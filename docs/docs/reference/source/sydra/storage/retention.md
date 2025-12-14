---
sidebar_position: 5
title: src/sydra/storage/retention.zig
---

# `src/sydra/storage/retention.zig`

## Purpose

Applies retention by deleting segment files older than a configured TTL.

## Public API

### `pub fn apply(data_dir: std.fs.Dir, manifest: *Manifest, ttl_days: u32) !void`

Behavior:

- If `ttl_days == 0`, retention is disabled (keeps data forever).
- Otherwise:
  - Computes `ttl_secs = ttl_days * 24 * 3600`.
  - Iterates `manifest.entries` and removes entries where:
    - `(now_secs - entry.end_ts) > ttl_secs`
  - Deletes expired segment files (`deleteFile`) best-effort.
  - Replaces the manifest’s in-memory entries list with only the retained entries.

Time unit assumption:

- `now_secs` is taken from `std.time.timestamp()` (seconds).
- `end_ts` is compared directly against `now_secs`, so point timestamps must be in seconds for retention to behave as intended.

## Tests

- `test "retention removes expired segments"`

