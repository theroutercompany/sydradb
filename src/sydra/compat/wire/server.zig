const std = @import("std");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const prepared_query = @import("../../query/prepared.zig");
const translator = @import("../../query/translator.zig");
const query_exec = @import("../../query/exec.zig");
const compiler_diagnostics = @import("../../query/compiler/diagnostics.zig");
const frontend = @import("../../query/frontend.zig");
const query_common = @import("../../query/common.zig");
const plan = @import("../../query/plan.zig");
const value_mod = @import("../../query/value.zig");
const engine_mod = @import("../../engine.zig");
const query_functions = @import("../../query/functions.zig");

const ManagedArrayList = std.array_list.Managed;

const log = std.log.scoped(.pgwire);

const max_message_size: usize = 16 * 1024 * 1024;

const PreparedQueryOutcome = union(enum) {
    handled,
    fallback: []const u8,
};

const PgwireExecutionErrorContract = struct {
    sqlstate: []const u8,
    message: []const u8,
};

const DescribedColumnState = struct {
    name: []u8,
};

pub const ServerConfig = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 6432,
    session: session_mod.SessionConfig = .{},
    engine: *engine_mod.Engine,
};

const ParsedStatementState = struct {
    name: []u8,
    template: prepared_query.PreparedStmt,
    parameter_oids: []u32,
    columns: []DescribedColumnState,
};

const BoundPortalState = struct {
    name: []u8,
    stmt: prepared_query.PreparedStmt,
    pending_row: ?[]value_mod.Value = null,
    emitted_rows: usize = 0,
};

const ExtendedQueryState = struct {
    alloc: std.mem.Allocator,
    parsed_statements: std.array_list.Managed(ParsedStatementState),
    bound_portals: std.array_list.Managed(BoundPortalState),

    fn init(alloc: std.mem.Allocator) ExtendedQueryState {
        return .{
            .alloc = alloc,
            .parsed_statements = std.array_list.Managed(ParsedStatementState).init(alloc),
            .bound_portals = std.array_list.Managed(BoundPortalState).init(alloc),
        };
    }

    fn deinit(self: *ExtendedQueryState) void {
        for (self.parsed_statements.items) |*entry| {
            self.alloc.free(entry.name);
            entry.template.finalize();
            if (entry.parameter_oids.len != 0) self.alloc.free(entry.parameter_oids);
            freeDescribedColumns(self.alloc, entry.columns);
        }
        self.parsed_statements.deinit();
        for (self.bound_portals.items) |*entry| {
            self.alloc.free(entry.name);
            freeOwnedRowValues(self.alloc, entry.pending_row);
            entry.stmt.finalize();
        }
        self.bound_portals.deinit();
    }

    fn upsertParsedStatement(
        self: *ExtendedQueryState,
        name: []const u8,
        stmt: prepared_query.PreparedStmt,
        parameter_oids: []u32,
        columns: []DescribedColumnState,
    ) !void {
        errdefer if (parameter_oids.len != 0) self.alloc.free(parameter_oids);
        errdefer freeDescribedColumns(self.alloc, columns);
        var stmt_adopted = false;
        defer if (!stmt_adopted) {
            var cleanup = stmt;
            cleanup.finalize();
        };

        if (name.len == 0) {
            _ = self.closePortal("");
        }
        if (self.findParsedIndex(name)) |idx| {
            self.alloc.free(self.parsed_statements.items[idx].name);
            self.parsed_statements.items[idx].template.finalize();
            if (self.parsed_statements.items[idx].parameter_oids.len != 0) self.alloc.free(self.parsed_statements.items[idx].parameter_oids);
            freeDescribedColumns(self.alloc, self.parsed_statements.items[idx].columns);
            self.parsed_statements.items[idx] = .{
                .name = try self.alloc.dupe(u8, name),
                .template = stmt,
                .parameter_oids = parameter_oids,
                .columns = columns,
            };
            stmt_adopted = true;
            return;
        }
        try self.parsed_statements.append(.{
            .name = try self.alloc.dupe(u8, name),
            .template = stmt,
            .parameter_oids = parameter_oids,
            .columns = columns,
        });
        stmt_adopted = true;
    }

    fn getParsedStatement(self: *ExtendedQueryState, name: []const u8) ?*ParsedStatementState {
        const idx = self.findParsedIndex(name) orelse return null;
        return &self.parsed_statements.items[idx];
    }

    fn closeParsedStatement(self: *ExtendedQueryState, name: []const u8) bool {
        const idx = self.findParsedIndex(name) orelse return false;
        var entry = self.parsed_statements.swapRemove(idx);
        self.alloc.free(entry.name);
        entry.template.finalize();
        if (entry.parameter_oids.len != 0) self.alloc.free(entry.parameter_oids);
        freeDescribedColumns(self.alloc, entry.columns);
        return true;
    }

    fn upsertPortal(self: *ExtendedQueryState, name: []const u8, stmt: prepared_query.PreparedStmt) !void {
        if (self.findPortalIndex(name)) |idx| {
            self.alloc.free(self.bound_portals.items[idx].name);
            freeOwnedRowValues(self.alloc, self.bound_portals.items[idx].pending_row);
            self.bound_portals.items[idx].stmt.finalize();
            self.bound_portals.items[idx] = .{
                .name = try self.alloc.dupe(u8, name),
                .stmt = stmt,
                .pending_row = null,
                .emitted_rows = 0,
            };
            return;
        }
        try self.bound_portals.append(.{
            .name = try self.alloc.dupe(u8, name),
            .stmt = stmt,
            .pending_row = null,
            .emitted_rows = 0,
        });
    }

    fn getPortal(self: *ExtendedQueryState, name: []const u8) ?*BoundPortalState {
        const idx = self.findPortalIndex(name) orelse return null;
        return &self.bound_portals.items[idx];
    }

    fn closePortal(self: *ExtendedQueryState, name: []const u8) bool {
        const idx = self.findPortalIndex(name) orelse return false;
        var entry = self.bound_portals.swapRemove(idx);
        self.alloc.free(entry.name);
        freeOwnedRowValues(self.alloc, entry.pending_row);
        entry.stmt.finalize();
        return true;
    }

    fn findParsedIndex(self: *ExtendedQueryState, name: []const u8) ?usize {
        for (self.parsed_statements.items, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.name, name)) return idx;
        }
        return null;
    }

    fn findPortalIndex(self: *ExtendedQueryState, name: []const u8) ?usize {
        for (self.bound_portals.items, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.name, name)) return idx;
        }
        return null;
    }
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

    try writer_state.interface.flush();
    try messageLoop(alloc, reader, writer, &writer_state.interface, engine);
}

