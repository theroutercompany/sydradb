const std = @import("std");
const Engine = @import("engine.zig").Engine;
const types = @import("types.zig");
const config = @import("config.zig");

// Minimal HTTP server handling:
// POST /api/v1/ingest  (NDJSON lines: {series, ts, value, tags?})
// POST /api/v1/query/range  ({series|series_id, start, end})
// GET  /metrics

pub fn runHttp(alloc: std.mem.Allocator, eng: *Engine, port: u16) !void {
    const builtin = @import("builtin");
    if (builtin.zig_version.minor >= 15) {
        var server = std.http.Server.init(.{ .reuse_address = true });
        defer server.deinit();
        try server.listen(.{ .address = try std.net.Address.parseIp4("0.0.0.0", port) });
        while (true) {
            var conn = try server.accept(.{ .allocator = alloc });
            defer conn.deinit();
            handle(alloc, eng, &conn) catch {};
        }
    } else {
        return error.Unsupported;
    }
}

fn handle(alloc: std.mem.Allocator, eng: *Engine, res: *std.http.Server.Connection) !void {
    const req = try res.request();
    const path = req.target;
    if (std.mem.startsWith(u8, path, "/api/") and eng.config.auth_token.len != 0) {
        const auth = req.headers.getFirstValue("authorization") orelse "";
        const expected = eng.config.auth_token;
        if (!(std.mem.startsWith(u8, auth, "Bearer ") and std.mem.eql(u8, auth[7..], expected))) {
            try res.sendError(.unauthorized, "unauthorized");
            return;
        }
    }
    if (std.mem.eql(u8, path, "/metrics") and req.method == .GET) return try handleMetrics(alloc, eng, res, req);
    if (std.mem.eql(u8, path, "/api/v1/ingest") and req.method == .POST) return try handleIngest(alloc, eng, res, req);
    if (std.mem.eql(u8, path, "/api/v1/query/range") and req.method == .POST) return try handleQuery(alloc, eng, res, req);
    if (std.mem.eql(u8, path, "/api/v1/query/find") and req.method == .POST) return try handleFind(alloc, eng, res, req);
    try res.sendError(.not_found, "not found");
}

fn handleMetrics(_: std.mem.Allocator, _: *Engine, res: *std.http.Server.Connection, _: std.http.Server.Request) !void {
    // alloc, eng and req are currently unused; retained in signature for future use
    const body = "# HELP sydradb_up 1 if server is up\n# TYPE sydradb_up gauge\nsydradb_up 1\n";
    var response = try res.respond(.{ .status = .ok, .headers = .{ .content_type = .{ .override = true, .value = "text/plain; version=0.0.4" } } });
    try response.writer().writeAll(body);
}

