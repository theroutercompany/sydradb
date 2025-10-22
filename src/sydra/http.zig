const std = @import("std");
const Engine = @import("engine.zig").Engine;
const types = @import("types.zig");
const config = @import("config.zig");
const compat = @import("compat.zig");
const query_exec = @import("query/exec.zig");
const query_value = @import("query/value.zig");

pub fn runHttp(alloc: std.mem.Allocator, eng: *Engine, port: u16) !void {
    var address = try std.net.Address.parseIp4("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    _ = alloc;

    while (true) {
        const connection = server.accept() catch |err| switch (err) {
            error.ConnectionResetByPeer, error.ConnectionAborted => continue,
            else => return err,
        };
        const worker = std.Thread.spawn(.{}, connectionWorker, .{ eng, connection }) catch |spawn_err| {
            std.log.err("http spawn failed: {s}", .{@errorName(spawn_err)});
            connection.stream.close();
            continue;
        };
        worker.detach();
    }
}

fn connectionWorker(eng: *Engine, connection: std.net.Server.Connection) void {
    const alloc = std.heap.c_allocator;
    handleConnection(alloc, eng, connection) catch |err| switch (err) {
        error.HttpConnectionClosing, error.HttpRequestTruncated => {},
        else => std.log.warn("http connection error: {s}", .{@errorName(err)}),
    };
}

fn handleConnection(alloc: std.mem.Allocator, eng: *Engine, connection: std.net.Server.Connection) !void {
    defer connection.stream.close();

    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var reader_state = connection.stream.reader(&in_buf);
    var writer_state = connection.stream.writer(&out_buf);
    var http_server = std.http.Server.init(reader_state.interface(), &writer_state.interface);

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
    const target = req.head.target;
    var path = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
        path = target[0..idx];
        if (idx + 1 < target.len) query = target[idx + 1 ..];
    }
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
        return try handleMetrics(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/debug/compat/stats") and method == .GET) {
        return try handleCompatStats(req);
    }
    if (std.mem.eql(u8, path, "/debug/compat/catalog") and method == .GET) {
        return try handleCompatCatalog(alloc, req);
    }
    if (std.mem.eql(u8, path, "/status") and method == .GET) {
        return try handleStatus(req);
    }
    if (std.mem.eql(u8, path, "/api/v1/ingest") and method == .POST) {
        return try handleIngest(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/query/range") and method == .POST) {
        return try handleQuery(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/query/range") and method == .GET) {
        return try handleQueryGet(alloc, eng, req, query);
    }
    if (std.mem.eql(u8, path, "/api/v1/query/find") and method == .POST) {
        return try handleFind(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/sydraql") and method == .POST) {
        return try handleSydraql(alloc, eng, req);
    }

    try req.respond("not found", .{ .status = .not_found });
}

fn handleSydraql(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [1024]u8 = undefined;
    const reader_ptr = req.readerExpectNone(&body_buf);
    const reader = std.Io.Reader.adaptToOldInterface(reader_ptr);
    const content_len = req.head.content_length orelse {
        return respondJsonError(alloc, req, .length_required, "length required");
    };
    if (content_len > 256 * 1024) {
        return respondJsonError(alloc, req, .payload_too_large, "payload too large");
    }

    const len: usize = @intCast(content_len);
    const body = try alloc.alloc(u8, len);
    defer alloc.free(body);
    try reader.readNoEof(body);

    const sydraql = std.mem.trim(u8, body, " \t\r\n");
    if (sydraql.len == 0) {
        return respondJsonError(alloc, req, .bad_request, "query required");
    }

    const start_time = std.time.microTimestamp();
    var cursor = query_exec.execute(alloc, eng, sydraql) catch |err| {
        return respondExecutionError(alloc, req, err);
    };
    defer cursor.deinit();

    var send_buf: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buf, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    var writer = response.writer;
    var adapter_buf: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&adapter_buf);
    var jw = std.json.Stringify{ .writer = &adapter.new_interface };

    try jw.beginObject();
    try jw.objectField("columns");
    try jw.beginArray();
    for (cursor.columns) |col| {
        try jw.write(col.name);
    }
    try jw.endArray();
    try jw.objectField("rows");
    try jw.beginArray();
    var row_count: usize = 0;
    while (try cursor.next()) |row| {
        try jw.beginArray();
        for (row.values) |cell| {
            try writeJsonValue(&jw, cell);
        }
        try jw.endArray();
        row_count += 1;
    }
    try jw.endArray();
    try jw.objectField("stats");
    try jw.beginObject();
    const elapsed_us = std.time.microTimestamp() - start_time;
    try jw.objectField("stream_rows");
    try jw.write(row_count);
    try jw.objectField("stream_ms");
    try jw.write(@as(f64, @floatFromInt(elapsed_us)) / 1000.0);
    try jw.objectField("parse_ms");
    try jw.write(usToMs(cursor.stats.parse_us));
    try jw.objectField("validate_ms");
    try jw.write(usToMs(cursor.stats.validate_us));
    try jw.objectField("optimize_ms");
    try jw.write(usToMs(cursor.stats.optimize_us));
    try jw.objectField("physical_ms");
    try jw.write(usToMs(cursor.stats.physical_us));
    try jw.objectField("pipeline_ms");
    try jw.write(usToMs(cursor.stats.pipeline_us));
    if (cursor.stats.trace_id.len != 0) {
        try jw.objectField("trace_id");
        try jw.write(cursor.stats.trace_id);
    }
    try jw.endObject();
    try jw.endObject();

    try response.end();
}

fn respondExecutionError(alloc: std.mem.Allocator, req: *std.http.Server.Request, err: query_exec.ExecuteError) !void {
    const status: std.http.Status = switch (err) {
        error.OutOfMemory => .internal_server_error,
        error.UnsupportedPlan,
        error.UnsupportedExpression,
        error.UnsupportedAggregate,
        error.UnsupportedSelector,
        error.ValidationFailed,
        => .bad_request,
        else => .bad_request,
    };
    return respondJsonError(alloc, req, status, @errorName(err));
}

fn respondJsonError(
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    status: std.http.Status,
    message: []const u8,
) !void {
    const payload = try std.fmt.allocPrint(alloc, "{{\"error\":\"{s}\"}}", .{message});
    defer alloc.free(payload);
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(payload, .{ .status = status, .keep_alive = false, .extra_headers = &headers });
}

fn writeJsonValue(jw: *std.json.Stringify, value: query_value.Value) !void {
    switch (value) {
        .null => try jw.write(null),
        .boolean => |b| try jw.write(b),
        .integer => |i| try jw.write(i),
        .float => |f| try jw.write(f),
        .string => |s| try jw.write(s),
    }
}

fn usToMs(value: u64) f64 {
    return @as(f64, @floatFromInt(value)) / 1000.0;
}

fn findHeader(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn handleMetrics(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const ingest_total = eng.metrics.ingest_total.load(.monotonic);
    const flush_total = eng.metrics.flush_total.load(.monotonic);
    const flush_ns_total = eng.metrics.flush_ns_total.load(.monotonic);
    const flush_points_total = eng.metrics.flush_points_total.load(.monotonic);
    const wal_bytes_total = eng.metrics.wal_bytes_total.load(.monotonic);
    const queue_depth = eng.queue.len();
    const memtable_bytes = eng.mem.bytes.load(.monotonic);
    const flush_seconds_total = @as(f64, @floatFromInt(flush_ns_total)) / 1_000_000_000.0;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();

    try writer.writeAll("# HELP sydradb_up 1 if server is up\n# TYPE sydradb_up gauge\nsydradb_up 1\n");
    try writer.print("# HELP sydradb_ingest_total Total ingested points since start\n# TYPE sydradb_ingest_total counter\nsydradb_ingest_total {d}\n", .{ingest_total});
    try writer.print("# HELP sydradb_flush_total Total flush operations\n# TYPE sydradb_flush_total counter\nsydradb_flush_total {d}\n", .{flush_total});
    try writer.print("# HELP sydradb_flush_seconds_total Aggregate flush duration in seconds\n# TYPE sydradb_flush_seconds_total counter\nsydradb_flush_seconds_total {d:.6}\n", .{flush_seconds_total});
    try writer.print("# HELP sydradb_flush_points_total Total points flushed to disk\n# TYPE sydradb_flush_points_total counter\nsydradb_flush_points_total {d}\n", .{flush_points_total});
    try writer.print("# HELP sydradb_wal_bytes_total Total bytes written to WAL\n# TYPE sydradb_wal_bytes_total counter\nsydradb_wal_bytes_total {d}\n", .{wal_bytes_total});
    try writer.print("# HELP sydradb_queue_depth Current ingest queue depth\n# TYPE sydradb_queue_depth gauge\nsydradb_queue_depth {d}\n", .{queue_depth});
    try writer.print("# HELP sydradb_memtable_bytes Current memtable size in bytes\n# TYPE sydradb_memtable_bytes gauge\nsydradb_memtable_bytes {d}\n", .{memtable_bytes});

    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "text/plain; version=0.0.4" }};
    try req.respond(buf.items, .{ .extra_headers = &headers });
}

fn handleCompatStats(req: *std.http.Server.Request) !void {
    const snap = compat.stats.global().snapshot();
    var buf: [128]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &buf,
        "{{\"translations\":{d},\"fallbacks\":{d},\"cache_hits\":{d}}}",
        .{ snap.translations, snap.fallbacks, snap.cache_hits },
    );
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(body, .{ .extra_headers = &headers });
}

