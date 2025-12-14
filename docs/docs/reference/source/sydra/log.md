---
sidebar_position: 8
title: src/sydra/log.zig
---

# `src/sydra/log.zig`

## Purpose

Provides a small JSON logging helper that writes one JSON object per line (“JSONL”), intended for structured logs.

## Public API

### `pub const Level = enum { debug, info, warn, err }`

Serialized using `@tagName(level)` (e.g. `"info"`).

### `pub fn logJson(level: Level, msg: []const u8, fields: ?[]const std.json.Value, writer: *std.io.Writer) !void`

Writes a JSON object with at least:

- `ts`: `std.time.milliTimestamp()`
- `level`: string tag name
- `msg`: message string

Optional field merge behavior:

- When `fields` is provided, each entry is examined.
- If an entry is a JSON object (`v == .object`), its key/value pairs are written into the output object.
- Non-object values are ignored.

Note: if multiple field objects contain the same key, the output will contain duplicate keys (JSON parsers generally take the last occurrence).

The function appends a trailing newline (`"\n"`).

