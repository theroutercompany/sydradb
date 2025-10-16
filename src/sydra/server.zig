const std = @import("std");
const config = @import("config.zig");
const engine_mod = @import("engine.zig");
const http = @import("http.zig");
const catalog = @import("catalog.zig");
const compat = @import("compat.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len <= 1 or std.mem.eql(u8, args[1], "serve")) {
        var cfg = try loadConfigOrDefault(alloc);
        defer cfg.deinit(alloc);
        var eng = try engine_mod.Engine.init(alloc, cfg);
        defer eng.deinit();
        try catalog.bootstrap(alloc);
        std.debug.print("sydradb serve :{d}\n", .{cfg.http_port});
        try http.runHttp(alloc, eng, cfg.http_port);
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "pgwire")) return cmdPgWire(alloc, args);
    if (std.mem.eql(u8, cmd, "ingest")) return cmdIngest(alloc, args);
    if (std.mem.eql(u8, cmd, "query")) return cmdQuery(alloc, args);
    if (std.mem.eql(u8, cmd, "compact")) return cmdCompact(alloc, args);
    if (std.mem.eql(u8, cmd, "snapshot")) return cmdSnapshot(alloc, args);
    if (std.mem.eql(u8, cmd, "restore")) return cmdRestore(alloc, args);
    if (std.mem.eql(u8, cmd, "stats")) return cmdStats(alloc, args);
}

fn loadConfigOrDefault(alloc: std.mem.Allocator) !config.Config {
    return config.load(alloc, "sydradb.toml") catch config.Config{
        .data_dir = try alloc.dupe(u8, "./data"),
        .http_port = 8080,
        .fsync = .interval,
        .flush_interval_ms = 2000,
        .memtable_max_bytes = 8 * 1024 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = true,
        .mem_limit_bytes = 256 * 1024 * 1024,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

fn cmdPgWire(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);

    var eng = try engine_mod.Engine.init(alloc, cfg);
    defer eng.deinit();

    try catalog.bootstrap(alloc);

    const default_address = "127.0.0.1";
    const address = if (args.len >= 3)
        std.mem.sliceTo(args[2], 0)
    else
        default_address;

    var port: u16 = 6432;
    if (args.len >= 4) {
        port = std.fmt.parseInt(u16, std.mem.sliceTo(args[3], 0), 10) catch return error.Invalid;
    }

    const session_cfg = compat.wire.session.SessionConfig{};
    const server_cfg = compat.wire.server.ServerConfig{
        .address = address,
        .port = port,
        .session = session_cfg,
    };

    std.debug.print("sydradb pgwire {s}:{d}\n", .{ server_cfg.address, server_cfg.port });
    try compat.wire.server.run(alloc, server_cfg);
}

fn cmdIngest(alloc: std.mem.Allocator, _: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var eng = try engine_mod.Engine.init(alloc, cfg);
    defer eng.deinit();
    // Read NDJSON from stdin
    var stdin_file = std.fs.File.stdin();
    var stdin_buf: [4096]u8 = undefined;
    var reader_state = stdin_file.reader(&stdin_buf);
    var reader = std.Io.Reader.adaptToOldInterface(&reader_state.interface);
    var line_buf: [4096]u8 = undefined;
    var count: usize = 0;
    while (true) {
        const maybe_slice = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
            error.StreamTooLong => return error.StreamTooLong,
            else => return err,
        };
        const slice = maybe_slice orelse break;
        const trimmed = std.mem.trim(u8, slice, " \t\r\n");
        if (trimmed.len == 0) continue;
        const line = try alloc.dupe(u8, trimmed);
        defer alloc.free(line);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = parsed.value.object;
        const series = obj.get("series").?.string;
        const ts: i64 = @intCast(obj.get("ts").?.integer);
        const value = obj.get("value").?.float;
        const sid = @import("types.zig").hash64(series);
        try eng.ingest(.{ .series_id = sid, .ts = ts, .value = value, .tags_json = "{}" });
        count += 1;
    }
    std.debug.print("ingested {d} points\n", .{count});
}

fn cmdQuery(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 5) return error.Invalid;
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var eng = try engine_mod.Engine.init(alloc, cfg);
    defer eng.deinit();
    const sid = try std.fmt.parseInt(u64, args[2], 10);
    const start_ts = try std.fmt.parseInt(i64, args[3], 10);
    const end_ts = try std.fmt.parseInt(i64, args[4], 10);
    var out = try std.array_list.Managed(@import("types.zig").Point).initCapacity(alloc, 0);
    defer out.deinit();
    try eng.queryRange(sid, start_ts, end_ts, &out);
    for (out.items) |p| std.debug.print("{d},{d}\n", .{ p.ts, p.value });
}

fn cmdCompact(alloc: std.mem.Allocator, _: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var data_dir = try std.fs.cwd().openDir(cfg.data_dir, .{ .iterate = true });
    defer data_dir.close();
    var manifest = try @import("storage/manifest.zig").Manifest.loadOrInit(alloc, data_dir);
    defer manifest.deinit();
    try @import("storage/compact.zig").compactAll(alloc, data_dir, &manifest);
}

fn cmdStats(alloc: std.mem.Allocator, _: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var d = try std.fs.cwd().openDir(cfg.data_dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    var seg_count: usize = 0;
    while (try it.next()) |e| {
        if (e.kind == .directory and std.mem.eql(u8, e.name, "segments")) {
            var seg_dir = try d.openDir(e.name, .{ .iterate = true, .no_follow = true });
            defer seg_dir.close();
            var it2 = seg_dir.iterate();
            while (try it2.next()) |h| {
                if (h.kind == .directory) {
                    var hour_dir = try seg_dir.openDir(h.name, .{ .iterate = true });
                    defer hour_dir.close();
                    var it3 = hour_dir.iterate();
                    while (try it3.next()) |f| {
                        if (f.kind == .file) seg_count += 1;
                    }
                }
            }
        }
    }
    std.debug.print("segments_total {d}\n", .{seg_count});
}

fn cmdSnapshot(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3) return error.Invalid;
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var data_dir = try std.fs.cwd().openDir(cfg.data_dir, .{ .iterate = true });
    defer data_dir.close();
    try @import("snapshot.zig").snapshot(alloc, data_dir, args[2]);
}

fn cmdRestore(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3) return error.Invalid;
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var data_dir = try std.fs.cwd().openDir(cfg.data_dir, .{ .iterate = true });
    defer data_dir.close();
    try @import("snapshot.zig").restore(alloc, data_dir, args[2]);
}