fn messageLoop(
    alloc: std.mem.Allocator,
    reader: std.Io.AnyReader,
    writer: std.Io.AnyWriter,
    flush_writer: *std.Io.Writer,
    engine: *engine_mod.Engine,
) !void {
    var extended_state = ExtendedQueryState.init(alloc);
    defer extended_state.deinit();

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
                try handleParseMessage(alloc, writer, payload_storage, engine, &extended_state);
            },
            'B' => {
                try handleBindMessage(alloc, writer, payload_storage, engine, &extended_state);
            },
            'D' => {
                try handleDescribeMessage(writer, payload_storage, &extended_state);
            },
            'E' => {
                try handleExecuteMessage(alloc, writer, payload_storage, &extended_state);
            },
            'C' => {
                try handleCloseMessage(writer, payload_storage, &extended_state);
            },
            'H' => {
                // Flush requests only ask the backend to drain buffered output.
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
        try flush_writer.flush();
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

fn readPayloadU16(payload: []const u8, cursor: *usize) !u16 {
    if (payload.len < cursor.* + 2) return error.InvalidMessageLength;
    const bytes = payload[cursor.* .. cursor.* + 2];
    cursor.* += 2;
    return std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(bytes.ptr)), .big);
}

fn readPayloadI32(payload: []const u8, cursor: *usize) !i32 {
    if (payload.len < cursor.* + 4) return error.InvalidMessageLength;
    const bytes = payload[cursor.* .. cursor.* + 4];
    cursor.* += 4;
    return std.mem.readInt(i32, @as(*const [4]u8, @ptrCast(bytes.ptr)), .big);
}

fn readFormatCodes(alloc: std.mem.Allocator, payload: []const u8, cursor: *usize, count: u16) ![]u16 {
    const start = cursor.*;
    const bytes = @as(usize, count) * 2;
    if (payload.len < start + bytes) return error.InvalidMessageLength;
    cursor.* += bytes;
    if (count == 0) return &.{};

    const codes = try alloc.alloc(u16, count);
    for (0..count) |idx| {
        const offset = start + idx * 2;
        codes[idx] = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(payload[offset .. offset + 2].ptr)), .big);
    }
    return codes;
}

fn parameterFormatCode(codes: []const u16, param_idx: usize) u16 {
    if (codes.len == 0) return 0;
    if (codes.len == 1) return codes[0];
    return if (param_idx < codes.len) codes[param_idx] else 0;
}

fn freeDescribedColumns(alloc: std.mem.Allocator, columns: []DescribedColumnState) void {
    if (columns.len == 0) return;
    for (columns) |column| {
        alloc.free(column.name);
    }
    alloc.free(columns);
}

fn cloneOwnedRowValues(alloc: std.mem.Allocator, values: []const value_mod.Value) ![]value_mod.Value {
    const owned = try alloc.alloc(value_mod.Value, values.len);
    errdefer alloc.free(owned);
    for (values, 0..) |value, idx| {
        owned[idx] = switch (value) {
            .string => |text| .{ .string = try alloc.dupe(u8, text) },
            else => value,
        };
    }
    return owned;
}

fn freeOwnedRowValues(alloc: std.mem.Allocator, values: ?[]value_mod.Value) void {
    const slice = values orelse return;
    for (slice) |value| switch (value) {
        .string => |text| alloc.free(text),
        else => {},
    };
    alloc.free(slice);
}

fn readPayloadBytes(payload: []const u8, cursor: *usize, len: usize) ![]const u8 {
    if (payload.len < cursor.* + len) return error.InvalidMessageLength;
    const out = payload[cursor.* .. cursor.* + len];
    cursor.* += len;
    return out;
}

fn parseBindTextValue(text: []const u8, parameter: prepared_query.ParameterDescription) !value_mod.Value {
    switch (parameter.inferred_type.tag) {
        .string, .tags => return .{ .string = text },
        .boolean => {
            if (std.ascii.eqlIgnoreCase(text, "t") or std.ascii.eqlIgnoreCase(text, "true")) return .{ .boolean = true };
            if (std.ascii.eqlIgnoreCase(text, "f") or std.ascii.eqlIgnoreCase(text, "false")) return .{ .boolean = false };
            return error.InvalidFormat;
        },
        .integer, .timestamp, .duration => {
            const value = std.fmt.parseInt(i64, text, 10) catch return error.InvalidFormat;
            return .{ .integer = value };
        },
        .float => {
            if (std.fmt.parseFloat(f64, text)) |value| {
                return .{ .float = value };
            } else |_| if (std.fmt.parseInt(i64, text, 10)) |value| {
                return .{ .integer = value };
            } else |_| return error.InvalidFormat;
        },
        .numeric, .value, .null, .any => {},
    }
    if (std.ascii.eqlIgnoreCase(text, "null")) return .null;
    if (std.ascii.eqlIgnoreCase(text, "t") or std.ascii.eqlIgnoreCase(text, "true")) return .{ .boolean = true };
    if (std.ascii.eqlIgnoreCase(text, "f") or std.ascii.eqlIgnoreCase(text, "false")) return .{ .boolean = false };
    if (std.fmt.parseInt(i64, text, 10)) |value| {
        return .{ .integer = value };
    } else |_| {}
    if (std.fmt.parseFloat(f64, text)) |value| {
        return .{ .float = value };
    } else |_| {}
    return .{ .string = text };
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
    query_common.validateQueryTextLimit(trimmed) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "54000", query_common.query_text_too_large_message);
        try protocol.writeReadyForQuery(writer, 'I');
        return;
    };

    log.debug("simple query received: {s}", .{trimmed});

    switch (try handleSqlCorePreparedQuery(alloc, writer, engine, trimmed)) {
        .handled => return,
        .fallback => |reason| {
            defer alloc.free(reason);
            try writeExecutionModeNotices(alloc, writer, "translator", true, reason);
            const notice = try std.fmt.allocPrint(alloc, "sql_prepare_fallback=translator reason={s}", .{reason});
            defer alloc.free(notice);
            try protocol.writeNoticeResponse(writer, notice);
        },
    }

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
    engine: *engine_mod.Engine,
    state: *ExtendedQueryState,
) !void {
    var cursor: usize = 0;
    const statement_name = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "malformed parse message");
        return;
    };

    const query_bytes = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "malformed parse message");
        return;
    };

    if (payload.len < cursor + 2) {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "parse message truncated");
        return;
    }

    const parameter_bytes = payload[cursor .. cursor + 2];
    const parameter_count = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(parameter_bytes.ptr)), .big);
    cursor += 2;
    const expected_bytes = @as(usize, parameter_count) * 4;
    if (payload.len < cursor + expected_bytes) {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "parse message truncated");
        return;
    }

    const trimmed = std.mem.trim(u8, query_bytes, " \t\r\n");
    query_common.validateQueryTextLimit(trimmed) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "54000", query_common.query_text_too_large_message);
        return;
    };
    log.debug(
        "parse message for statement '{s}' sql='{s}'",
        .{ statement_name, trimmed },
    );

    var stmt = prepared_query.prepareSqlCore(alloc, engine, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.NotImplemented => {
            try protocol.writeErrorResponse(writer, "ERROR", "0A000", "SQL parse unsupported by direct prepare");
            return;
        },
        else => {
            try protocol.writeErrorResponse(writer, "ERROR", "42601", @errorName(err));
            return;
        },
    };
    var stmt_adopted = false;
    defer if (!stmt_adopted) stmt.finalize();

    if (parameter_count != 0 and parameter_count != stmt.binding.maxParameterSlot()) {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "parse parameter count does not match statement");
        return;
    }

    const parameter_descriptions = try stmt.describeParameters();
    const parameter_oids = try alloc.alloc(u32, parameter_descriptions.len);
    errdefer alloc.free(parameter_oids);
    for (parameter_descriptions, 0..) |description, idx| {
        parameter_oids[idx] = description.pgOid();
    }

    const columns = stmt.describeColumns() catch |err| {
        try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
        return;
    };
    var described_columns_list = std.array_list.Managed(DescribedColumnState).init(alloc);
    errdefer {
        for (described_columns_list.items) |column| alloc.free(column.name);
        described_columns_list.deinit();
    }
    for (columns) |column| {
        try described_columns_list.append(.{ .name = try alloc.dupe(u8, column.name) });
    }
    const described_columns = try described_columns_list.toOwnedSlice();

    try state.upsertParsedStatement(
        statement_name,
        stmt,
        parameter_oids,
        described_columns,
    );
    stmt_adopted = true;
    try protocol.writeParseComplete(writer);
}

