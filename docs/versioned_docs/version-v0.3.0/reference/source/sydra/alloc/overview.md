---
sidebar_position: 1
title: Allocator overview (src/sydra/alloc)
---

# Allocator overview (`src/sydra/alloc*`)

SydraDB centralizes allocator selection and (optionally) uses a custom small-object allocator for better throughput and observability.

The allocator mode is chosen at build time via `build_options.allocator_mode`:

- `"default"` → `std.heap.GeneralPurposeAllocator`
- `"mimalloc"` → mimalloc-backed `std.mem.Allocator` vtable
- `"small_pool"` → custom small-object allocator + `GeneralPurposeAllocator` fallback

Shard count (for the small pool) is controlled by `build_options.allocator_shards`.

## Module map

- Entrypoint and build-time selection: `src/sydra/alloc.zig` → `alloc-zig`
- Sharded slab allocator used by the small pool: `src/sydra/alloc/slab_shard.zig` → `slab-shard`

## Code excerpts

```zig title="src/sydra/alloc.zig (build-time mode selection)"
const std = @import("std");
const build_options = @import("build_options");

const allocator_mode = build_options.allocator_mode;
const use_mimalloc = std.mem.eql(u8, allocator_mode, "mimalloc");
const use_small_pool = std.mem.eql(u8, allocator_mode, "small_pool");

pub const mode = allocator_mode;
pub const is_mimalloc = use_mimalloc;
pub const is_small_pool = use_small_pool;

comptime {
    if (!std.mem.eql(u8, allocator_mode, "default") and !use_mimalloc and !use_small_pool) {
        @compileError("unknown allocator-mode: " ++ allocator_mode);
    }
}
```

```zig title="src/sydra/alloc.zig (AllocatorHandle shape, excerpt)"
pub const AllocatorHandle = if (use_small_pool) struct {
    pool: SmallPoolAllocator,

    pub fn init() AllocatorHandle {
        return .{ .pool = SmallPoolAllocator.init() };
    }

    pub fn allocator(self: *AllocatorHandle) std.mem.Allocator {
        return self.pool.allocator();
    }
} else if (use_mimalloc) struct {
    mimalloc: MimallocAllocator,

    pub fn init() AllocatorHandle {
        return .{ .mimalloc = MimallocAllocator.init() };
    }

    pub fn allocator(self: *AllocatorHandle) std.mem.Allocator {
        return self.mimalloc.allocator();
    }
} else struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),

    pub fn init() AllocatorHandle {
        return .{ .gpa = std.heap.GeneralPurposeAllocator(.{}){} };
    }

    pub fn allocator(self: *AllocatorHandle) std.mem.Allocator {
        return self.gpa.allocator();
    }
};
```
