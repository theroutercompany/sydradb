---
sidebar_position: 2
title: src/sydra/config.zig
---

# `src/sydra/config.zig`

## Purpose

Defines SydraDB’s runtime configuration model and a lightweight config-file loader.

## Public API

### `pub const FsyncPolicy = enum { always, interval, none }`

Controls WAL syncing behavior (see engine/writer loop).

### `pub const Config = struct { ... }`

Fields:

- `data_dir: []const u8`
- `http_port: u16`
- `fsync: FsyncPolicy`
- `flush_interval_ms: u32`
- `memtable_max_bytes: usize`
- `retention_days: u32`
- `auth_token: []const u8`
- `enable_influx: bool`
- `enable_prom: bool`
- `mem_limit_bytes: usize`
- `retention_ns: std.StringHashMap(u32)` – per-namespace retention (days)

#### `pub fn deinit(self: *Config, alloc: std.mem.Allocator) void`

Frees owned allocations (`data_dir`, `auth_token`) and deinitializes `retention_ns`.

```zig title="Config struct (excerpt)"
const std = @import("std");

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
```

### `pub fn load(alloc: std.mem.Allocator, path: []const u8) !Config`

Loads a config file from `path`:

1. Opens the file relative to the current working directory.
2. Reads the full file into an allocated buffer.
3. Parses via `parseToml`.

## Parsing behavior (`parseToml`)

Despite the name, `parseToml` is a minimal, line-based parser.

- Splits on newlines (`\n` / `\r`), trims whitespace.
- Skips empty lines and lines starting with `#`.
- Parses `key = value` pairs using the first `=` in the line.
- Supports quoted strings for `data_dir` and `auth_token`.
- Parses booleans for `enable_influx`/`enable_prom` as `true` (anything else is `false`).
- Parses `retention.<namespace> = <days>` into `retention_ns`.

For user-facing configuration guidance, see `Reference/Configuration (sydradb.toml)`.

```zig title="parseToml main loop (excerpt)"
var it = std.mem.tokenizeAny(u8, text, "\n\r");
while (it.next()) |line_raw| {
    const line = std.mem.trim(u8, line_raw, " \t");
    if (line.len == 0 or line[0] == '#') continue;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
    const key_raw = std.mem.trim(u8, line[0..eq], " \t");
    const val_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");

    if (std.mem.eql(u8, key_raw, "http_port")) {
        cfg.http_port = @intCast(try std.fmt.parseInt(u16, val_raw, 10));
    } else if (std.mem.startsWith(u8, key_raw, "retention.")) {
        const ns = key_raw["retention.".len..];
        const days: u32 = @intCast(try std.fmt.parseInt(u32, val_raw, 10));
        try cfg.retention_ns.put(ns, days);
    }
}
```

## Namespace retention helpers

### `pub fn namespaceOf(series: []const u8) []const u8`

Returns the substring before the first `.` in a series name:

- `weather.room1` → `weather`
- `cpu` → `cpu`

### `pub fn ttlForSeries(cfg: *const Config, series: []const u8) u32`

Resolves retention (days) for a series:

1. If `retention.<namespace>` exists, use it.
2. Otherwise, fall back to `retention_days`.

```zig title="Retention helpers"
pub fn namespaceOf(series: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, series, '.')) |i| return series[0..i];
    return series;
}

pub fn ttlForSeries(cfg: *const Config, series: []const u8) u32 {
    const ns = namespaceOf(series);
    if (cfg.retention_ns.get(ns)) |days| return days;
    return cfg.retention_days;
}
```
