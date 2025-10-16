const std = @import("std");
const protocol = @import("protocol.zig");

pub const SessionConfig = struct {
    server_version: []const u8 = "15.2",
    server_encoding: []const u8 = "UTF8",
    client_encoding: []const u8 = "UTF8",
    date_style: []const u8 = "ISO, MDY",
    time_zone: []const u8 = "UTC",
    integer_datetimes: []const u8 = "on",
    standard_conforming_strings: []const u8 = "on",
    default_database: ?[]const u8 = null,
    application_name_prefix: []const u8 = "sydradb",
};

pub const Session = struct {
    alloc: std.mem.Allocator,
    user: []const u8,
    database: []const u8,
    application_name: []const u8,
    parameters: []protocol.Parameter,

    pub fn deinit(self: Session) void {
        for (self.parameters) |param| {
            self.alloc.free(@constCast(param.key));
            self.alloc.free(@constCast(param.value));
        }
        self.alloc.free(self.parameters);
        self.alloc.free(@constCast(self.user));
        self.alloc.free(@constCast(self.database));
        self.alloc.free(@constCast(self.application_name));
    }

    pub fn borrowedUser(self: Session) []const u8 {
        return self.user;
    }

    pub fn borrowedDatabase(self: Session) []const u8 {
        return self.database;
    }

    pub fn borrowedApplicationName(self: Session) []const u8 {
        return self.application_name;
    }
};

pub const HandshakeError = error{
    MissingUser,
    InvalidStartup,
    UnsupportedProtocol,
    CancelRequestUnsupported,
    OutOfMemory,
};

fn duplicateParameters(alloc: std.mem.Allocator, params: []protocol.Parameter) ![]protocol.Parameter {
    const out = try alloc.alloc(protocol.Parameter, params.len);
    var idx: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < idx) : (i += 1) {
            alloc.free(@constCast(out[i].key));
            alloc.free(@constCast(out[i].value));
        }
        alloc.free(out);
    }
    while (idx < params.len) : (idx += 1) {
        out[idx] = .{
            .key = try alloc.dupe(u8, params[idx].key),
            .value = try alloc.dupe(u8, params[idx].value),
        };
    }
    return out;
}

pub fn performHandshake(
    alloc: std.mem.Allocator,
    reader: anytype,
    writer: anytype,
    config: SessionConfig,
) HandshakeError!Session {
    var startup = protocol.readStartup(alloc, reader, writer, .{}) catch |err| switch (err) {
        error.UnsupportedProtocol => return HandshakeError.UnsupportedProtocol,
        error.CancelRequestUnsupported => return HandshakeError.CancelRequestUnsupported,
        else => return HandshakeError.InvalidStartup,
    };
    errdefer startup.deinit(alloc);

    const user_param = startup.find("user") orelse {
        protocol.writeErrorResponse(writer, "FATAL", "28000", "user parameter required") catch return HandshakeError.InvalidStartup;
        return HandshakeError.MissingUser;
    };

    const db_param = startup.find("database") orelse config.default_database orelse user_param;
    const app_param = startup.find("application_name") orelse config.application_name_prefix;

    const user_copy = try alloc.dupe(u8, user_param);
    errdefer alloc.free(user_copy);
    const db_copy = try alloc.dupe(u8, db_param);
    errdefer alloc.free(db_copy);
    const app_copy = try alloc.dupe(u8, app_param);
    errdefer alloc.free(app_copy);

    const param_copies = try duplicateParameters(alloc, startup.parameters);
    errdefer {
        for (param_copies) |param| {
            alloc.free(@constCast(param.key));
            alloc.free(@constCast(param.value));
        }
        alloc.free(param_copies);
    }

    protocol.writeAuthenticationOk(writer) catch return HandshakeError.InvalidStartup;

    const status_pairs = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "server_version", .value = config.server_version },
        .{ .key = "server_encoding", .value = config.server_encoding },
        .{ .key = "client_encoding", .value = config.client_encoding },
        .{ .key = "application_name", .value = app_param },
        .{ .key = "DateStyle", .value = config.date_style },
        .{ .key = "TimeZone", .value = config.time_zone },
        .{ .key = "integer_datetimes", .value = config.integer_datetimes },
        .{ .key = "standard_conforming_strings", .value = config.standard_conforming_strings },
    };

    for (status_pairs) |pair| {
        protocol.writeParameterStatus(writer, pair.key, pair.value) catch return HandshakeError.InvalidStartup;
    }

    protocol.writeReadyForQuery(writer, 'I') catch return HandshakeError.InvalidStartup;

    startup.deinit(alloc);

    return Session{
        .alloc = alloc,
        .user = user_copy,
        .database = db_copy,
        .application_name = app_copy,
        .parameters = param_copies,
    };
}

fn buildStartupBuffer(allocator: std.mem.Allocator, params: []const protocol.Parameter) ![]u8 {
    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], protocol.protocol_version_3);
    try body.appendSlice(buf[0..4]);

    for (params) |param| {
        try body.appendSlice(param.key);
        try body.append(0);
        try body.appendSlice(param.value);
        try body.append(0);
    }
    try body.append(0);

    const total_len = @as(u32, @intCast(body.items.len + 4));
    var out = try allocator.alloc(u8, body.items.len + 4);
    std.mem.writeInt(u32, out[0..4], total_len, .big);
    @memcpy(out[4..], body.items);
    return out;
}

fn appendSslRequest(buffer: *std.ArrayList(u8)) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, len_buf[0..4], 8, .big);
    try buffer.appendSlice(len_buf);
    std.mem.writeInt(u32, len_buf[0..4], protocol.ssl_request_code, .big);
    try buffer.appendSlice(len_buf);
}

test "performHandshake returns session metadata and writes responses" {
    const alloc = std.testing.allocator;

    const params = [_]protocol.Parameter{
        .{ .key = "user", .value = "alice" },
        .{ .key = "database", .value = "analytics" },
        .{ .key = "application_name", .value = "psql" },
    };

    const startup = try buildStartupBuffer(alloc, &params);
    defer alloc.free(startup);

    var inbound = std.ArrayList(u8).init(alloc);
    defer inbound.deinit();
    try appendSslRequest(&inbound);
    try inbound.appendSlice(startup);

    var reader_stream = std.io.fixedBufferStream(inbound.items);
    var write_storage: [512]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(write_storage[0..]);

    var session = performHandshake(alloc, reader_stream.reader(), writer_stream.writer(), .{}) catch unreachable;
    defer session.deinit();

    try std.testing.expectEqualStrings("alice", session.borrowedUser());
    try std.testing.expectEqualStrings("analytics", session.borrowedDatabase());
    try std.testing.expectEqualStrings("psql", session.borrowedApplicationName());
    try std.testing.expectEqual(@as(usize, 3), session.parameters.len);

    const written = writer_stream.buffer[0..writer_stream.pos];
    try std.testing.expect(std.mem.indexOfScalar(u8, written, 'N') != null); // SSL decline
    try std.testing.expect(std.mem.indexOf(u8, written, "server_version") != null);
    try std.testing.expect(written[written.len - 6] == 'Z');
}