fn handleBindMessage(
    alloc: std.mem.Allocator,
    writer: std.Io.AnyWriter,
    payload: []u8,
    engine: *engine_mod.Engine,
    state: *ExtendedQueryState,
) !void {
    var cursor: usize = 0;
    const portal_name = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "malformed bind message");
        return;
    };
    const statement_name = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "malformed bind message");
        return;
    };

    const format_count = readPayloadU16(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "bind message truncated");
        return;
    };
    const format_codes = readFormatCodes(alloc, payload, &cursor, format_count) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "bind format codes truncated");
        return;
    };
    defer if (format_codes.len != 0) alloc.free(format_codes);

    const parsed = state.getParsedStatement(statement_name) orelse {
        try protocol.writeErrorResponse(writer, "ERROR", "26000", "unknown prepared statement");
        return;
    };

    const parameter_count = readPayloadU16(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "bind parameter count missing");
        return;
    };
    if (parameter_count != parsed.template.binding.maxParameterSlot()) {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "bind parameter count does not match prepared statement");
        return;
    }

    var stmt = parsed.template.cloneForExecution(alloc, engine) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.NotImplemented => {
            try protocol.writeErrorResponse(writer, "ERROR", "0A000", "SQL bind unsupported by direct prepare");
            return;
        },
        else => {
            try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
            return;
        },
    };
    var portal_adopted = false;
    defer if (!portal_adopted) stmt.finalize();

    for (0..parameter_count) |param_idx| {
        const param_length = readPayloadI32(payload, &cursor) catch {
            try protocol.writeErrorResponse(writer, "ERROR", "08P01", "bind parameter value truncated");
            return;
        };
        const format_code = parameterFormatCode(format_codes, param_idx);
        if (format_code != 0) {
            try protocol.writeErrorResponse(writer, "ERROR", "0A000", "binary bind parameters are not supported");
            return;
        }
        if (param_length < 0) {
            try stmt.bindPositional(param_idx + 1, .null);
            continue;
        }
        const text = readPayloadBytes(payload, &cursor, @intCast(param_length)) catch {
            try protocol.writeErrorResponse(writer, "ERROR", "08P01", "bind parameter value truncated");
            return;
        };
        const parameter = stmt.describeParameters() catch |err| {
            try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
            return;
        };
        try stmt.bindPositional(param_idx + 1, parseBindTextValue(text, parameter[param_idx]) catch {
            try protocol.writeErrorResponse(writer, "ERROR", "22P02", "invalid text representation for bind parameter");
            return;
        });
    }

    const result_format_count = readPayloadU16(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "bind result formats missing");
        return;
    };
    const result_format_codes = readFormatCodes(alloc, payload, &cursor, result_format_count) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "bind result formats truncated");
        return;
    };
    defer if (result_format_codes.len != 0) alloc.free(result_format_codes);
    for (result_format_codes) |format_code| {
        if (format_code != 0) {
            try protocol.writeErrorResponse(writer, "ERROR", "0A000", "binary result formats are not supported");
            return;
        }
    }

    try state.upsertPortal(portal_name, stmt);
    portal_adopted = true;
    try protocol.writeBindComplete(writer);
}

fn handleDescribeMessage(
    writer: std.Io.AnyWriter,
    payload: []u8,
    state: *ExtendedQueryState,
) !void {
    if (payload.len < 2) {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "describe message truncated");
        return;
    }

    var cursor: usize = 1;
    const target = payload[0];
    const name = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "malformed describe message");
        return;
    };

    switch (target) {
        'S' => {
            const parsed = state.getParsedStatement(name) orelse {
                try protocol.writeErrorResponse(writer, "ERROR", "26000", "unknown prepared statement");
                return;
            };
            try protocol.writeParameterDescription(writer, parsed.parameter_oids);
            if (parsed.template.producesRows() and parsed.columns.len != 0) {
                try writeDescribedRowDescription(writer, parsed.columns);
            } else {
                try protocol.writeNoData(writer);
            }
        },
        'P' => {
            const portal = state.getPortal(name) orelse {
                try protocol.writeErrorResponse(writer, "ERROR", "34000", "unknown portal");
                return;
            };
            const columns = portal.stmt.describeColumns() catch |err| {
                try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
                return;
            };
            if (columns.len == 0) {
                try protocol.writeNoData(writer);
            } else {
                try writeRowDescription(writer, columns);
            }
        },
        else => try protocol.writeErrorResponse(writer, "ERROR", "08P01", "unknown describe target"),
    }
}

fn handleExecuteMessage(
    alloc: std.mem.Allocator,
    writer: std.Io.AnyWriter,
    payload: []u8,
    state: *ExtendedQueryState,
) !void {
    var cursor: usize = 0;
    const portal_name = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "malformed execute message");
        return;
    };
    const max_rows = readPayloadI32(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "execute message truncated");
        return;
    };

    const portal = state.getPortal(portal_name) orelse {
        try protocol.writeErrorResponse(writer, "ERROR", "34000", "unknown portal");
        return;
    };

    if (!portal.stmt.producesRows()) {
        while (true) {
            const step = portal.stmt.step() catch |err| {
                try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
                return;
            };
            switch (step) {
                .row => {
                    try protocol.writeErrorResponse(writer, "ERROR", "XX000", "write portal produced an unexpected row");
                    return;
                },
                .done => {
                    const tag = try formatCommandTag(alloc, portal.stmt.statementKind(), portal.stmt.rowsAffected());
                    defer alloc.free(tag);
                    try protocol.writeCommandComplete(writer, tag);
                    return;
                },
            }
        }
    }

    var row_buffer = std.array_list.Managed(u8).init(alloc);
    defer row_buffer.deinit();
    var value_buffer = ManagedArrayList(u8).init(alloc);
    defer value_buffer.deinit();

    var row_count: usize = 0;
    if (portal.pending_row) |pending| {
        portal.pending_row = null;
        defer freeOwnedRowValues(alloc, pending);
        try writeDataRow(writer, pending, &row_buffer, &value_buffer);
        row_count += 1;
        portal.emitted_rows += 1;
        if (max_rows > 0 and row_count >= @as(usize, @intCast(max_rows))) {
            if (try prefetchOrCompletePortal(alloc, writer, portal)) return;
            try protocol.writePortalSuspended(writer);
            return;
        }
    }

    while (max_rows <= 0 or row_count < @as(usize, @intCast(max_rows))) {
        const step = portal.stmt.step() catch |err| {
            try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
            return;
        };
        switch (step) {
            .row => |values| {
                try writeDataRow(writer, values, &row_buffer, &value_buffer);
                row_count += 1;
                portal.emitted_rows += 1;
                if (max_rows > 0 and row_count >= @as(usize, @intCast(max_rows))) {
                    if (try prefetchOrCompletePortal(alloc, writer, portal)) return;
                    try protocol.writePortalSuspended(writer);
                    return;
                }
            },
            .done => {
                const tag = try formatCommandTag(alloc, portal.stmt.statementKind(), portal.emitted_rows);
                defer alloc.free(tag);
                try protocol.writeCommandComplete(writer, tag);
                return;
            },
        }
    }

    try protocol.writePortalSuspended(writer);
}

