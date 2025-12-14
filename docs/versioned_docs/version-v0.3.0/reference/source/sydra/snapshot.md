---
sidebar_position: 7
title: src/sydra/snapshot.zig
---

# `src/sydra/snapshot.zig`

## Purpose

Implements a simple snapshot/restore mechanism for SydraDB’s on-disk state by copying a small set of files/directories:

- `MANIFEST`
- `wal/`
- `segments/`
- `tags.json`

This is used by the CLI `snapshot` / `restore` commands in `src/sydra/server.zig`.

## Public API

### `pub fn snapshot(alloc: std.mem.Allocator, data_dir: std.fs.Dir, dst_path: []const u8) !void`

Creates (or reuses) `dst_path` under the current working directory and copies:

- `MANIFEST` (if present)
- `wal/` recursively (if present)
- `segments/` recursively (if present)
- `tags.json` (if present)

### `pub fn restore(alloc: std.mem.Allocator, data_dir: std.fs.Dir, src_path: []const u8) !void`

Opens `src_path` under the current working directory and copies back into `data_dir`:

- `MANIFEST` (if present)
- `wal/` recursively (if present)
- `segments/` recursively (if present)
- `tags.json` (if present)

```zig title="snapshot/restore (excerpt)"
pub fn snapshot(alloc: std.mem.Allocator, data_dir: std.fs.Dir, dst_path: []const u8) !void {
    // Simple manifested copy: copy MANIFEST, wal/, segments/, tags.json
    try std.fs.cwd().makePath(dst_path);
    var dst = try std.fs.cwd().openDir(dst_path, .{ .iterate = true });
    defer dst.close();
    try copyIfExists(data_dir, dst, "MANIFEST");
    try copyDirRecursive(alloc, data_dir, dst, "wal");
    try copyDirRecursive(alloc, data_dir, dst, "segments");
    try copyIfExists(data_dir, dst, "tags.json");
}

pub fn restore(alloc: std.mem.Allocator, data_dir: std.fs.Dir, src_path: []const u8) !void {
    var src = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src.close();
    try copyIfExists(src, data_dir, "MANIFEST");
    try copyDirRecursive(alloc, src, data_dir, "wal");
    try copyDirRecursive(alloc, src, data_dir, "segments");
    try copyIfExists(src, data_dir, "tags.json");
}
```

## Key internal helpers

### `fn copyIfExists(from: std.fs.Dir, to: std.fs.Dir, name: []const u8) !void`

Copies `name` from `from` → `to`, ignoring `error.FileNotFound`.

### `fn copyDirRecursive(alloc: std.mem.Allocator, from: std.fs.Dir, to: std.fs.Dir, name: []const u8) !void`

Recursively copies a directory tree:

- Opens `from.openDir(name, .{ .iterate = true })`; ignores `error.FileNotFound`.
- Ensures the destination path exists (`to.makePath(name)`).
- Iterates entries:
  - files: `copyFile`
  - directories: recurse

Note: `alloc` is currently unused by the implementation.
