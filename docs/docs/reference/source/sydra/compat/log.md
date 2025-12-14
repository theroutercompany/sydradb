---
sidebar_position: 6
title: src/sydra/compat/log.zig
---

# `src/sydra/compat/log.zig`

## Purpose

Records SQL→sydraQL translation events as JSON Lines (JSONL) written to stderr, and updates global translation counters.

This is intended for:

- observing translation behavior in real traffic
- collecting samples for debugging and compatibility testing

## Public API

### `pub const Recorder = struct { ... }`

#### Fields

- `enabled: bool = true`
- `sample_every: u32 = 1`
  - `1` records every event.
  - `N` records approximately one out of every `N` calls (starting with the first call).
- `counter: std.atomic.Value(u64)` used to implement sampling.

#### `pub fn shouldRecord(self: *Recorder) bool`

- Returns `false` when `enabled` is `false`.
- Otherwise increments `counter` (seq-cst) and returns `true` when:
  - `prev % sample_every == 0`

#### `pub fn record(self: *Recorder, sql, translated, used_cache, fell_back, duration_ns) void`

Always updates global counters (even when sampling drops emission):

- `fell_back == true` → `stats.global().noteFallback()`
- `fell_back == false` → `stats.global().noteTranslation()`
- `used_cache == true` → `stats.global().noteCacheHit()`

Then, if `shouldRecord()` is `true`, emits a JSON object to stderr and appends a newline.

JSON schema (one line per event):

```json
{
  "ts": 1734144000000,
  "event": "compat.translate",
  "sql": "SELECT 1",
  "sydraql": "FROM ...",
  "cache": false,
  "fallback": false,
  "duration_ns": 123456
}
```

Notes:

- `ts` uses `std.time.milliTimestamp()` (milliseconds).
- Writer errors are ignored (the function `catch return`s frequently).
- Emission uses a small stack buffer (`[512]u8`) for stderr writes.

### `pub fn global() *Recorder`

Returns a pointer to a file-scoped `default_recorder`.