fn prefetchOrCompletePortal(
    alloc: std.mem.Allocator,
    writer: std.Io.AnyWriter,
    portal: *BoundPortalState,
) !bool {
    const next_step = portal.stmt.step() catch |err| {
        try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
        return true;
    };
    switch (next_step) {
        .done => {
            const tag = try formatCommandTag(alloc, portal.stmt.statementKind(), portal.emitted_rows);
            defer alloc.free(tag);
            try protocol.writeCommandComplete(writer, tag);
            return true;
        },
        .row => |values| {
            freeOwnedRowValues(alloc, portal.pending_row);
            portal.pending_row = try cloneOwnedRowValues(alloc, values);
            return false;
        },
    }
}

fn handleCloseMessage(
    writer: std.Io.AnyWriter,
    payload: []u8,
    state: *ExtendedQueryState,
) !void {
    if (payload.len < 2) {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "close message truncated");
        return;
    }

    var cursor: usize = 1;
    const target = payload[0];
    const name = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer, "ERROR", "08P01", "malformed close message");
        return;
    };

    const closed = switch (target) {
        'S' => state.closeParsedStatement(name),
        'P' => state.closePortal(name),
        else => {
            try protocol.writeErrorResponse(writer, "ERROR", "08P01", "unknown close target");
            return;
        },
    };
    if (!closed) {
        try protocol.writeErrorResponse(writer, "ERROR", if (target == 'S') "26000" else "34000", "named object does not exist");
        return;
    }
    try protocol.writeCloseComplete(writer);
}

fn handleSqlCorePreparedQuery(
    alloc: std.mem.Allocator,
    writer: std.Io.AnyWriter,
    engine: *engine_mod.Engine,
    sql: []const u8,
) !PreparedQueryOutcome {
    var stmt = prepared_query.prepareSqlCore(alloc, engine, sql, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.NotImplemented => {
            const reason = try classifySqlPrepareFallback(alloc, sql);
            log.debug("sql_core prepared path falling back for {s}: {s}", .{ sql, reason });
            return .{ .fallback = reason };
        },
        else => {
            try protocol.writeErrorResponse(writer, "ERROR", "42601", @errorName(err));
            try protocol.writeReadyForQuery(writer, 'I');
            return .handled;
        },
    };
    defer stmt.finalize();

    if (stmt.producesRows()) {
        try writeRowDescription(writer, stmt.columns);
    }

    var row_buffer = std.array_list.Managed(u8).init(alloc);
    defer row_buffer.deinit();
    var value_buffer = ManagedArrayList(u8).init(alloc);
    defer value_buffer.deinit();

    var row_count: usize = 0;
    while (true) {
        const step = stmt.step() catch |err| {
            try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
            try protocol.writeReadyForQuery(writer, 'I');
            return .handled;
        };
        switch (step) {
            .row => |values| {
                if (!stmt.producesRows()) {
                    try protocol.writeErrorResponse(writer, "ERROR", "XX000", "write statement produced an unexpected row");
                    try protocol.writeReadyForQuery(writer, 'I');
                    return .handled;
                }
                writeDataRow(writer, values, &row_buffer, &value_buffer) catch |err| {
                    try protocol.writeErrorResponse(writer, "ERROR", "XX000", @errorName(err));
                    try protocol.writeReadyForQuery(writer, 'I');
                    return .handled;
                };
                row_count += 1;
            },
            .done => break,
        }
    }

    if (stmt.producesRows() and stmt.columns.len != 0) {
        const schema_notice = try formatSchemaNotice(alloc, stmt.columns);
        defer alloc.free(schema_notice);
        try protocol.writeNoticeResponse(writer, schema_notice);
    }
    try writeExecutionModeNotices(alloc, writer, "sql_core_vm", false, "");

    const tag = try formatCommandTag(
        alloc,
        stmt.statementKind(),
        if (stmt.producesRows()) row_count else stmt.rowsAffected(),
    );
    defer alloc.free(tag);
    try protocol.writeCommandComplete(writer, tag);
    try protocol.writeReadyForQuery(writer, 'I');
    return .handled;
}

fn classifySqlPrepareFallback(alloc: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var skeleton = try frontend.sql_core.parseSqlCoreSkeleton(alloc, sql);
    defer skeleton.deinit();

    if (skeleton.stmt == null) {
        if (skeleton.diagnostics.len != 0) {
            const code = @tagName(skeleton.diagnostics[0].code);
            return try std.fmt.allocPrint(alloc, "frontend_{s}", .{code});
        }
        return try alloc.dupe(u8, "frontend_uncovered");
    }
    return try alloc.dupe(u8, "compiler_not_implemented");
}

fn pgwireExecutionErrorContract(err: query_exec.ExecuteError) PgwireExecutionErrorContract {
    if (compiler_diagnostics.fromCompileError(err)) |reason| {
        return switch (reason) {
            .series_not_found => .{
                .sqlstate = "42P01",
                .message = compiler_diagnostics.diagnosticMessage(reason),
            },
            .ambiguous_selector => .{
                .sqlstate = "22023",
                .message = compiler_diagnostics.diagnosticMessage(reason),
            },
            .shadow_mismatch => .{
                .sqlstate = "XX000",
                .message = compiler_diagnostics.diagnosticMessage(reason),
            },
            else => .{
                .sqlstate = "0A000",
                .message = compiler_diagnostics.diagnosticMessage(reason),
            },
        };
    }

    return switch (err) {
        error.ValidationFailed => .{
            .sqlstate = "22023",
            .message = "validation failed",
        },
        error.InvalidLiteral,
        error.UnterminatedString,
        error.UnexpectedToken,
        error.UnexpectedStatement,
        error.UnexpectedExpression,
        error.UnterminatedParenthesis,
        error.InvalidNumber,
        error.InvalidDuration,
        error.InvalidTimestamp,
        => .{
            .sqlstate = "42601",
            .message = "syntax error",
        },
        else => .{
            .sqlstate = "XX000",
            .message = @errorName(err),
        },
    };
}

