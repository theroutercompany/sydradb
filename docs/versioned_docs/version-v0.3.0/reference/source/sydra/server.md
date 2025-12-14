---
sidebar_position: 1
title: src/sydra/server.zig
---

# `src/sydra/server.zig`

## Purpose

Top-level runtime orchestration and CLI dispatch.

This module:

- Parses CLI arguments
- Loads configuration (or uses defaults)
- Instantiates the engine and ancillary subsystems
- Routes to the HTTP server or subcommands (`pgwire`, `ingest`, `query`, etc.)

## Public API

### `pub fn run(handle: *alloc_mod.AllocatorHandle) !void`

Dispatch rules:

- No args or `serve` → start the HTTP server
- `pgwire` → start the PostgreSQL wire protocol listener
- `ingest` → read NDJSON from stdin and ingest
- `query` → range query by `series_id`
- `compact` → run compaction
- `snapshot` / `restore` → snapshot management
- `stats` → print basic stats (and allocator stats in some modes)

The `handle` is used to:

- Provide the allocator via `handle.allocator()`
- Expose allocator statistics for `stats`
- Pass through to the HTTP server entrypoint

```zig title="Command dispatch (excerpt)"
pub fn run(handle: *alloc_mod.AllocatorHandle) !void {
    const alloc = handle.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len <= 1 or std.mem.eql(u8, args[1], "serve")) {
        // starts the engine + HTTP server
        // ...
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "pgwire")) return cmdPgWire(alloc, args);
    if (std.mem.eql(u8, cmd, "ingest")) return cmdIngest(alloc, args);
    if (std.mem.eql(u8, cmd, "query")) return cmdQuery(alloc, args);
    if (std.mem.eql(u8, cmd, "compact")) return cmdCompact(alloc, args);
    if (std.mem.eql(u8, cmd, "snapshot")) return cmdSnapshot(alloc, args);
    if (std.mem.eql(u8, cmd, "restore")) return cmdRestore(alloc, args);
    if (std.mem.eql(u8, cmd, "stats")) return cmdStats(handle, alloc, args);
}
```

## Key internal helpers

### `fn loadConfigOrDefault(alloc: std.mem.Allocator) !config.Config`

Loads `sydradb.toml` from the current working directory. If loading/parsing fails, returns a default config literal.

Notable defaults:

- `data_dir = "./data"`
- `http_port = 8080`
- `fsync = interval`
- `flush_interval_ms = 2000`
- `memtable_max_bytes = 8 MiB`
- `retention_days = 0` (keep forever)
- `auth_token = ""` (auth disabled)
- `enable_prom = true`
- `mem_limit_bytes = 256 MiB`
- `retention_ns = StringHashMap(u32)` (per-namespace retention map)

Callers must `deinit` the returned config to free owned allocations.

```zig title="loadConfigOrDefault (full function)"
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
```

## Commands

### `fn cmdPgWire(alloc: std.mem.Allocator, args: [][:0]u8) !void`

Starts a pgwire listener backed by an engine instance.

- Default `address`: `127.0.0.1` (override via `args[2]`)
- Default `port`: `6432` (override via `args[3]`)

It constructs:

- `compat.wire.session.SessionConfig{}`
- `compat.wire.server.ServerConfig{ address, port, session, engine }`

And runs `compat.wire.server.run(alloc, server_cfg)`.

### `fn cmdIngest(alloc: std.mem.Allocator, args: [][:0]u8) !void`

Reads NDJSON from stdin and ingests each line into the engine.

Expected per-line JSON fields:

- `series` (string)
- `ts` (integer)
- `value` (float)

Series IDs:

- This command uses `types.hash64(series)` (hashes only the series name).
- HTTP ingest uses a different `series_id` derivation when tags are present (see `Reference/Series IDs`).

```zig title="cmdIngest series_id derivation (excerpt)"
const series = obj.get("series").?.string;
const ts: i64 = @intCast(obj.get("ts").?.integer);
const value = obj.get("value").?.float;

// CLI ingest hashes only the series name (tags are not part of the SeriesId here).
const sid = @import("types.zig").hash64(series);

try eng.ingest(.{ .series_id = sid, .ts = ts, .value = value, .tags_json = "{}" });
```

### `fn cmdQuery(alloc: std.mem.Allocator, args: [][:0]u8) !void`

Usage:

```
sydradb query <series_id> <start_ts> <end_ts>
```

Runs `Engine.queryRange` and prints CSV rows as:

```
ts,value
```

### `fn cmdCompact(alloc: std.mem.Allocator, args: [][:0]u8) !void`

Opens `cfg.data_dir`, loads or initializes the manifest, then runs storage compaction across all segments.

### `fn cmdSnapshot(alloc: std.mem.Allocator, args: [][:0]u8) !void`

Usage:

```
sydradb snapshot <dst_dir>
```

Calls `snapshot.zig` to write a snapshot.

### `fn cmdRestore(alloc: std.mem.Allocator, args: [][:0]u8) !void`

Usage:

```
sydradb restore <src_dir>
```

Calls `snapshot.zig` to restore from a snapshot.

### `fn cmdStats(handle: *alloc_mod.AllocatorHandle, alloc: std.mem.Allocator, args: [][:0]u8) !void`

- Counts segment files under `<data_dir>/segments/**` and prints `segments_total`.
- If built with the `small_pool` allocator mode, prints allocator stats via `handle.snapshotSmallPoolStats()`.
