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

### `pub fn get(self, allocator, id: ObjectId) !LoadedObject`

- Loads the object file into an allocated buffer.
- Validates the header and payload length.
- Returns a `LoadedObject` with `payload` as a slice into that buffer.

Callers must free `loaded.payload` using the same allocator passed to `get`.

## Tests

- `test "object store write/read round-trip"`

