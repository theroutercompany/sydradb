const std = @import("std");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const translator = @import("../../query/translator.zig");
const query_exec = @import("../../query/exec.zig");
const plan = @import("../../query/plan.zig");
const value_mod = @import("../../query/value.zig");
const engine_mod = @import("../../engine.zig");

const ManagedArrayList = std.array_list.Managed;

const log = std.log.scoped(.pgwire);

const max_message_size: usize = 16 * 1024 * 1024;

pub const ServerConfig = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 6432,
    session: session_mod.SessionConfig = .{},
    engine: *engine_mod.Engine,
};

pub fn run(alloc: std.mem.Allocator, config: ServerConfig) !void {
    const listen_addr = try parseAddress(config.address, config.port);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    log.info("pgwire listening on {s}:{d}", .{ config.address, config.port });

    while (true) {
        const connection = server.accept() catch |err| switch (err) {
            error.ConnectionResetByPeer, error.ConnectionAborted => continue,
            else => return err,
        };
        handleConnection(alloc, connection, config.session, config.engine) catch |err| switch (err) {
            error.EndOfStream => {},
            else => log.warn("pgwire connection ended with {s}", .{@errorName(err)}),
        };
    }
}

pub fn handleConnection(
    alloc: std.mem.Allocator,
    connection: std.net.Server.Connection,
    session_config: session_mod.SessionConfig,
    engine: *engine_mod.Engine,
) !void {
    defer connection.stream.close();

    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var reader_state = connection.stream.reader(&in_buf);
    var writer_state = connection.stream.writer(&out_buf);
    const reader = std.Io.Reader.adaptToOldInterface(reader_state.interface());
    const writer = anyWriter(&writer_state.interface);

    var session = session_mod.performHandshake(alloc, reader, writer, session_config) catch |err| {
        switch (err) {
            session_mod.HandshakeError.MissingUser,
            session_mod.HandshakeError.InvalidStartup,
            session_mod.HandshakeError.UnsupportedProtocol,
            session_mod.HandshakeError.CancelRequestUnsupported,
            session_mod.HandshakeError.OutOfMemory,
            => {
                log.debug("handshake terminated early: {s}", .{@errorName(err)});
                return;
            },
        }
    };
    defer session.deinit();

    log.debug(
        "session established user={s} db={s} app={s}",
        .{ session.borrowedUser(), session.borrowedDatabase(), session.borrowedApplicationName() },
    );

    try messageLoop(alloc, reader, writer, engine);
}

fn messageLoop(
    alloc: std.mem.Allocator,
    reader: std.Io.AnyReader,
    writer: std.Io.AnyWriter,
    engine: *engine_mod.Engine,
) !void {
    while (true) {
        const type_byte = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        const message_length = try readU32(reader);
        if (message_length < 4) return error.InvalidMessageLength;
        const payload_len = message_length - 4;
        if (payload_len > max_message_size) return error.MessageTooLarge;

        const payload_storage = try alloc.alloc(u8, payload_len);
        defer alloc.free(payload_storage);
        try reader.readNoEof(payload_storage);

        switch (type_byte) {
            'X' => return,
            'Q' => {
                try handleSimpleQuery(alloc, writer, payload_storage, engine);
            },
            'P' => {
                try handleParseMessage(alloc, writer, payload_storage);
            },
            'S' => {
                try protocol.writeReadyForQuery(writer, 'I');
            },
            else => {
                log.debug("frontend message {c} unsupported", .{type_byte});
                try protocol.writeErrorResponse(writer, "ERROR", "0A000", "message type not implemented");
                try protocol.writeReadyForQuery(writer, 'I');
            },
        }
    }
}

fn trimNullTerminator(buffer: []u8) []const u8 {
    if (buffer.len == 0) return buffer;
    if (buffer[buffer.len - 1] == 0) {
        return buffer[0 .. buffer.len - 1];
    }
    return buffer;
}

fn readU32(reader: std.Io.AnyReader) !u32 {
    var buf: [4]u8 = undefined;
    try reader.readNoEof(&buf);
    return std.mem.readInt(u32, &buf, .big);
}

