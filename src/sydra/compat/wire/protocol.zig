const std = @import("std");

pub const ssl_request_code: u32 = 80877103;
pub const cancel_request_code: u32 = 80877102;
pub const protocol_version_3: u32 = 3 << 16; // 3.0 (196608)

pub const StartupOptions = struct {
    /// Whether the server intends to upgrade the connection to TLS.
    /// We decline SSL for now but keep the flag so we can support it later.
    allow_ssl: bool = false,
};

pub const Parameter = struct {
    key: []const u8,
    value: []const u8,
};

pub const StartupRequest = struct {
    protocol_version: u32,
    parameters: []Parameter = &[_]Parameter{},
    ssl_request_seen: bool = false,

    pub fn deinit(self: *StartupRequest, alloc: std.mem.Allocator) void {
        for (self.parameters) |param| {
            alloc.free(param.key);
            alloc.free(param.value);
        }
        alloc.free(self.parameters);
        self.* = .{
            .protocol_version = 0,
            .parameters = &[_]Parameter{},
            .ssl_request_seen = false,
        };
    }

    pub fn find(self: StartupRequest, key: []const u8) ?[]const u8 {
        for (self.parameters) |param| {
            if (std.mem.eql(u8, param.key, key)) return param.value;
        }
        return null;
    }
};

fn readU32(reader: anytype) !u32 {
    var buf: [4]u8 = undefined;
    try reader.readNoEof(&buf);
    return std.mem.readInt(u32, &buf, .big);
}

fn appendParameter(
    alloc: std.mem.Allocator,
    list: *std.array_list.Managed(Parameter),
    key_slice: []const u8,
    value_slice: []const u8,
) !void {
    const key_copy = try alloc.dupe(u8, key_slice);
    errdefer alloc.free(key_copy);
    const value_copy = try alloc.dupe(u8, value_slice);
    errdefer alloc.free(value_copy);
    try list.append(.{ .key = key_copy, .value = value_copy });
}

/// Consumes the PostgreSQL startup negotiation and returns parsed parameters.
/// The caller is responsible for sending AuthenticationOk/ParameterStatus/etc.
pub fn readStartup(
    alloc: std.mem.Allocator,
    reader: anytype,
    writer: anytype,
    options: StartupOptions,
) !StartupRequest {
    var request = StartupRequest{
        .protocol_version = 0,
    };
    errdefer request.deinit(alloc);

    var params = std.array_list.Managed(Parameter).init(alloc);
    defer params.deinit();

    var ssl_seen = false;

    while (true) {
        const total_len = try readU32(reader);
        if (total_len < 8) return error.InvalidStartupLength;
        const body_len = total_len - 4;
        var body = try alloc.alloc(u8, body_len);
        defer alloc.free(body);
        try reader.readNoEof(body);

        const protocol = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(body[0..4].ptr)), .big);

        if (protocol == ssl_request_code) {
            if (options.allow_ssl) {
                // TLS handshake support is future work; surface positive acknowledgement once ready.
                try writer.writeAll("S");
            } else {
                try writer.writeAll("N");
            }
            ssl_seen = true;
            continue;
        }

        if (protocol == cancel_request_code) {
            return error.CancelRequestUnsupported;
        }

        if ((protocol & 0xFFFF0000) != protocol_version_3) {
            return error.UnsupportedProtocol;
        }

        request.protocol_version = protocol;
        request.ssl_request_seen = ssl_seen;

        var idx: usize = 4;
        while (idx < body.len) {
            const key_end = std.mem.indexOfScalarPos(u8, body, idx, 0) orelse return error.MalformedStartupPacket;
            if (key_end == idx) {
                // Reached the trailing NUL terminator.
                break;
            }
            const val_start = key_end + 1;
            if (val_start >= body.len) return error.MalformedStartupPacket;
            const val_end = std.mem.indexOfScalarPos(u8, body, val_start, 0) orelse return error.MalformedStartupPacket;
            const key_slice = body[idx..key_end];
            const value_slice = body[val_start..val_end];
            try appendParameter(alloc, &params, key_slice, value_slice);
            idx = val_end + 1;
        }

        break;
    }

    request.parameters = try params.toOwnedSlice();
    return request;
}

pub fn writeAuthenticationOk(writer: anytype) !void {
    var buf: [9]u8 = undefined;
    buf[0] = 'R';
    std.mem.writeInt(u32, buf[1..5], 8, .big);
    std.mem.writeInt(u32, buf[5..9], 0, .big);
    try writer.writeAll(buf[0..9]);
}

pub fn writeParameterStatus(writer: anytype, key: []const u8, value: []const u8) !void {
    var length: u32 = 4 + 1 + 1; // initial length field + two terminators
    length += @intCast(key.len);
    length += @intCast(value.len);

    try writer.writeByte('S');
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], length, .big);
    try writer.writeAll(buf[0..4]);
    try writer.writeAll(key);
    try writer.writeByte(0);
    try writer.writeAll(value);
    try writer.writeByte(0);
}

pub fn writeReadyForQuery(writer: anytype, status: u8) !void {
    var buf: [6]u8 = undefined;
    buf[0] = 'Z';
    std.mem.writeInt(u32, buf[1..5], 5, .big);
    buf[5] = status;
    try writer.writeAll(buf[0..6]);
}

