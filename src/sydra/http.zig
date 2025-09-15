const std = @import("std");
const Engine = @import("engine.zig").Engine;
const types = @import("types.zig");
const config = @import("config.zig");

pub fn runHttp(alloc: std.mem.Allocator, eng: *Engine, port: u16) !void {
    var address = try std.net.Address.parseIp4("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const connection = server.accept() catch |err| switch (err) {
            error.ConnectionResetByPeer, error.ConnectionAborted => continue,
            else => return err,
        };
        handleConnection(alloc, eng, connection) catch |err| switch (err) {
            error.HttpConnectionClosing, error.HttpRequestTruncated => {},
            else => std.log.warn("http connection error: {s}", .{@errorName(err)}),
        };
    }
}

fn handleConnection(alloc: std.mem.Allocator, eng: *Engine, connection: std.net.Server.Connection) !void {
    defer connection.stream.close();

    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var reader_state = connection.stream.reader(&recv_buffer);
    var writer_state = connection.stream.writer(&send_buffer);
    var http_server: std.http.Server = .init(reader_state.interface(), &writer_state.interface);

    while (true) {
        var req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing, error.HttpRequestTruncated => return,
            else => return err,
        };
        handleRequest(alloc, eng, &req) catch |err| switch (err) {
            error.HttpExpectationFailed => {
                _ = req.respond("expectation failed", .{ .status = .expectation_failed, .keep_alive = false }) catch {};
                return;
            },
            else => return err,
        };
    }
}

fn handleRequest(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const path = req.head.target;
    const method = req.head.method;

    if (std.mem.startsWith(u8, path, "/api/") and eng.config.auth_token.len != 0) {
        const maybe_auth = findHeader(req, "authorization");
        if (maybe_auth) |auth| {
            if (!(std.mem.startsWith(u8, auth, "Bearer ") and std.mem.eql(u8, auth[7..], eng.config.auth_token))) {
                try req.respond("unauthorized", .{ .status = .unauthorized, .keep_alive = false });
                return;
            }
        } else {
            try req.respond("unauthorized", .{ .status = .unauthorized, .keep_alive = false });
            return;
        }
    }

    if (std.mem.eql(u8, path, "/metrics") and method == .GET) {
        return try handleMetrics(req);
    }
    if (std.mem.eql(u8, path, "/api/v1/ingest") and method == .POST) {
        return try handleIngest(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/query/range") and method == .POST) {
        return try handleQuery(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/query/find") and method == .POST) {
        return try handleFind(alloc, eng, req);
    }

    try req.respond("not found", .{ .status = .not_found });
}

fn findHeader(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn handleMetrics(req: *std.http.Server.Request) !void {
    const body = "# HELP sydradb_up 1 if server is up\n# TYPE sydradb_up gauge\nsydradb_up 1\n";
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "text/plain; version=0.0.4" }};
    try req.respond(body, .{ .extra_headers = &headers });
}

fn handleIngest(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buffer: [4096]u8 = undefined;
    var body_reader = try req.readerExpectContinue(&body_buffer);
    var compat_body_reader = body_reader.adaptToOldInterface();
    var count: usize = 0;

    while (true) {
        const line_opt = try compat_body_reader.readUntilDelimiterOrEofAlloc(alloc, '\n', 1024 * 64);
        if (line_opt == null) break;
        defer alloc.free(line_opt.?);
        const line = std.mem.trim(u8, line_opt.?, " \t\r\n");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = parsed.value.object;
        const series = obj.get("series").?.string;
        const ts: i64 = @intCast(obj.get("ts").?.integer);
        const value: f64 = if (obj.get("value")) |v| switch (v) {
            .float => v.float,
            .integer => @floatFromInt(v.integer),
            else => 0,
        } else blk: {
            if (obj.get("fields")) |fields_val| {
                if (fields_val == .object) {
                    var it = fields_val.object.iterator();
                    while (it.next()) |e| switch (e.value_ptr.*) {
                        .float => break :blk e.value_ptr.float,
                        .integer => break :blk @floatFromInt(e.value_ptr.integer),
                        else => {},
                    };
                }
            }
            break :blk 0;
        };
        const default_tags = [_]u8{ '{', '}' };
        var tags_json: []const u8 = &default_tags;
        var tags_owned: ?[]u8 = null;
        if (obj.get("tags")) |v| {
            if (v == .object) {
                var out: std.io.Writer.Allocating = .init(alloc);
                var jws: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
                try jws.write(v);
                tags_owned = try alloc.dupe(u8, out.writer.buffer[0..out.writer.end]);
                out.deinit();
                tags_json = tags_owned.?;
            }
        }
        const sid = types.seriesIdFrom(series, tags_json);
        try eng.ingest(.{ .series_id = sid, .ts = ts, .value = value, .tags_json = try alloc.dupe(u8, tags_json) });
        eng.noteTags(sid, tags_json);
        if (tags_owned) |buf| alloc.free(buf);
        count += 1;
    }

    var buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ingested\":{d}}}", .{count});
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(body, .{ .extra_headers = &headers });
}