fn handleSydraqlQuery(
    alloc: std.mem.Allocator,
    writer: std.Io.AnyWriter,
    engine: *engine_mod.Engine,
    sydraql: []const u8,
) !void {
    const start_time = std.time.microTimestamp();
    var cursor = query_exec.execute(alloc, engine, sydraql) catch |err| {
        const contract = pgwireExecutionErrorContract(err);
        try protocol.writeErrorResponse(writer, "ERROR", contract.sqlstate, contract.message);
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
    const plan_us = cursor.stats.parse_us + cursor.stats.validate_us + cursor.stats.bind_us + cursor.stats.compile_us + cursor.stats.logical_us + cursor.stats.optimize_us + cursor.stats.physical_us + cursor.stats.pipeline_us;
    const stream_ms = @divTrunc(elapsed_us, 1000);
    const plan_ms = @divTrunc(@as(i64, @intCast(plan_us)), 1000);
    if (cursor.columns.len != 0) {
        const schema_notice = try formatSchemaNotice(alloc, cursor.columns);
        defer alloc.free(schema_notice);
        try protocol.writeNoticeResponse(writer, schema_notice);
    }
    if (cursor.stats.trace_id.len != 0) {
        const trace_notice = try formatTraceNotice(alloc, cursor.stats.trace_id);
        defer alloc.free(trace_notice);
        try protocol.writeNoticeResponse(writer, trace_notice);
    }
    try writeExecutionModeNotices(alloc, writer, cursor.stats.execution_mode, cursor.stats.legacy_fallback, cursor.stats.fallback_reason);
    for (op_stats) |stat| {
        const elapsed_ms = @divTrunc(@as(i64, @intCast(stat.elapsed_us)), 1000);
        const notice = try std.fmt.allocPrint(alloc, "operator={s} rows_out={d} elapsed_ms={d}", .{ stat.name, stat.rows_out, elapsed_ms });
        defer alloc.free(notice);
        try protocol.writeNoticeResponse(writer, notice);
    }
    const metrics_notice = try formatMetricsNotice(alloc, row_count, rows_scanned, stream_ms, plan_ms);
    defer alloc.free(metrics_notice);
    try protocol.writeNoticeResponse(writer, metrics_notice);

    const tag = try formatSelectTag(alloc, row_count);
    defer alloc.free(tag);
    try protocol.writeCommandComplete(writer, tag);
    try protocol.writeReadyForQuery(writer, 'I');
}

fn writeRowDescription(writer: std.Io.AnyWriter, columns: []const plan.ColumnInfo) !void {
    try writeColumnDescriptions(writer, ColumnDescriptionAdapter.initPlan(columns));
}

fn writeDescribedRowDescription(writer: std.Io.AnyWriter, columns: []const DescribedColumnState) !void {
    try writeColumnDescriptions(writer, ColumnDescriptionAdapter.initDescribed(columns));
}

const ColumnDescriptionAdapter = union(enum) {
    plan: []const plan.ColumnInfo,
    described: []const DescribedColumnState,

    fn initPlan(columns: []const plan.ColumnInfo) ColumnDescriptionAdapter {
        return .{ .plan = columns };
    }

    fn initDescribed(columns: []const DescribedColumnState) ColumnDescriptionAdapter {
        return .{ .described = columns };
    }

    fn len(self: ColumnDescriptionAdapter) usize {
        return switch (self) {
            .plan => |columns| columns.len,
            .described => |columns| columns.len,
        };
    }

    fn nameAt(self: ColumnDescriptionAdapter, idx: usize) []const u8 {
        return switch (self) {
            .plan => |columns| columns[idx].name,
            .described => |columns| columns[idx].name,
        };
    }
};

fn writeColumnDescriptions(writer: std.Io.AnyWriter, columns: ColumnDescriptionAdapter) !void {
    try writer.writeByte('T');
    var len: u32 = 4 + 2;
    for (0..columns.len()) |idx| {
        len += @as(u32, @intCast(columns.nameAt(idx).len + 19));
    }
    var buf4: [4]u8 = undefined;
    std.mem.writeInt(u32, buf4[0..4], len, .big);
    try writer.writeAll(buf4[0..4]);

    var buf2: [2]u8 = undefined;
    std.mem.writeInt(u16, buf2[0..2], @as(u16, @intCast(columns.len())), .big);
    try writer.writeAll(buf2[0..2]);

    const default_type = query_functions.Type.init(.value, true);
    for (0..columns.len()) |idx| {
        try writer.writeAll(columns.nameAt(idx));
        try writer.writeByte(0);

        std.mem.writeInt(u32, buf4[0..4], 0, .big);
        try writer.writeAll(buf4[0..4]);
        std.mem.writeInt(u16, buf2[0..2], 0, .big);
        try writer.writeAll(buf2[0..2]);
        const type_info = query_functions.pgTypeInfo(default_type);
        std.mem.writeInt(u32, buf4[0..4], type_info.oid, .big);
        try writer.writeAll(buf4[0..4]);
        std.mem.writeInt(i16, buf2[0..2], type_info.len, .big);
        try writer.writeAll(buf2[0..2]);
        std.mem.writeInt(i32, buf4[0..4], type_info.modifier, .big);
        try writer.writeAll(buf4[0..4]);
        std.mem.writeInt(u16, buf2[0..2], type_info.format, .big);
        try writer.writeAll(buf2[0..2]);
    }
}

fn formatSchemaNotice(alloc: std.mem.Allocator, columns: []const plan.ColumnInfo) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(alloc);
    var w = buf.writer(alloc);
    try w.writeAll("schema=[");
    const default_type = query_functions.Type.init(.value, true);
    for (columns, 0..) |col, idx| {
        if (idx != 0) try w.writeAll(", ");
        const type_name = query_functions.displayName(default_type);
        try w.writeAll("{name:\"");
        try w.writeAll(col.name);
        try w.writeAll("\",type:\"");
        try w.writeAll(type_name);
        try w.writeAll("\",nullable:");
        if (default_type.nullable) {
            try w.writeAll("true");
        } else {
            try w.writeAll("false");
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice(alloc);
}

fn formatTraceNotice(alloc: std.mem.Allocator, trace_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(alloc, "trace_id={s}", .{trace_id});
}

fn formatMetricsNotice(
    alloc: std.mem.Allocator,
    rows_emitted: usize,
    rows_scanned: u64,
    stream_ms: i64,
    plan_ms: i64,
) ![]u8 {
    return try std.fmt.allocPrint(
        alloc,
        "metrics rows={d} scanned={d} stream_ms={d} plan_ms={d}",
        .{ rows_emitted, rows_scanned, stream_ms, plan_ms },
    );
}

fn writeExecutionModeNotices(
    alloc: std.mem.Allocator,
    writer: std.Io.AnyWriter,
    execution_mode: []const u8,
    legacy_fallback: bool,
    fallback_reason: []const u8,
) !void {
    const mode_notice = try std.fmt.allocPrint(alloc, "execution_mode={s} legacy_fallback={}", .{ execution_mode, legacy_fallback });
    defer alloc.free(mode_notice);
    try protocol.writeNoticeResponse(writer, mode_notice);

    if (fallback_reason.len != 0) {
        const fallback_notice = try std.fmt.allocPrint(alloc, "fallback_reason={s}", .{fallback_reason});
        defer alloc.free(fallback_notice);
        try protocol.writeNoticeResponse(writer, fallback_notice);
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
) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "SELECT {d}", .{rows_emitted});
}

fn formatCommandTag(
    alloc: std.mem.Allocator,
    kind: frontend.stmt.StatementKind,
    rows_affected: usize,
) ![]const u8 {
    return switch (kind) {
        .select => try formatSelectTag(alloc, rows_affected),
        .insert => try std.fmt.allocPrint(alloc, "INSERT 0 {d}", .{rows_affected}),
        .delete => try std.fmt.allocPrint(alloc, "DELETE {d}", .{rows_affected}),
        .explain => try alloc.dupe(u8, "EXPLAIN"),
    };
}

test "formatSelectTag uses standard select tag" {
    const alloc = std.testing.allocator;
    const tag = try formatSelectTag(alloc, 5);
    defer alloc.free(tag);
    try std.testing.expectEqualStrings("SELECT 5", tag);
}

test "formatCommandTag renders direct write tags" {
    const alloc = std.testing.allocator;

    const insert_tag = try formatCommandTag(alloc, .insert, 2);
    defer alloc.free(insert_tag);
    try std.testing.expectEqualStrings("INSERT 0 2", insert_tag);

    const delete_tag = try formatCommandTag(alloc, .delete, 3);
    defer alloc.free(delete_tag);
    try std.testing.expectEqualStrings("DELETE 3", delete_tag);
}

test "formatMetricsNotice renders metrics" {
    const alloc = std.testing.allocator;
    const notice = try formatMetricsNotice(alloc, 1, 0, 0, 0);
    defer alloc.free(notice);
    try std.testing.expectEqualStrings("metrics rows=1 scanned=0 stream_ms=0 plan_ms=0", notice);
}

test "formatTraceNotice renders id" {
    const alloc = std.testing.allocator;
    const notice = try formatTraceNotice(alloc, "xyz");
    defer alloc.free(notice);
    try std.testing.expectEqualStrings("trace_id=xyz", notice);
}

test "writeExecutionModeNotices emits normalized fallback telemetry" {
    const alloc = std.testing.allocator;
    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    try writeExecutionModeNotices(alloc, anyWriter(&allocating_writer.writer), "translator", true, "frontend_lexer_mismatch");

    const written = allocating_writer.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "execution_mode=translator legacy_fallback=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "fallback_reason=frontend_lexer_mismatch") != null);
}

test "pgwireExecutionErrorContract maps stable sydraql failures" {
    const unsupported = pgwireExecutionErrorContract(error.UnsupportedFunction);
    try std.testing.expectEqualStrings("0A000", unsupported.sqlstate);
    try std.testing.expectEqualStrings(compiler_diagnostics.diagnosticMessage(.unsupported_function), unsupported.message);

    const missing_series = pgwireExecutionErrorContract(error.SeriesNotFound);
    try std.testing.expectEqualStrings("42P01", missing_series.sqlstate);
    try std.testing.expectEqualStrings(compiler_diagnostics.diagnosticMessage(.series_not_found), missing_series.message);

    const ambiguous = pgwireExecutionErrorContract(error.AmbiguousSelector);
    try std.testing.expectEqualStrings("22023", ambiguous.sqlstate);
    try std.testing.expectEqualStrings(compiler_diagnostics.diagnosticMessage(.ambiguous_selector), ambiguous.message);

    const shadow = pgwireExecutionErrorContract(error.ShadowMismatch);
    try std.testing.expectEqualStrings("XX000", shadow.sqlstate);
    try std.testing.expectEqualStrings(compiler_diagnostics.diagnosticMessage(.shadow_mismatch), shadow.message);

    const validation = pgwireExecutionErrorContract(error.ValidationFailed);
    try std.testing.expectEqualStrings("22023", validation.sqlstate);
    try std.testing.expectEqualStrings("validation failed", validation.message);

    const syntax = pgwireExecutionErrorContract(error.UnexpectedToken);
    try std.testing.expectEqualStrings("42601", syntax.sqlstate);
    try std.testing.expectEqualStrings("syntax error", syntax.message);
}

test "sql core prepared path handles simple select queries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-sql-core", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    const handled = try handleSqlCorePreparedQuery(alloc, anyWriter(&allocating_writer.writer), engine, "SELECT 1");
    try std.testing.expect(handled == .handled);
    try std.testing.expect(std.mem.indexOf(u8, allocating_writer.written(), "execution_mode=sql_core_vm") != null);
    try std.testing.expect(std.mem.indexOf(u8, allocating_writer.written(), "SELECT 1") != null);
}