fn handleSimpleQuery(
    alloc: std.mem.Allocator,
    writer: std.Io.AnyWriter,
    payload: []u8,
    engine: *engine_mod.Engine,
) !void {
    const raw_sql = trimNullTerminator(payload);
    const trimmed = std.mem.trim(u8, raw_sql, " \t\r\n");
    if (trimmed.len == 0) {
        try protocol.writeEmptyQueryResponse(writer);
        try protocol.writeReadyForQuery(writer, 'I');
        return;
    }

    log.debug("simple query received: {s}", .{trimmed});

    const translation = translator.translate(alloc, trimmed) catch |err| switch (err) {
        error.OutOfMemory => {
            try protocol.writeErrorResponse(writer, "FATAL", "53100", "out of memory during translation");
            try protocol.writeReadyForQuery(writer, 'I');
            return;
        },
    };

    switch (translation) {
        .success => |success| {
            defer alloc.free(success.sydraql);
            handleSydraqlQuery(alloc, writer, engine, success.sydraql) catch |err| {
                log.debug("sydraql execution failed: {s}", .{@errorName(err)});
                try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
                try protocol.writeReadyForQuery(writer, 'I');
                return;
            };
        },
        .failure => |failure| {
            const msg = if (failure.message.len == 0)
                "translation failed"
            else
                failure.message;
            try protocol.writeErrorResponse(writer, "ERROR", failure.sqlstate, msg);
            try protocol.writeReadyForQuery(writer, 'I');
        },
    }
}

fn handleParseMessage(
    alloc: std.mem.Allocator,
    writer: std.Io.AnyWriter,
    payload: []u8,
) !void {
    var cursor: usize = 0;
    const statement_name = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "malformed parse message");
        try protocol.writeReadyForQuery(writer, 'I');
        return;
    };

    const query_bytes = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "malformed parse message");
        try protocol.writeReadyForQuery(writer, 'I');
        return;
    };

    if (payload.len < cursor + 2) {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "parse message truncated");
        try protocol.writeReadyForQuery(writer, 'I');
        return;
    }

    const parameter_bytes = payload[cursor .. cursor + 2];
    const parameter_count = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(parameter_bytes.ptr)), .big);
    cursor += 2;
    const expected_bytes = @as(usize, parameter_count) * 4;
    if (payload.len < cursor + expected_bytes) {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "parse message truncated");
        try protocol.writeReadyForQuery(writer, 'I');
        return;
    }

    const trimmed = std.mem.trim(u8, query_bytes, " \t\r\n");
    log.debug(
        "parse message for statement '{s}' sql='{s}'",
        .{ statement_name, trimmed },
    );

    const translation = translator.translate(alloc, trimmed) catch |err| switch (err) {
        error.OutOfMemory => {
            try protocol.writeErrorResponse(writer, "FATAL", "53100", "out of memory during translation");
            try protocol.writeReadyForQuery(writer, 'I');
            return;
        },
    };

    switch (translation) {
        .success => |success| {
            defer alloc.free(success.sydraql);
            try protocol.writeErrorResponse(writer, "ERROR", "0A000", "extended protocol not implemented yet");
        },
        .failure => |failure| {
            const msg = if (failure.message.len == 0)
                "translation failed"
            else
                failure.message;
            try protocol.writeErrorResponse(writer, "ERROR", failure.sqlstate, msg);
        },
    }

    try protocol.writeReadyForQuery(writer, 'I');
}

