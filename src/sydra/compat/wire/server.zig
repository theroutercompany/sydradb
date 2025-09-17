const std = @import("std");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const translator = @import("../../query/translator.zig");

const log = std.log.scoped(.pgwire);

const max_message_size: usize = 16 * 1024 * 1024;

pub const ServerConfig = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 6432,
    session: session_mod.SessionConfig = .{},
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
        handleConnection(alloc, connection, config.session) catch |err| switch (err) {
            error.EndOfStream => {},
            else => log.warn("pgwire connection ended with {s}", .{@errorName(err)}),
        };
    }
}

pub fn handleConnection(
    alloc: std.mem.Allocator,
    connection: std.net.Server.Connection,
    session_config: session_mod.SessionConfig,
) !void {
    defer connection.stream.close();

    const handshake_reader = connection.stream.reader();
    const handshake_writer = connection.stream.writer();

    var session = session_mod.performHandshake(alloc, handshake_reader, handshake_writer, session_config) catch |err| {
        switch (err) {
            session_mod.HandshakeError.MissingUser,
            session_mod.HandshakeError.InvalidStartup,
            session_mod.HandshakeError.UnsupportedProtocol,
            session_mod.HandshakeError.CancelRequestUnsupported,
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

    var reader = connection.stream.reader();
    var writer = connection.stream.writer();

    try messageLoop(alloc, &reader, &writer);
}

fn messageLoop(
    alloc: std.mem.Allocator,
    reader: *std.net.Stream.Reader,
    writer: *std.net.Stream.Writer,
) !void {
    while (true) {
        const type_byte = reader.*.readByte() catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        const message_length = try readU32(reader);
        if (message_length < 4) return error.InvalidMessageLength;
        const payload_len = message_length - 4;
        if (payload_len > max_message_size) return error.MessageTooLarge;

        const payload_storage = try alloc.alloc(u8, payload_len);
        defer alloc.free(payload_storage);
        try reader.*.readNoEof(payload_storage);

        switch (type_byte) {
            'X' => return,
            'Q' => {
                try handleSimpleQuery(alloc, writer, payload_storage);
            },
            'P' => {
                try handleParseMessage(alloc, writer, payload_storage);
            },
            'S' => {
                try protocol.writeReadyForQuery(writer.*, 'I');
            },
            else => {
                log.debug("frontend message {c} unsupported", .{type_byte});
                try protocol.writeErrorResponse(writer.*, "ERROR", "0A000", "message type not implemented");
                try protocol.writeReadyForQuery(writer.*, 'I');
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

fn readU32(reader: *std.net.Stream.Reader) !u32 {
    var buf: [4]u8 = undefined;
    try reader.*.readNoEof(&buf);
    return std.mem.readInt(u32, &buf, .big);
}

fn handleSimpleQuery(
    alloc: std.mem.Allocator,
    writer: *std.net.Stream.Writer,
    payload: []u8,
) !void {
    const raw_sql = trimNullTerminator(payload);
    const trimmed = std.mem.trim(u8, raw_sql, " \t\r\n");
    if (trimmed.len == 0) {
        try protocol.writeEmptyQueryResponse(writer.*);
        try protocol.writeReadyForQuery(writer.*, 'I');
        return;
    }

    log.debug("simple query received: {s}", .{trimmed});

    const translation = translator.translate(alloc, trimmed) catch |err| switch (err) {
        error.OutOfMemory => {
            try protocol.writeErrorResponse(writer.*, "FATAL", "53100", "out of memory during translation");
            try protocol.writeReadyForQuery(writer.*, 'I');
            return;
        },
    };

    switch (translation) {
        .success => |success| {
            defer alloc.free(success.sydraql);
            try protocol.writeErrorResponse(writer.*, "ERROR", "0A000", "execution bridge not implemented yet");
        },
        .failure => |failure| {
            const msg = if (failure.message.len == 0)
                "translation failed"
            else
                failure.message;
            try protocol.writeErrorResponse(writer.*, "ERROR", failure.sqlstate, msg);
        },
    }

    try protocol.writeReadyForQuery(writer.*, 'I');
}

fn handleParseMessage(
    alloc: std.mem.Allocator,
    writer: *std.net.Stream.Writer,
    payload: []u8,
) !void {
    var cursor: usize = 0;
    const statement_name = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer.*, "ERROR", "08P01", "malformed parse message");
        try protocol.writeReadyForQuery(writer.*, 'I');
        return;
    };

    const query_bytes = readCString(payload, &cursor) catch {
        try protocol.writeErrorResponse(writer.*, "ERROR", "08P01", "malformed parse message");
        try protocol.writeReadyForQuery(writer.*, 'I');
        return;
    };

    if (payload.len < cursor + 2) {
        try protocol.writeErrorResponse(writer.*, "ERROR", "08P01", "parse message truncated");
        try protocol.writeReadyForQuery(writer.*, 'I');
        return;
    }

    const parameter_count = std.mem.readInt(u16, payload[cursor .. cursor + 2], .big);
    cursor += 2;
    const expected_bytes = @as(usize, parameter_count) * 4;
    if (payload.len < cursor + expected_bytes) {
        try protocol.writeErrorResponse(writer.*, "ERROR", "08P01", "parse message truncated");
        try protocol.writeReadyForQuery(writer.*, 'I');
        return;
    }

    const trimmed = std.mem.trim(u8, query_bytes, " \t\r\n");
    log.debug(
        "parse message for statement '{s}' sql='{s}'",
        .{ statement_name, trimmed },
    );

    const translation = translator.translate(alloc, trimmed) catch |err| switch (err) {
        error.OutOfMemory => {
            try protocol.writeErrorResponse(writer.*, "FATAL", "53100", "out of memory during translation");
            try protocol.writeReadyForQuery(writer.*, 'I');
            return;
        },
    };

    switch (translation) {
        .success => |success| {
            defer alloc.free(success.sydraql);
            try protocol.writeErrorResponse(writer.*, "ERROR", "0A000", "extended protocol not implemented yet");
        },
        .failure => |failure| {
            const msg = if (failure.message.len == 0)
                "translation failed"
            else
                failure.message;
            try protocol.writeErrorResponse(writer.*, "ERROR", failure.sqlstate, msg);
        },
    }

    try protocol.writeReadyForQuery(writer.*, 'I');
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
