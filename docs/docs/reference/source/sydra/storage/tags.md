---
sidebar_position: 4
title: src/sydra/storage/tags.zig
---

# `src/sydra/storage/tags.zig`

## Purpose

Maintains a mapping from tag key/value pairs to series IDs.

This backs the HTTP endpoint `POST /api/v1/query/find`.

## Data model

### `pub const TagIndex`

Fields:

- `map: std.StringHashMap(std.ArrayListUnmanaged(SeriesId))`

Keys are tag strings of the form:

```
key=value
```

## Public API

### `pub fn loadOrInit(alloc, data_dir) !TagIndex`

- If `tags.json` does not exist, returns an empty index.
- Otherwise, parses `tags.json` as a JSON object mapping strings → integer arrays.

### `pub fn add(self, key: []const u8, series_id: SeriesId) !void`

- Inserts `series_id` into the list for `key`.
- Performs naive deduplication by scanning the existing list.

### `pub fn get(self, key: []const u8) []const SeriesId`

Returns the series-id list for `key`, or an empty slice if missing.

### `pub fn save(self, data_dir) !void`

Writes the current map to `tags.json` (truncating the file first).

Notes:

- The file is written manually (not via `std.json.Stringify`) and does not escape keys.

### `pub fn deinit(self: *TagIndex) void`

Deinitializes all stored `ArrayListUnmanaged` values and the map itself.

## Integration points

- `Engine.noteTags` parses a tags JSON object and adds `key=value` entries into this index.
- HTTP `handleFind` queries this index via `eng.tags.get(...)`.