fn handleIngest(alloc: std.mem.Allocator, eng: *Engine, res: *std.http.Server.Connection, req: std.http.Server.Request) !void {
    // Read entire body, split by newlines, parse JSON objects.
    const body_stream = try req.reader();
    var br = std.io.bufferedReader(body_stream);
    const r = br.reader();
    var count: usize = 0;
    while (true) {
        const line_opt = try r.readUntilDelimiterOrEofAlloc(alloc, '\n', 1024 * 64);
        if (line_opt == null) break;
        defer alloc.free(line_opt.?);
        const line = std.mem.trim(u8, line_opt.?, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = parsed.value.object;
        const series = obj.get("series").?.string;
        const ts: i64 = @intCast(obj.get("ts").?.integer);
        const value = obj.get("value") orelse blk: {
            // fallback: pick first numeric field under "fields"
            if (obj.get("fields")) |fields_val| {
                if (fields_val == .object) {
                    var it = fields_val.object.iterator();
                    while (it.next()) |e| switch (e.value_ptr.*) {
                        .float => break :blk e.value_ptr.float,
                    .integer => break :blk @as(f64, @floatFromInt(e.value_ptr.integer)),
                        else => {},
                    };
                }
            }
            break :blk @as(f64, 0);
        };
        var tags_json: []const u8 = "{}";
        if (obj.get("tags")) |v| {
            if (v == .object) {
                // Re-stringify tags for hashing (simple, non-stable order ok for MVP)
                var out: std.io.Writer.Allocating = .init(alloc);
                defer out.deinit();
                var jws: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
                try jws.write(v);
                tags_json = out.written();
            }
        }
        const sid = types.seriesIdFrom(series, tags_json);
        try eng.ingest(.{ .series_id = sid, .ts = ts, .value = valueToF64(value), .tags_json = try alloc.dupe(u8, tags_json) });
        eng.noteTags(sid, tags_json);
        count += 1;
    }
    var response = try res.respond(.{ .status = .ok });
    try response.writer().print("{{\"ingested\":{d}}}", .{count});
}

fn valueToF64(v: std.json.Value) f64 {
    return switch (v) {
        .float => |x| x,
        .integer => |x| @as(f64, @floatFromInt(x)),
        else => 0,
    };
}

fn handleQuery(alloc: std.mem.Allocator, eng: *Engine, res: *std.http.Server.Connection, req: std.http.Server.Request) !void {
    const body = try (try req.reader()).readAllAlloc(alloc, 1024 * 64);
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var series_id: types.SeriesId = 0;
    if (obj.get("series_id")) |v| series_id = @intCast(v.integer)
    else if (obj.get("series")) |v| series_id = types.hash64(v.string);
    const start_ts: i64 = @intCast(obj.get("start").?.integer);
    const end_ts: i64 = @intCast(obj.get("end").?.integer);
    var points = try std.ArrayList(types.Point).initCapacity(alloc, 0);
    defer points.deinit();
    try eng.queryRange(series_id, start_ts, end_ts, &points);
    var response = try res.respond(.{ .status = .ok });
    var w = response.writer();
    try w.writeAll("[");
    var first = true;
    for (points.items) |pnt| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"ts\":{d},\"value\":{d}}}", .{ pnt.ts, pnt.value });
    }
    try w.writeAll("]");
    // finish handled by writer deinit
}

fn handleFind(alloc: std.mem.Allocator, eng: *Engine, res: *std.http.Server.Connection, req: std.http.Server.Request) !void {
    const body = try (try req.reader()).readAllAlloc(alloc, 64 * 1024);
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var op_and = true;
    if (obj.get("op")) |v| {
        if (v == .string and std.ascii.eqlIgnoreCase(v.string, "or")) op_and = false;
    }
    var sets = try std.ArrayList([]const u64).initCapacity(alloc, 0);
    defer sets.deinit();
    if (obj.get("tags")) |t| {
        if (t == .object) {
            var it = t.object.iterator();
            while (it.next()) |e| {
                var keybuf = try std.ArrayList(u8).initCapacity(alloc, 0);
                defer keybuf.deinit();
                keybuf.writer().print("{s}={s}", .{ e.key_ptr.*, e.value_ptr.string }) catch continue;
                const key = keybuf.items;
                try sets.append(eng.tags.get(key));
            }
        }
    }
    // compute AND/OR
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
            // intersect
            var it = result.iterator();
            while (it.next()) |entry| {
                var found = false;
                for (arr) |sid| {
                    if (sid == entry.key_ptr.*) { found = true; break; }
                }
                if (!found) _ = result.remove(entry.key_ptr.*);
            }
        } else {
            // union
            for (arr) |sid| result.put(sid, {}) catch {};
        }
    }
    var response = try res.respond(.{ .status = .ok });
    var w = response.writer();
    try w.writeAll("[");
    var it2 = result.keyIterator();
    var first2 = true;
    while (it2.next()) |k| {
        if (!first2) try w.writeAll(",");
        first2 = false;
        try w.print("{d}", .{k.*});
    }
    try w.writeAll("]");
    // finish handled by writer deinit
}