pub fn writeCommandComplete(writer: anytype, tag: []const u8) !void {
    try writer.writeByte('C');
    var length_buf: [4]u8 = undefined;
    const length: u32 = 4 + @as(u32, @intCast(tag.len + 1));
    std.mem.writeInt(u32, length_buf[0..4], length, .big);
    try writer.writeAll(length_buf[0..4]);
    try writer.writeAll(tag);
    try writer.writeByte(0);
}

pub fn writeEmptyQueryResponse(writer: anytype) !void {
    try writer.writeByte('I');
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 4, .big);
    try writer.writeAll(buf[0..4]);
}

pub fn writeErrorResponse(writer: anytype, severity: []const u8, code: []const u8, message: []const u8) !void {
    try writer.writeByte('E');
    var length: u32 = 4 + 1; // length field + terminating zero
    length += @intCast(severity.len + code.len + message.len + 3); // fields identifiers
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], length, .big);
    try writer.writeAll(buf[0..4]);
    try writer.writeByte('S');
    try writer.writeAll(severity);
    try writer.writeByte(0);
    try writer.writeByte('C');
    try writer.writeAll(code);
    try writer.writeByte(0);
    try writer.writeByte('M');
    try writer.writeAll(message);
    try writer.writeByte(0);
    try writer.writeByte(0);
}

pub fn writeNoticeResponse(writer: anytype, message: []const u8) !void {
    const severity = "NOTICE";
    try writer.writeByte('N');
    var length: u32 = 4 + 1;
    length += @intCast(severity.len + 2);
    length += @intCast(message.len + 2);
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], length, .big);
    try writer.writeAll(buf[0..4]);
    try writer.writeByte('S');
    try writer.writeAll(severity);
    try writer.writeByte(0);
    try writer.writeByte('M');
    try writer.writeAll(message);
    try writer.writeByte(0);
    try writer.writeByte(0);
}

pub fn formatParameters(params: []Parameter, writer: anytype) !void {
    var first = true;
    for (params) |param| {
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.print("{s}={s}", .{ param.key, param.value });
    }
}

fn buildStartupMessage(allocator: std.mem.Allocator, pairs: []const Parameter) ![]u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], protocol_version_3);
    try body.appendSlice(buf[0..4]);

    for (pairs) |param| {
        try body.appendSlice(param.key);
        try body.append(0);
        try body.appendSlice(param.value);
        try body.append(0);
    }
    try body.append(0);

    const total_len: u32 = @intCast(body.items.len + 4);
    var message = try allocator.alloc(u8, body.items.len + 4);
    std.mem.writeInt(u32, message[0..4], total_len, .big);
    @memcpy(message[4..], body.items);
    return message;
}

test "read startup parses parameters and emits basic responses" {
    const alloc = std.testing.allocator;

    const pairs = [_]Parameter{
        .{ .key = "user", .value = "sydra" },
        .{ .key = "database", .value = "sydradb" },
        .{ .key = "application_name", .value = "psql" },
    };

    const startup = try buildStartupMessage(alloc, &pairs);
    defer alloc.free(startup);

    var input = std.array_list.Managed(u8).init(alloc);
    defer input.deinit();

    // SSLRequest
    {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], 8, .big);
        try input.appendSlice(buf[0..4]);
        std.mem.writeInt(u32, buf[0..4], ssl_request_code, .big);
        try input.appendSlice(buf[0..4]);
    }

    try input.appendSlice(startup);

    var read_stream = std.io.fixedBufferStream(input.items);
    var read_state = read_stream.reader();
    const reader = read_state.any();
    var write_buffer: [256]u8 = undefined;
    var write_stream = std.io.fixedBufferStream(write_buffer[0..]);
    var write_state = write_stream.writer();
    const writer = write_state.any();

    var req = try readStartup(alloc, reader, writer, .{});
    defer req.deinit(alloc);

    try std.testing.expect(req.ssl_request_seen);
    try std.testing.expectEqual(protocol_version_3, req.protocol_version);
    try std.testing.expectEqual(@as(usize, 3), req.parameters.len);
    try std.testing.expectEqualStrings("sydra", req.find("user").?);
    try std.testing.expectEqualStrings("sydradb", req.find("database").?);

    // SSL decline should have written a single 'N'
    try std.testing.expectEqual(@as(usize, 1), write_stream.pos);
    try std.testing.expectEqual(@as(u8, 'N'), write_buffer[0]);

    try writeAuthenticationOk(writer);
    try writeParameterStatus(writer, "server_version", "15.2");
    try writeReadyForQuery(writer, 'I');

    const written = write_stream.buffer[0..write_stream.pos];
    const expected_prefix = [_]u8{
        'N',
        'R',
        0,
        0,
        0,
        8,
        0,
        0,
        0,
        0,
        'S',
    };
    try std.testing.expect(std.mem.startsWith(u8, written, &expected_prefix));

    // Verify ReadyForQuery trailer
    try std.testing.expectEqual(@as(u8, 'Z'), written[written.len - 6]);
    try std.testing.expectEqual(@as(u8, 'I'), written[written.len - 1]);
}
