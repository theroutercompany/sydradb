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

```zig title="add() naive dedup (from src/sydra/storage/tags.zig)"
pub fn add(self: *TagIndex, key: []const u8, series_id: types.SeriesId) !void {
    var gop = try self.map.getOrPut(key);
    if (!gop.found_existing) gop.value_ptr.* = .{};

    // naive dedup: scan existing list
    for (gop.value_ptr.items) |sid| if (sid == series_id) return;
    try gop.value_ptr.append(self.alloc, series_id);
}
```

### `pub fn get(self, key: []const u8) []const SeriesId`

Returns the series-id list for `key`, or an empty slice if missing.

### `pub fn save(self, data_dir) !void`

Writes the current map to `tags.json` (truncating the file first).

Notes:

- The file is written manually (not via `std.json.Stringify`) and does not escape keys.

```zig title="save() JSON writer (excerpt)"
try w.writeAll("{");
var it = self.map.iterator();
var first = true;
while (it.next()) |e| {
    if (!first) try w.writeAll(",");
    first = false;
    try w.print("\"{s}\":[", .{e.key_ptr.*});
    var first2 = true;
    for (e.value_ptr.items) |sid| {
        if (!first2) try w.writeAll(",");
        first2 = false;
        try w.print("{d}", .{sid});
    }
    try w.writeAll("]");
}
try w.writeAll("}");
```

### `pub fn deinit(self: *TagIndex) void`

Deinitializes all stored `ArrayListUnmanaged` values and the map itself.

## Integration points

- `Engine.noteTags` parses a tags JSON object and adds `key=value` entries into this index.
- HTTP `handleFind` queries this index via `eng.tags.get(...)`.
