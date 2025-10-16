const std = @import("std");

pub const FsyncPolicy = enum { always, interval, none };

pub const Config = struct {
    data_dir: []const u8,
    http_port: u16,
    fsync: FsyncPolicy,
    flush_interval_ms: u32,
    memtable_max_bytes: usize,
    retention_days: u32,
    auth_token: []const u8,
    enable_influx: bool,
    enable_prom: bool,
    mem_limit_bytes: usize,
    retention_ns: std.StringHashMap(u32),

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.data_dir);
        alloc.free(self.auth_token);
        self.retention_ns.deinit();
    }
};

pub fn load(alloc: std.mem.Allocator, path: []const u8) !Config {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    _ = try file.readAll(buf);
    return try parseToml(alloc, buf);
}

fn parseToml(alloc: std.mem.Allocator, text: []const u8) !Config {
    var cfg = Config{
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
    var it = std.mem.tokenizeAny(u8, text, "\n\r");
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key_raw = std.mem.trim(u8, line[0..eq], " \t");
        const val_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key_raw, "data_dir")) {
            if (val_raw.len >= 2 and val_raw[0] == '"' and val_raw[val_raw.len - 1] == '"') {
                const inner = val_raw[1 .. val_raw.len - 1];
                alloc.free(cfg.data_dir);
                cfg.data_dir = try alloc.dupe(u8, inner);
            }
        } else if (std.mem.eql(u8, key_raw, "http_port")) {
            cfg.http_port = @intCast(try std.fmt.parseInt(u16, val_raw, 10));
        } else if (std.mem.eql(u8, key_raw, "flush_interval_ms")) {
            cfg.flush_interval_ms = @intCast(try std.fmt.parseInt(u32, val_raw, 10));
        } else if (std.mem.eql(u8, key_raw, "memtable_max_bytes")) {
            cfg.memtable_max_bytes = @intCast(try std.fmt.parseInt(usize, val_raw, 10));
        } else if (std.mem.eql(u8, key_raw, "retention_days")) {
            cfg.retention_days = @intCast(try std.fmt.parseInt(u32, val_raw, 10));
        } else if (std.mem.eql(u8, key_raw, "fsync")) {
            var val = val_raw;
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val = val[1 .. val.len - 1];
            if (std.mem.eql(u8, val, "always")) cfg.fsync = .always else if (std.mem.eql(u8, val, "interval")) cfg.fsync = .interval else if (std.mem.eql(u8, val, "none")) cfg.fsync = .none;
        } else if (std.mem.eql(u8, key_raw, "mem_limit_bytes")) {
            cfg.mem_limit_bytes = @intCast(try std.fmt.parseInt(usize, val_raw, 10));
        } else if (std.mem.eql(u8, key_raw, "auth_token")) {
            var v2 = val_raw;
            if (v2.len >= 2 and v2[0] == '"' and v2[v2.len - 1] == '"') v2 = v2[1 .. v2.len - 1];
            alloc.free(cfg.auth_token);
            cfg.auth_token = try alloc.dupe(u8, v2);
        } else if (std.mem.eql(u8, key_raw, "enable_influx")) {
            const v2 = std.mem.trim(u8, val_raw, " \t");
            cfg.enable_influx = std.mem.eql(u8, v2, "true");
        } else if (std.mem.eql(u8, key_raw, "enable_prom")) {
            const v2 = std.mem.trim(u8, val_raw, " \t");
            cfg.enable_prom = std.mem.eql(u8, v2, "true");
        } else if (std.mem.startsWith(u8, key_raw, "retention.")) {
            const ns = key_raw["retention.".len..];
            const days: u32 = @intCast(try std.fmt.parseInt(u32, val_raw, 10));
            try cfg.retention_ns.put(ns, days);
        }
    }
    return cfg;
}

pub fn namespaceOf(series: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, series, '.')) |i| return series[0..i];
    return series;
}

pub fn ttlForSeries(cfg: *const Config, series: []const u8) u32 {
    const ns = namespaceOf(series);
    if (cfg.retention_ns.get(ns)) |days| return days;
    return cfg.retention_days;
}
