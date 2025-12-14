---
sidebar_position: 2
title: src/sydra/alloc.zig
---

# `src/sydra/alloc.zig`

## Purpose

Implements build-time allocator selection and provides a single `AllocatorHandle` abstraction for the rest of the runtime.

This module supports three allocator modes (selected via `build_options.allocator_mode`):

- `default`: `std.heap.GeneralPurposeAllocator(.{})`
- `mimalloc`: mimalloc-backed allocator vtable
- `small_pool`: a custom small-object allocator with:
  - optional sharded slab allocator for small allocations (`slab_shard.zig`)
  - mutex-protected bucket allocator for a fixed set of sizes
  - fallback to a backing `GeneralPurposeAllocator` for oversize/aligned allocations

## Public build flags

- `pub const mode = build_options.allocator_mode`
- `pub const is_mimalloc = (mode == "mimalloc")`
- `pub const is_small_pool = (mode == "small_pool")`

There is a comptime guard that rejects unknown `allocator_mode` values.

## AllocatorHandle (main integration point)

### `pub const AllocatorHandle = ...`

`AllocatorHandle` is a compile-time selected struct:

- If `is_small_pool`:
  - stores `pool: SmallPoolAllocator`
  - exposes:
    - `init()`
    - `allocator() std.mem.Allocator`
    - `snapshotSmallPoolStats() SmallPoolAllocator.Stats`
    - `enterEpoch() ?u64`
    - `leaveEpoch(observed: u64) void`
    - `advanceEpoch() ?u64`
    - `deinit()`
- Else if `is_mimalloc`:
  - stores `mimalloc: MimallocAllocator`
  - exposes `init()`, `allocator()`, `deinit()` (no-op)
- Else (`default`):
  - stores `gpa: std.heap.GeneralPurposeAllocator(.{})`
  - exposes `init()`, `allocator()`, `deinit()` (calls `gpa.deinit()`)

The rest of SydraDB typically receives `*AllocatorHandle` and calls `handle.allocator()` to obtain `std.mem.Allocator`.

## Mimalloc mode

When `allocator_mode == "mimalloc"`, `MimallocAllocator` implements a `std.mem.Allocator.VTable` backed by `mi_malloc_aligned`, `mi_realloc_aligned`, and `mi_free`.

Notes:

- `resizeFn` always returns `false` (in-place resize unsupported); callers must remap/copy.
- `allocFn` and `remapFn` translate `std.mem.Alignment` to a byte count, using `1` for a 0-byte alignment.

## Small pool mode (custom allocator)

### High-level design

`SmallPoolAllocator` routes allocations through three strategies, in priority order:

1. **Shard allocator** (optional): `slab_shard.Shard` instances managed by `ShardManager`.
2. **Bucket allocator**: fixed size classes with per-bucket mutex and slab refills.
3. **Fallback allocator**: backing `GeneralPurposeAllocator` for oversize or stricter alignments.

### Key constants (small_pool)

- `default_alignment`: `@sizeOf(usize)` alignment
- `header_size`: `default_alignment.toByteUnits()`
  - bucket and shard allocators return `ptr + header_size`
- `slab_bytes: usize = 64 * 1024`
- `bucket_sizes = [16, 24, 32, 48, 64, 96, 128, 192, 256]`
- `fallback_bucket_bounds = [64, 128, 256, 512, 1024, 2048, 4096, 8192]`
- `pub const max_shard_size`: derived from the generated shard class table

### ShardManager (optional sharded allocator)

`ShardManager` owns `[]slab_shard.Shard` and provides:

- `currentShard()` returning a per-thread shard
  - uses a `threadlocal` `ThreadShardState` cache (`small_pool_tls_state`)
  - assigns shard indices via an atomic counter (round-robin)
- `freeLocal(ptr)`:
  - detects the owning shard via `slab_shard.Shard.owningShard(ptr)`
  - if local shard owns it: calls `free`
  - otherwise: calls `freeDeferred`
- epoch helpers:
  - `enterEpoch()` → `currentShard().currentEpoch()`
  - `leaveEpoch(observed)` → `currentShard().observeEpoch(observed)`
  - `advanceEpoch()` → `currentShard().advanceEpoch()`
- `collectGarbage()` calls `collectGarbage()` on all shards

Shard manager initialization is controlled by `build_options.allocator_shards`:

- `configured_shard_count > 0` → tries to create a manager
- failures are caught and result in “no shards” mode

### Bucket allocator

For sizes that fit a `bucket_sizes` class:

- `allocBucket` locks a bucket mutex, refills slabs when needed, and pops from a free list.
- `refillBucket` allocates a new slab from the backing allocator and builds a linked list of `FreeNode` blocks.
- `freeSmall` linearly scans buckets, checking if a pointer belongs to that bucket’s slabs, and pushes the node back onto the free list.

The implementation tracks lock timing and contention:

- wait/hold times in nanoseconds
- acquisition count
- contention count (wait time over `lock_wait_threshold_ns`)

### Fallback tracking + stats

For allocations that bypass buckets/shards, the allocator updates counters:

- `fallback_allocs`, `fallback_frees`, `fallback_resizes`, `fallback_remaps`
- `fallback_sizes[...]` counts allocation sizes binned by `fallback_bucket_bounds`

`pub const Stats` and `pub fn snapshotStats()` return a detailed snapshot including:

- per-bucket usage (`allocations`, `in_use`, `high_water`, `slabs`, free-list length)
- per-bucket lock stats
- fallback counters and size histogram
- shard manager summary (if enabled): shard count, alloc hit/miss counts, deferred totals, epoch info

## Tests (small_pool only)

When built with `"small_pool"` mode, this file includes tests for:

- oversize allocations falling back to the backing allocator
- shard allocation hit tracking in stats
- per-thread shard assignment
- cross-thread frees being deferred and later reclaimed via epochs + garbage collection

## Code excerpts

```zig title="src/sydra/alloc.zig (mode selection + comptime guard)"
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

```zig title="src/sydra/alloc.zig (AllocatorHandle excerpt)"
threadlocal var small_pool_tls_state: SmallPoolAllocator.ThreadShardState = .{};

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