test "sql core prepared path handles simple insert queries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-sql-core-insert", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    const handled = try handleSqlCorePreparedQuery(alloc, anyWriter(&allocating_writer.writer), engine, "INSERT INTO writes.simple(time, value) VALUES (10, 4)");
    try std.testing.expect(handled == .handled);
    try std.testing.expect(std.mem.indexOf(u8, allocating_writer.written(), "INSERT 0 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, allocating_writer.written(), "execution_mode=sql_core_vm") != null);

    const sid = @import("../../types.zig").seriesIdFrom("writes.simple", "{}");
    try waitForQueryablePoints(alloc, engine, sid, 1, 1_000);
}

test "sql core prepared path handles simple delete queries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-sql-core-delete", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    const sid = @import("../../types.zig").seriesIdFrom("writes.simple_delete", "{}");
    try engine.registerSeries("writes.simple_delete", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 30, .value = 3.0, .tags_json = "{}" });

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    const handled = try handleSqlCorePreparedQuery(
        alloc,
        anyWriter(&allocating_writer.writer),
        engine,
        "DELETE FROM writes.simple_delete WHERE time >= 20",
    );
    try std.testing.expect(handled == .handled);
    try std.testing.expect(std.mem.indexOf(u8, allocating_writer.written(), "DELETE 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, allocating_writer.written(), "execution_mode=sql_core_vm") != null);

    var points = std.array_list.Managed(@import("../../types.zig").Point).init(alloc);
    defer points.deinit();
    try engine.queryRange(sid, std.math.minInt(i64), std.math.maxInt(i64), &points);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(i64, 10), points.items[0].ts);
}

test "extended protocol executes direct SQL prepared statements" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-extended-sql-core", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    const sid = @import("../../types.zig").seriesIdFrom("ext.room1", "{}");
    try engine.registerSeries("ext.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 2, 1_000);

    var input = std.array_list.Managed(u8).init(alloc);
    defer input.deinit();
    try appendParseMessage(&input, "stmt1", "SELECT time, value FROM ext.room1 WHERE time >= $1 ORDER BY time ASC LIMIT 1", 1);
    try appendDescribeMessage(&input, 'S', "stmt1");
    try appendBindMessage(&input, "portal1", "stmt1", &.{"15"});
    try appendDescribeMessage(&input, 'P', "portal1");
    try appendExecuteMessage(&input, "portal1", 0);
    try appendFrontendMessage(&input, 'S', &.{});

    var read_stream = std.io.fixedBufferStream(input.items);
    var read_state = read_stream.reader();
    const reader = read_state.any();

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    try messageLoop(alloc, reader, anyWriter(&allocating_writer.writer), &allocating_writer.writer, engine);

    const written = allocating_writer.written();
    const message_types = try collectBackendMessageTypes(alloc, written);
    defer alloc.free(message_types);
    try std.testing.expectEqualSlices(u8, &.{ '1', 't', 'T', '2', 'T', 'D', 'C', 'Z' }, message_types);
    try std.testing.expect(std.mem.indexOf(u8, written, "SELECT 1") != null);
}