fn handleSydraqlQuery(
    alloc: std.mem.Allocator,
    writer: std.Io.AnyWriter,
    engine: *engine_mod.Engine,
    sydraql: []const u8,
) !void {
    const start_time = std.time.microTimestamp();
    var cursor = query_exec.execute(alloc, engine, sydraql) catch |err| {
        try protocol.writeErrorResponse(writer, "ERROR", "0A000", @errorName(err));
        try protocol.writeReadyForQuery(writer, 'I');
        return;
    };
    defer cursor.deinit();

    try writeRowDescription(writer, cursor.columns);

    var row_buffer = std.array_list.Managed(u8).init(alloc);
    defer row_buffer.deinit();
    var value_buffer = ManagedArrayList(u8).init(alloc);
    defer value_buffer.deinit();

    var row_count: usize = 0;
    while (try cursor.next()) |row| {
        writeDataRow(writer, row.values, &row_buffer, &value_buffer) catch |err| {
            try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
            try protocol.writeReadyForQuery(writer, 'I');
            return;
        };
        row_count += 1;
    }

    const op_stats = try cursor.collectOperatorStats(alloc);
    defer alloc.free(op_stats);
    var rows_scanned: u64 = 0;
    for (op_stats) |stat| {
        if (std.ascii.eqlIgnoreCase(stat.name, "scan")) {
            rows_scanned += stat.rows_out;
        }
    }
    cursor.stats.rows_emitted = @as(u64, @intCast(row_count));
    cursor.stats.rows_scanned = rows_scanned;
    const elapsed_us = std.time.microTimestamp() - start_time;
    const plan_us = cursor.stats.parse_us + cursor.stats.validate_us + cursor.stats.optimize_us + cursor.stats.physical_us + cursor.stats.pipeline_us;
    const stream_ms = @divTrunc(elapsed_us, 1000);
    const plan_ms = @divTrunc(@as(i64, @intCast(plan_us)), 1000);
    for (op_stats) |stat| {
        const elapsed_ms = @divTrunc(@as(i64, @intCast(stat.elapsed_us)), 1000);
        const notice = try std.fmt.allocPrint(alloc, "operator={s} rows_out={d} elapsed_ms={d}", .{ stat.name, stat.rows_out, elapsed_ms });
        defer alloc.free(notice);
        try protocol.writeNoticeResponse(writer, notice);
    }
    const tag = try formatSelectTag(alloc, row_count, rows_scanned, stream_ms, plan_ms, cursor.stats.trace_id);
    defer alloc.free(tag);
    try protocol.writeCommandComplete(writer, tag);
    try protocol.writeReadyForQuery(writer, 'I');
}

fn writeRowDescription(writer: std.Io.AnyWriter, columns: []const plan.ColumnInfo) !void {
    try writer.writeByte('T');
    var len: u32 = 4 + 2;
    for (columns) |col| {
        len += @as(u32, @intCast(col.name.len + 19));
    }
    var buf4: [4]u8 = undefined;
    std.mem.writeInt(u32, buf4[0..4], len, .big);
    try writer.writeAll(buf4[0..4]);

    var buf2: [2]u8 = undefined;
    std.mem.writeInt(u16, buf2[0..2], @as(u16, @intCast(columns.len)), .big);
    try writer.writeAll(buf2[0..2]);

    for (columns) |col| {
        try writer.writeAll(col.name);
        try writer.writeByte(0);

        std.mem.writeInt(u32, buf4[0..4], 0, .big);
        try writer.writeAll(buf4[0..4]);
        std.mem.writeInt(u16, buf2[0..2], 0, .big);
        try writer.writeAll(buf2[0..2]);
        std.mem.writeInt(u32, buf4[0..4], 25, .big); // text OID
        try writer.writeAll(buf4[0..4]);
        std.mem.writeInt(i16, buf2[0..2], -1, .big);
        try writer.writeAll(buf2[0..2]);
        std.mem.writeInt(i32, buf4[0..4], -1, .big);
        try writer.writeAll(buf4[0..4]);
        std.mem.writeInt(u16, buf2[0..2], 0, .big); // text format
        try writer.writeAll(buf2[0..2]);
    }
}

