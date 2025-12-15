---
sidebar_position: 5
title: src/sydra/compat/stats.zig
---

# `src/sydra/compat/stats.zig`

## Purpose

Provides simple, process-wide counters used by the Postgres-compatibility translator/pgwire surfaces.

The counters are atomic so they can be incremented from multiple threads.

## Used by

- [SQL → sydraQL translator](../query/translator.md)
- [Translation log (JSONL)](./log.md)
- [pgwire server](./wire-server.md) and [HTTP debug endpoints](../http.md)

## Public API

### `pub const Snapshot`

A copyable struct representing counter values at a point in time:

- `translations: u64`
- `fallbacks: u64`
- `cache_hits: u64`

### `pub const Stats = struct { ... }`

#### Fields

- `translation_count: std.atomic.Value(u64)`
- `fallback_count: std.atomic.Value(u64)`
- `cache_hit_count: std.atomic.Value(u64)`

All counters use `.seq_cst` operations.

```zig title="Stats struct + helpers (excerpt)"
pub const Stats = struct {
    translation_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fallback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cache_hit_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn noteTranslation(self: *Stats) void {
        _ = self.translation_count.fetchAdd(1, .seq_cst);
    }

    pub fn snapshot(self: *Stats) Snapshot {
        return .{
            .translations = self.translation_count.load(.seq_cst),
            .fallbacks = self.fallback_count.load(.seq_cst),
            .cache_hits = self.cache_hit_count.load(.seq_cst),
        };
    }
};
```

#### Counter methods

- `pub fn noteTranslation(self: *Stats) void`
- `pub fn noteFallback(self: *Stats) void`
- `pub fn noteCacheHit(self: *Stats) void`

Each increments its corresponding atomic counter.

#### Snapshot + reset

- `pub fn snapshot(self: *Stats) Snapshot`
  - Loads all counters and returns a `Snapshot`.
- `pub fn reset(self: *Stats) void`
  - Stores `0` into all counters.

### `pub fn global() *Stats`

Returns a pointer to a file-scoped `global_stats` instance.

### `pub fn formatSnapshot(snapshot: Snapshot, writer) !void`

Formats snapshot fields in a single line:

```
translations=123 fallbacks=4 cache_hits=99
```