test "extended protocol executes direct SQL prepared inserts" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-extended-insert", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var input = std.array_list.Managed(u8).init(alloc);
    defer input.deinit();
    try appendParseMessage(&input, "stmt1", "INSERT INTO ext.inserted(time, value) VALUES ($1, $2)", 2);
    try appendDescribeMessage(&input, 'S', "stmt1");
    try appendBindMessage(&input, "portal1", "stmt1", &.{ "10", "4.5" });
    try appendDescribeMessage(&input, 'P', "portal1");
    try appendExecuteMessage(&input, "portal1", 0);
    try appendFrontendMessage(&input, 'S', &.{});

    var read_stream = std.io.fixedBufferStream(input.items);
    var read_state = read_stream.reader();
    const reader = read_state.any();

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    try messageLoop(alloc, reader, anyWriter(&allocating_writer.writer), &allocating_writer.writer, engine);

    const written = allocating_writer.written();
    const message_types = try collectBackendMessageTypes(alloc, written);
    defer alloc.free(message_types);
    try std.testing.expectEqualSlices(u8, &.{ '1', 't', 'n', '2', 'n', 'C', 'Z' }, message_types);
    try std.testing.expect(std.mem.indexOf(u8, written, "INSERT 0 1") != null);

    const sid = @import("../../types.zig").seriesIdFrom("ext.inserted", "{}");
    try waitForQueryablePoints(alloc, engine, sid, 1, 1_000);
}

test "extended protocol executes direct SQL prepared deletes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-extended-delete", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    const sid = @import("../../types.zig").seriesIdFrom("ext.deleted", "{}");
    try engine.registerSeries("ext.deleted", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 30, .value = 3.0, .tags_json = "{}" });

    var input = std.array_list.Managed(u8).init(alloc);
    defer input.deinit();
    try appendParseMessage(&input, "stmt1", "DELETE FROM ext.deleted WHERE time >= $1", 1);
    try appendDescribeMessage(&input, 'S', "stmt1");
    try appendBindMessage(&input, "portal1", "stmt1", &.{"20"});
    try appendDescribeMessage(&input, 'P', "portal1");
    try appendExecuteMessage(&input, "portal1", 0);
    try appendFrontendMessage(&input, 'S', &.{});

    var read_stream = std.io.fixedBufferStream(input.items);
    var read_state = read_stream.reader();
    const reader = read_state.any();

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    try messageLoop(alloc, reader, anyWriter(&allocating_writer.writer), &allocating_writer.writer, engine);

    const written = allocating_writer.written();
    const message_types = try collectBackendMessageTypes(alloc, written);
    defer alloc.free(message_types);
    try std.testing.expectEqualSlices(u8, &.{ '1', 't', 'n', '2', 'n', 'C', 'Z' }, message_types);
    try std.testing.expect(std.mem.indexOf(u8, written, "DELETE 2") != null);

    var points = std.array_list.Managed(@import("../../types.zig").Point).init(alloc);
    defer points.deinit();
    try engine.queryRange(sid, std.math.minInt(i64), std.math.maxInt(i64), &points);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(i64, 10), points.items[0].ts);
}

test "simple query writes explicit translator fallback notice for uncovered SQL" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-sql-fallback-notice", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    const sid = @import("../../types.zig").seriesIdFrom("fallback.regex", "{}");
    try engine.registerSeries("fallback.regex", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 1, 1_000);

    var payload = std.array_list.Managed(u8).init(alloc);
    defer payload.deinit();
    try payload.appendSlice("SELECT value FROM fallback.regex WHERE value =~ '1'");
    try payload.append(0);

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    try handleSimpleQuery(alloc, anyWriter(&allocating_writer.writer), payload.items, engine);

    const written = allocating_writer.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "execution_mode=translator legacy_fallback=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "fallback_reason=frontend_lexer_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "sql_prepare_fallback=translator reason=") != null);
}

test "extended protocol suspends and resumes portals" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-extended-suspend", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    const sid = @import("../../types.zig").seriesIdFrom("ext.suspend", "{}");
    try engine.registerSeries("ext.suspend", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 2, 1_000);

    var input = std.array_list.Managed(u8).init(alloc);
    defer input.deinit();
    try appendParseMessage(&input, "stmt1", "SELECT time, value FROM ext.suspend ORDER BY time ASC", 0);
    try appendBindMessage(&input, "portal1", "stmt1", &.{});
    try appendExecuteMessage(&input, "portal1", 1);
    try appendExecuteMessage(&input, "portal1", 1);
    try appendFrontendMessage(&input, 'S', &.{});

    var read_stream = std.io.fixedBufferStream(input.items);
    var read_state = read_stream.reader();
    const reader = read_state.any();

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    try messageLoop(alloc, reader, anyWriter(&allocating_writer.writer), &allocating_writer.writer, engine);

    const written = allocating_writer.written();
    const message_types = try collectBackendMessageTypes(alloc, written);
    defer alloc.free(message_types);
    try std.testing.expectEqualSlices(u8, &.{ '1', '2', 'D', 's', 'D', 'C', 'Z' }, message_types);
    try std.testing.expect(std.mem.indexOf(u8, written, "SELECT 2") != null);
}

test "extended protocol rejects binary result formats" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-extended-binary-result", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var input = std.array_list.Managed(u8).init(alloc);
    defer input.deinit();
    try appendParseMessage(&input, "stmt1", "SELECT 1", 0);
    try appendBindMessageWithFormats(&input, "portal1", "stmt1", &.{}, &.{}, &.{1});
    try appendFrontendMessage(&input, 'S', &.{});

    var read_stream = std.io.fixedBufferStream(input.items);
    var read_state = read_stream.reader();
    const reader = read_state.any();

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    try messageLoop(alloc, reader, anyWriter(&allocating_writer.writer), &allocating_writer.writer, engine);

    const written = allocating_writer.written();
    const message_types = try collectBackendMessageTypes(alloc, written);
    defer alloc.free(message_types);
    try std.testing.expectEqualSlices(u8, &.{ '1', 'E', 'Z' }, message_types);
    try std.testing.expect(std.mem.indexOf(u8, written, "binary result formats are not supported") != null);
}

test "extended protocol rejects unsupported direct prepare with stable feature-not-supported error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-extended-unsupported-prepare", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var input = std.array_list.Managed(u8).init(alloc);
    defer input.deinit();
    try appendParseMessage(&input, "stmt1", "SELECT value FROM ext.regex WHERE value =~ '1'", 0);
    try appendFrontendMessage(&input, 'S', &.{});

    var read_stream = std.io.fixedBufferStream(input.items);
    var read_state = read_stream.reader();
    const reader = read_state.any();

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    try messageLoop(alloc, reader, anyWriter(&allocating_writer.writer), &allocating_writer.writer, engine);

    const written = allocating_writer.written();
    const message_types = try collectBackendMessageTypes(alloc, written);
    defer alloc.free(message_types);
    try std.testing.expectEqualSlices(u8, &.{ 'E', 'Z' }, message_types);
    try std.testing.expect(std.mem.indexOf(u8, written, "0A000") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "SQL parse unsupported by direct prepare") != null);
}