fn writeDataRow(
    writer: std.Io.AnyWriter,
    values: []const value_mod.Value,
    row_buffer: *std.array_list.Managed(u8),
    value_buffer: *ManagedArrayList(u8),
) !void {
    row_buffer.items.len = 0;
    try row_buffer.append('D');
    const len_index = row_buffer.items.len;
    try row_buffer.appendSlice(&[_]u8{ 0, 0, 0, 0 });

    var buf2: [2]u8 = undefined;
    std.mem.writeInt(u16, buf2[0..2], @as(u16, @intCast(values.len)), .big);
    try row_buffer.appendSlice(buf2[0..2]);

    var len_buf: [4]u8 = undefined;
    for (values) |value| {
        const maybe_text = try formatValue(value, value_buffer);
        if (maybe_text) |text| {
            std.mem.writeInt(i32, len_buf[0..4], @as(i32, @intCast(text.len)), .big);
            try row_buffer.appendSlice(len_buf[0..4]);
            try row_buffer.appendSlice(text);
        } else {
            std.mem.writeInt(i32, len_buf[0..4], -1, .big);
            try row_buffer.appendSlice(len_buf[0..4]);
        }
    }

    const len_ptr = @as(*[4]u8, @ptrCast(row_buffer.items.ptr + len_index));
    std.mem.writeInt(u32, len_ptr, @as(u32, @intCast(row_buffer.items.len - 1)), .big);
    try writer.writeAll(row_buffer.items);
}

fn formatValue(value: value_mod.Value, buf: *ManagedArrayList(u8)) !?[]const u8 {
    switch (value) {
        .null => return null,
        .boolean => |b| {
            buf.items.len = 0;
            try buf.writer().writeAll(if (b) "t" else "f");
            return buf.items;
        },
        .integer => |i| {
            buf.items.len = 0;
            try buf.writer().print("{d}", .{i});
            return buf.items;
        },
        .float => |f| {
            buf.items.len = 0;
            try buf.writer().print("{d}", .{f});
            return buf.items;
        },
        .string => |s| return s,
    }
}

fn readCString(buffer: []const u8, cursor: *usize) ![]const u8 {
    const start = cursor.*;
    const end = std.mem.indexOfScalarPos(u8, buffer, start, 0) orelse return error.MalformedCstring;
    cursor.* = end + 1;
    return buffer[start..end];
}

fn parseAddress(host: []const u8, port: u16) !std.net.Address {
    return std.net.Address.parseIp4(host, port) catch {
        return std.net.Address.parseIp6(host, port) catch {
            return error.InvalidAddress;
        };
    };
}

fn anyWriter(writer: *std.Io.Writer) std.Io.AnyWriter {
    return .{
        .context = writer,
        .writeFn = struct {
            fn call(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
                const w: *std.Io.Writer = @ptrCast(@alignCast(@constCast(ctx)));
                return w.write(bytes);
            }
        }.call,
    };
}

fn formatSelectTag(
    alloc: std.mem.Allocator,
    rows_emitted: usize,
    rows_scanned: u64,
    stream_ms: i64,
    plan_ms: i64,
    trace_id: []const u8,
) ![]const u8 {
    if (trace_id.len != 0) {
        return try std.fmt.allocPrint(
            alloc,
            "SELECT rows={d} scanned={d} stream_ms={d} plan_ms={d} trace_id={s}",
            .{ rows_emitted, rows_scanned, stream_ms, plan_ms, trace_id },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "SELECT rows={d} scanned={d} stream_ms={d} plan_ms={d}",
        .{ rows_emitted, rows_scanned, stream_ms, plan_ms },
    );
}

test "formatSelectTag includes scanned rows" {
    const alloc = std.testing.allocator;
    const tag = try formatSelectTag(alloc, 5, 12, 20, 8, "");
    defer alloc.free(tag);
    try std.testing.expectEqualStrings("SELECT rows=5 scanned=12 stream_ms=20 plan_ms=8", tag);
}

test "formatSelectTag includes trace id when present" {
    const alloc = std.testing.allocator;
    const tag = try formatSelectTag(alloc, 2, 4, 15, 9, "ABC123");
    defer alloc.free(tag);
    try std.testing.expectEqualStrings("SELECT rows=2 scanned=4 stream_ms=15 plan_ms=9 trace_id=ABC123", tag);
}