fn handleQuery(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buffer: [4096]u8 = undefined;
    var reader = try req.readerExpectContinue(&body_buffer);
    var compat_reader = reader.adaptToOldInterface();
    const body = try compat_reader.readAllAlloc(alloc, 1024 * 64);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var series_id: types.SeriesId = 0;
    if (obj.get("series_id")) |v| series_id = @intCast(v.integer) else if (obj.get("series")) |v| series_id = types.hash64(v.string);
    const start_ts: i64 = @intCast(obj.get("start").?.integer);
    const end_ts: i64 = @intCast(obj.get("end").?.integer);

    var points = try std.ArrayList(types.Point).initCapacity(alloc, 0);
    defer points.deinit(alloc);
    try eng.queryRange(series_id, start_ts, end_ts, &points);

    var send_buffer: [1024]u8 = undefined;
    var writer = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer writer.end() catch {};

    try writer.writer.writeAll("[");
    var first = true;
    for (points.items) |pnt| {
        if (!first) try writer.writer.writeAll(",");
        first = false;
        try writer.writer.print("{{\"ts\":{d},\"value\":{d}}}", .{ pnt.ts, pnt.value });
    }
    try writer.writer.writeAll("]");
    try writer.end();
}

fn handleFind(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buffer: [4096]u8 = undefined;
    var reader = try req.readerExpectContinue(&body_buffer);
    var compat_reader = reader.adaptToOldInterface();
    const body = try compat_reader.readAllAlloc(alloc, 64 * 1024);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var op_and = true;
    if (obj.get("op")) |v| {
        if (v == .string and std.ascii.eqlIgnoreCase(v.string, "or")) op_and = false;
    }
    var sets = try std.ArrayList([]const u64).initCapacity(alloc, 0);
    defer sets.deinit(alloc);
    if (obj.get("tags")) |t| {
        if (t == .object) {
            var it = t.object.iterator();
            while (it.next()) |e| {
                var keybuf = std.ArrayList(u8){};
                defer keybuf.deinit(alloc);
                keybuf.print(alloc, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.string }) catch continue;
                const key = keybuf.items;
                try sets.append(alloc, eng.tags.get(key));
            }
        }
    }
    var result = std.AutoHashMap(u64, void).init(alloc);
    defer result.deinit();
    var first = true;
    for (sets.items) |arr| {
        if (first) {
            for (arr) |sid| result.put(sid, {}) catch {};
            first = false;
            continue;
        }
        if (op_and) {
            var it = result.iterator();
            while (it.next()) |entry| {
                var found = false;
                for (arr) |sid| {
                    if (sid == entry.key_ptr.*) {
                        found = true;
                        break;
                    }
                }
                if (!found) _ = result.remove(entry.key_ptr.*);
            }
        } else {
            for (arr) |sid| result.put(sid, {}) catch {};
        }
    }

    var send_buffer: [512]u8 = undefined;
    var writer = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer writer.end() catch {};

    try writer.writer.writeAll("[");
    var it2 = result.keyIterator();
    var first2 = true;
    while (it2.next()) |k| {
        if (!first2) try writer.writer.writeAll(",");
        first2 = false;
        try writer.writer.print("{d}", .{k.*});
    }
    try writer.writer.writeAll("]");
    try writer.end();
}