fn handleCompatCatalog(alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    var jw_writer = buf.writer();
    var jw_buffer: [512]u8 = undefined;
    var jw_adapter = jw_writer.adaptToNewApi(&jw_buffer);
    var jw_iface = &jw_adapter.new_interface;
    var jw = std.json.Stringify{ .writer = jw_iface };
    try jw.beginObject();

    const store = compat.catalog.global();

    try jw.objectField("namespaces");
    try jw.beginArray();
    for (store.namespaces()) |ns| {
        try jw.beginObject();
        try jw.objectField("oid");
        try jw.write(ns.oid);
        try jw.objectField("name");
        try jw.write(ns.nspname);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("classes");
    try jw.beginArray();
    for (store.classes()) |cls| {
        try jw.beginObject();
        try jw.objectField("oid");
        try jw.write(cls.oid);
        try jw.objectField("name");
        try jw.write(cls.relname);
        try jw.objectField("namespace");
        try jw.write(cls.relnamespace);
        const kind_buf = [_]u8{cls.relkind};
        try jw.objectField("kind");
        try jw.write(kind_buf[0..]);
        const pers_buf = [_]u8{cls.relpersistence};
        try jw.objectField("persistence");
        try jw.write(pers_buf[0..]);
        try jw.objectField("tuples");
        try jw.write(cls.reltuples);
        try jw.objectField("has_pkey");
        try jw.write(cls.relhaspkey);
        try jw.objectField("is_partition");
        try jw.write(cls.relispartition);
        try jw.objectField("toast_oid");
        try jw.write(cls.reltoastrelid);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("attributes");
    try jw.beginArray();
    for (store.attributes()) |attr| {
        try jw.beginObject();
        try jw.objectField("rel_oid");
        try jw.write(attr.attrelid);
        try jw.objectField("name");
        try jw.write(attr.attname);
        try jw.objectField("type_oid");
        try jw.write(attr.atttypid);
        try jw.objectField("attnum");
        try jw.write(attr.attnum);
        try jw.objectField("not_null");
        try jw.write(attr.attnotnull);
        try jw.objectField("has_default");
        try jw.write(attr.atthasdef);
        try jw.objectField("is_dropped");
        try jw.write(attr.attisdropped);
        try jw.objectField("len");
        try jw.write(attr.attlen);
        try jw.objectField("typmod");
        try jw.write(attr.atttypmod);
        const identity_buf = [_]u8{attr.attidentity};
        try jw.objectField("identity");
        try jw.write(identity_buf[0..]);
        const generated_buf = [_]u8{attr.attgenerated};
        try jw.objectField("generated");
        try jw.write(generated_buf[0..]);
        try jw.objectField("dims");
        try jw.write(attr.attndims);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("types");
    try jw.beginArray();
    for (store.types()) |ty| {
        try jw.beginObject();
        try jw.objectField("oid");
        try jw.write(ty.oid);
        try jw.objectField("name");
        try jw.write(ty.typname);
        try jw.objectField("namespace");
        try jw.write(ty.typnamespace);
        try jw.objectField("len");
        try jw.write(ty.typlen);
        try jw.objectField("byval");
        try jw.write(ty.typbyval);
        const type_buf = [_]u8{ty.typtype};
        try jw.objectField("type");
        try jw.write(type_buf[0..]);
        try jw.objectField("category");
        const cat_buf = [_]u8{ty.typcategory};
        try jw.write(cat_buf[0..]);
        try jw.objectField("delim");
        const delim_buf = [_]u8{ty.typdelim};
        try jw.write(delim_buf[0..]);
        try jw.objectField("elem");
        try jw.write(ty.typelem);
        try jw.objectField("array");
        try jw.write(ty.typarray);
        try jw.objectField("basetype");
        try jw.write(ty.typbasetype);
        try jw.objectField("collation");
        try jw.write(ty.typcollation);
        try jw.objectField("input");
        try jw.write(ty.typinput);
        try jw.objectField("output");
        try jw.write(ty.typoutput);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.endObject();
    try jw_iface.flush();
    if (jw_adapter.err) |write_err| return write_err;

    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(buf.items, .{ .extra_headers = &headers });
}

fn handleStatus(req: *std.http.Server.Request) !void {
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond("{\"status\":\"ok\"}", .{ .extra_headers = &headers });
}

fn handleIngest(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [4096]u8 = undefined;
    const body_reader_ptr = req.readerExpectNone(&body_buf);
    const body_reader = std.Io.Reader.adaptToOldInterface(body_reader_ptr);
    var line_buf: [4096]u8 = undefined;
    var count: usize = 0;

    while (true) {
        const maybe_slice = body_reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = req.respond("line too long", .{ .status = .payload_too_large, .keep_alive = false }) catch {};
                return;
            },
            else => return err,
        };
        const slice = maybe_slice orelse break;
        const trimmed = std.mem.trim(u8, slice, " \t\r\n");
        if (trimmed.len == 0) continue;

        const line = try alloc.dupe(u8, trimmed);
        if (line.len == 0) continue;
        defer alloc.free(line);

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
                var tags_buf = std.array_list.Managed(u8).init(alloc);
                defer tags_buf.deinit();
                var tags_writer = tags_buf.writer();
                var tags_tmp: [128]u8 = undefined;
                var tags_adapter = tags_writer.adaptToNewApi(&tags_tmp);
                var tags_iface = &tags_adapter.new_interface;
                var stream = std.json.Stringify{ .writer = tags_iface };
                try stream.write(v);
                try tags_iface.flush();
                if (tags_adapter.err) |write_err| return write_err;
                tags_owned = try tags_buf.toOwnedSlice();
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
    var body_buf: [1024]u8 = undefined;
    const reader_ptr = req.readerExpectNone(&body_buf);
    const reader = std.Io.Reader.adaptToOldInterface(reader_ptr);
    const content_len = req.head.content_length orelse {
        try req.respond("length required", .{ .status = .length_required, .keep_alive = false });
        return;
    };
    if (content_len > 1024 * 64) {
        try req.respond("payload too large", .{ .status = .payload_too_large, .keep_alive = false });
        return;
    }
    const alloc_len: usize = @intCast(content_len);
    const body = try alloc.alloc(u8, alloc_len);
    defer alloc.free(body);
    try reader.readNoEof(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var series_id: ?types.SeriesId = null;
    if (obj.get("series_id")) |v| series_id = @intCast(v.integer) else if (obj.get("series")) |v| series_id = types.hash64(v.string);
    const start_val = obj.get("start") orelse {
        try req.respond("missing start", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    const end_val = obj.get("end") orelse {
        try req.respond("missing end", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    const start_ts: i64 = @intCast(start_val.integer);
    const end_ts: i64 = @intCast(end_val.integer);
    const sid = series_id orelse {
        try req.respond("missing series identifier", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    try queryAndRespond(alloc, eng, req, sid, start_ts, end_ts);
}

fn handleQueryGet(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, query: []const u8) !void {
    if (query.len == 0) {
        try req.respond("missing query parameters", .{ .status = .bad_request, .keep_alive = false });
        return;
    }
    var series_opt: ?[]const u8 = null;
    var series_id_opt: ?types.SeriesId = null;
    var start_opt: ?i64 = null;
    var end_opt: ?i64 = null;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "series_id")) {
            series_id_opt = std.fmt.parseInt(types.SeriesId, value, 10) catch {
                try req.respond("invalid series_id", .{ .status = .bad_request, .keep_alive = false });
                return;
            };
        } else if (std.mem.eql(u8, key, "series")) {
            series_opt = value;
        } else if (std.mem.eql(u8, key, "start")) {
            start_opt = std.fmt.parseInt(i64, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "end")) {
            end_opt = std.fmt.parseInt(i64, value, 10) catch null;
        }
    }
    const sid = series_id_opt orelse (if (series_opt) |name| types.hash64(name) else null) orelse {
        try req.respond("missing series or series_id", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    const start_ts = start_opt orelse {
        try req.respond("missing start", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    const end_ts = end_opt orelse {
        try req.respond("missing end", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    try queryAndRespond(alloc, eng, req, sid, start_ts, end_ts);
}

fn queryAndRespond(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, sid: types.SeriesId, start_ts: i64, end_ts: i64) !void {
    var points = try std.array_list.Managed(types.Point).initCapacity(alloc, 0);
    defer points.deinit();
    try eng.queryRange(sid, start_ts, end_ts, &points);
    try respondPoints(req, points.items);
}

fn respondPoints(req: *std.http.Server.Request, points: []const types.Point) !void {
    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    const resp_writer = &response.writer;
    try resp_writer.writeAll("[");
    var first = true;
    for (points) |pnt| {
        if (!first) try resp_writer.writeAll(",");
        first = false;
        try resp_writer.print("{{\"ts\":{d},\"value\":{d}}}", .{ pnt.ts, pnt.value });
    }
    try resp_writer.writeAll("]");
    try response.end();
}

fn handleFind(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [1024]u8 = undefined;
    const reader_ptr = req.readerExpectNone(&body_buf);
    const reader = std.Io.Reader.adaptToOldInterface(reader_ptr);
    const content_len = req.head.content_length orelse {
        try req.respond("length required", .{ .status = .length_required, .keep_alive = false });
        return;
    };
    if (content_len > 64 * 1024) {
        try req.respond("payload too large", .{ .status = .payload_too_large, .keep_alive = false });
        return;
    }
    const alloc_len: usize = @intCast(content_len);
    const body = try alloc.alloc(u8, alloc_len);
    defer alloc.free(body);
    try reader.readNoEof(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var op_and = true;
    if (obj.get("op")) |v| {
        if (v == .string and std.ascii.eqlIgnoreCase(v.string, "or")) op_and = false;
    }
    var sets = try std.array_list.Managed([]const u64).initCapacity(alloc, 0);
    defer sets.deinit();
    if (obj.get("tags")) |t| {
        if (t == .object) {
            var it = t.object.iterator();
            while (it.next()) |e| {
                const key = std.fmt.allocPrint(alloc, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.string }) catch continue;
                defer alloc.free(key);
                try sets.append(eng.tags.get(key));
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
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    const resp_writer = &response.writer;
    try resp_writer.writeAll("[");
    var it2 = result.keyIterator();
    var first2 = true;
    while (it2.next()) |k| {
        if (!first2) try resp_writer.writeAll(",");
        first2 = false;
        try resp_writer.print("{d}", .{k.*});
    }
    try resp_writer.writeAll("]");
    try response.end();
}
