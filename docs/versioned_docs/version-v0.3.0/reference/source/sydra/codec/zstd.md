---
sidebar_position: 5
title: src/sydra/codec/zstd.zig
---

# `src/sydra/codec/zstd.zig`

## Purpose

Placeholder wrapper for Zstandard compression.

The module comment notes intended future implementations such as:

- linking zstd via FFI
- using a subprocess

## Public API

### `pub fn compress(alloc: anytype, input: []const u8) []const u8`

Current implementation returns an empty slice (`&[_]u8{}`).

### `pub fn decompress(alloc: anytype, input: []const u8) []const u8`

Current implementation returns an empty slice (`&[_]u8{}`).

## Code excerpt

```zig title="src/sydra/codec/zstd.zig"
// Thin zstd wrapper (placeholder). In production, link FFI or subprocess.
pub fn compress(_: anytype, _: []const u8) []const u8 {
    return &[_]u8{};
}
pub fn decompress(_: anytype, _: []const u8) []const u8 {
    return &[_]u8{};
}
```
