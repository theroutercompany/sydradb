const std = @import("std");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");

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

    const reader = connection.stream.reader();
    const writer = connection.stream.writer();

    try messageLoop(alloc, reader, writer);
}

fn messageLoop(
    alloc: std.mem.Allocator,
    reader: std.net.Stream.Reader,
    writer: std.net.Stream.Writer,
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
                const query = trimNullTerminator(payload_storage);
                log.debug("simple query received: {s}", .{query});
                try protocol.writeErrorResponse(writer, "ERROR", "0A000", "simple query not implemented");
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

fn readU32(reader: std.net.Stream.Reader) !u32 {
    var buf: [4]u8 = undefined;
    try reader.readNoEof(&buf);
    return std.mem.readInt(u32, &buf, .big);
}

fn parseAddress(host: []const u8, port: u16) !std.net.Address {
    return std.net.Address.parseIp4(host, port) catch {
        return std.net.Address.parseIp6(host, port) catch {
            return error.InvalidAddress;
        };
    };
}