test "simple query rejects oversized query text with stable program limit error" {
    const alloc = std.testing.allocator;
    const payload_len = query_common.max_query_text_bytes + 32;
    const payload = try alloc.alloc(u8, payload_len + 1);
    defer alloc.free(payload);
    @memset(payload[0..payload_len], 'x');
    payload[payload_len] = 0;

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    const engine = undefined;
    try handleSimpleQuery(alloc, anyWriter(&allocating_writer.writer), payload, engine);

    const written = allocating_writer.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "54000") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, query_common.query_text_too_large_message) != null);
}

test "simple query maps missing translated sydraql series to stable undefined-table error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-missing-series", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var payload = std.array_list.Managed(u8).init(alloc);
    defer payload.deinit();
    try payload.appendSlice("SELECT value FROM missing.series WHERE time >= 0");
    try payload.append(0);

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    try handleSimpleQuery(alloc, anyWriter(&allocating_writer.writer), payload.items, engine);

    const written = allocating_writer.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "42P01") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, compiler_diagnostics.diagnosticMessage(.series_not_found)) != null);
}

test "extended protocol rejects oversized parse text with stable program limit error" {
    const alloc = std.testing.allocator;
    const sql = try alloc.alloc(u8, query_common.max_query_text_bytes + 32);
    defer alloc.free(sql);
    @memset(sql, 'x');

    var input = std.array_list.Managed(u8).init(alloc);
    defer input.deinit();
    try appendParseMessage(&input, "stmt1", sql, 0);
    try appendFrontendMessage(&input, 'S', &.{});

    var read_stream = std.io.fixedBufferStream(input.items);
    var read_state = read_stream.reader();
    const reader = read_state.any();

    var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
    defer allocating_writer.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/pgwire-oversized-parse", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../../config.zig").Config = .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    try messageLoop(alloc, reader, anyWriter(&allocating_writer.writer), &allocating_writer.writer, engine);

    const written = allocating_writer.written();
    const message_types = try collectBackendMessageTypes(alloc, written);
    defer alloc.free(message_types);
    try std.testing.expectEqualSlices(u8, &.{ 'E', 'Z' }, message_types);
    try std.testing.expect(std.mem.indexOf(u8, written, "54000") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, query_common.query_text_too_large_message) != null);
}

fn appendFrontendMessage(buffer: *std.array_list.Managed(u8), msg_type: u8, payload: []const u8) !void {
    try buffer.append(msg_type);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, len_buf[0..4], @as(u32, @intCast(payload.len + 4)), .big);
    try buffer.appendSlice(len_buf[0..4]);
    try buffer.appendSlice(payload);
}

fn appendParseMessage(buffer: *std.array_list.Managed(u8), statement_name: []const u8, sql: []const u8, parameter_slots: u16) !void {
    var payload = std.array_list.Managed(u8).init(buffer.allocator);
    defer payload.deinit();
    try payload.appendSlice(statement_name);
    try payload.append(0);
    try payload.appendSlice(sql);
    try payload.append(0);
    var buf2: [2]u8 = undefined;
    std.mem.writeInt(u16, buf2[0..2], parameter_slots, .big);
    try payload.appendSlice(buf2[0..2]);
    var buf4: [4]u8 = undefined;
    for (0..parameter_slots) |_| {
        std.mem.writeInt(u32, buf4[0..4], 0, .big);
        try payload.appendSlice(buf4[0..4]);
    }
    try appendFrontendMessage(buffer, 'P', payload.items);
}

fn appendBindMessage(buffer: *std.array_list.Managed(u8), portal_name: []const u8, statement_name: []const u8, parameters: []const []const u8) !void {
    try appendBindMessageWithFormats(buffer, portal_name, statement_name, parameters, &.{}, &.{});
}

fn appendBindMessageWithFormats(
    buffer: *std.array_list.Managed(u8),
    portal_name: []const u8,
    statement_name: []const u8,
    parameters: []const []const u8,
    parameter_formats: []const u16,
    result_formats: []const u16,
) !void {
    var payload = std.array_list.Managed(u8).init(buffer.allocator);
    defer payload.deinit();
    try payload.appendSlice(portal_name);
    try payload.append(0);
    try payload.appendSlice(statement_name);
    try payload.append(0);
    var buf2: [2]u8 = undefined;
    std.mem.writeInt(u16, buf2[0..2], @as(u16, @intCast(parameter_formats.len)), .big);
    try payload.appendSlice(buf2[0..2]);
    for (parameter_formats) |format_code| {
        std.mem.writeInt(u16, buf2[0..2], format_code, .big);
        try payload.appendSlice(buf2[0..2]);
    }
    std.mem.writeInt(u16, buf2[0..2], @as(u16, @intCast(parameters.len)), .big);
    try payload.appendSlice(buf2[0..2]);
    var buf4: [4]u8 = undefined;
    for (parameters) |parameter| {
        std.mem.writeInt(i32, buf4[0..4], @as(i32, @intCast(parameter.len)), .big);
        try payload.appendSlice(buf4[0..4]);
        try payload.appendSlice(parameter);
    }
    std.mem.writeInt(u16, buf2[0..2], @as(u16, @intCast(result_formats.len)), .big);
    try payload.appendSlice(buf2[0..2]);
    for (result_formats) |format_code| {
        std.mem.writeInt(u16, buf2[0..2], format_code, .big);
        try payload.appendSlice(buf2[0..2]);
    }
    try appendFrontendMessage(buffer, 'B', payload.items);
}

fn appendDescribeMessage(buffer: *std.array_list.Managed(u8), target: u8, name: []const u8) !void {
    var payload = std.array_list.Managed(u8).init(buffer.allocator);
    defer payload.deinit();
    try payload.append(target);
    try payload.appendSlice(name);
    try payload.append(0);
    try appendFrontendMessage(buffer, 'D', payload.items);
}

fn appendExecuteMessage(buffer: *std.array_list.Managed(u8), portal_name: []const u8, max_rows: i32) !void {
    var payload = std.array_list.Managed(u8).init(buffer.allocator);
    defer payload.deinit();
    try payload.appendSlice(portal_name);
    try payload.append(0);
    var buf4: [4]u8 = undefined;
    std.mem.writeInt(i32, buf4[0..4], max_rows, .big);
    try payload.appendSlice(buf4[0..4]);
    try appendFrontendMessage(buffer, 'E', payload.items);
}

fn collectBackendMessageTypes(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        try out.append(bytes[cursor]);
        cursor += 1;
        if (bytes.len < cursor + 4) return error.InvalidMessageLength;
        const length = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(bytes[cursor .. cursor + 4].ptr)), .big);
        cursor += 4;
        if (length < 4) return error.InvalidMessageLength;
        cursor += length - 4;
    }
    return try out.toOwnedSlice();
}

fn waitForQueryablePoints(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    series_id: @import("../../types.zig").SeriesId,
    expected_count: usize,
    timeout_ms: u64,
) !void {
    return engine.waitForQueryablePoints(allocator, series_id, expected_count, timeout_ms);
}
