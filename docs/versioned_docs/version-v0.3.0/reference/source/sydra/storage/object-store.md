---
sidebar_position: 7
title: src/sydra/storage/object_store.zig
---

# `src/sydra/storage/object_store.zig`

## Purpose

Implements a content-addressed object store (Git-inspired):

- Objects are addressed by a BLAKE3 hash of `(type, payload)`.
- Objects are stored under `objects/<prefix>/<hex>` in a directory.

## Public types

### `pub const ObjectType = enum(u8)`

- `blob = 1`
- `tree = 2`
- `commit = 3`
- `ref = 4`

### `pub const ObjectId`

- `hash: [32]u8`
- `pub fn toHex(self) [64]u8` – lower-hex encoding

```zig title="ObjectId.toHex (from src/sydra/storage/object_store.zig)"
pub const ObjectId = struct {
    hash: [32]u8,

    pub fn toHex(self: ObjectId) [64]u8 {
        var out: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "{s}", .{std.fmt.fmtSliceHexLower(self.hash[0..])}) catch unreachable;
        return out;
    }
};
```

### `pub const LoadedObject`

- `id: ObjectId`
- `obj_type: ObjectType`
- `payload: []u8` – slice referencing the read buffer returned by `get`

### `pub const ObjectStore`

Fields:

- `allocator: std.mem.Allocator`
- `root: std.fs.Dir`

## Public API

### `pub fn init(allocator, path: []const u8) !ObjectStore`

- Ensures `path/` exists.
- Creates `objects/` and `refs/` under `path/`.

### `pub fn put(self, obj_type: ObjectType, payload: []const u8) !ObjectId`

- Hashes `(obj_type, payload)` via BLAKE3.
- Stores objects under `objects/<first_byte_hex>/<object_id_hex>`.
- Uses a 5-byte header:
  - `[type:u8][payload_len:u32 little]`
- If the object already exists, returns the id without rewriting.

```zig title="put() header + payload write (excerpt)"
var header = [_]u8{ @intFromEnum(obj_type), 0, 0, 0, 0 };
const payload_len: u32 = @intCast(payload.len);
std.mem.writeInt(u32, header[1..5], payload_len, .little);

try file.writeAll(&header);
try file.writeAll(payload);
```

### `pub fn get(self, allocator, id: ObjectId) !LoadedObject`

- Loads the object file into an allocated buffer.
- Validates the header and payload length.
- Returns a `LoadedObject` with `payload` as a slice into that buffer.

Callers must free `loaded.payload` using the same allocator passed to `get`.

```zig title="get() header validation (excerpt)"
const stat = try file.stat();
if (stat.size < 5) return error.CorruptObject;

var buffer = try allocator.alloc(u8, stat.size);
errdefer allocator.free(buffer);
try file.readAll(buffer);

const obj_type = std.meta.intToEnum(ObjectType, buffer[0]) catch return error.UnknownObjectType;
const payload_len = std.mem.readInt(u32, buffer[1..5], .little);
if (payload_len > buffer[5..].len) return error.CorruptObject;

const payload = buffer[5 .. 5 + payload_len];
```

```zig title="ObjectId hashing (excerpt)"
fn hash(obj_type: ObjectType, payload: []const u8) ObjectId {
    var hasher = std.crypto.hash.blake3.Blake3.init(.{});
    hasher.update(&[_]u8{@intFromEnum(obj_type)});
    hasher.update(payload);
    var out: [32]u8 = undefined;
    hasher.final(out[0..]);
    return .{ .hash = out };
}
```

## Tests

- `test "object store write/read round-trip"`
