---
sidebar_position: 3
title: src/sydra/alloc/slab_shard.zig
---

# `src/sydra/alloc/slab_shard.zig`

## Purpose

Implements a sharded slab allocator intended for small allocations, with support for **deferred frees** gated by a simple **epoch** mechanism.

This module is used by `src/sydra/alloc.zig` in `"small_pool"` mode when shard support is enabled.

## Public API

### `pub const SlabClass`

Defines one allocation class:

- `size: usize` – maximum user size for the class
- `alloc_size: usize` – bytes per block including internal header
- `objects_per_slab: usize` – blocks per slab allocation

### `pub const ShardConfig`

- `classes: []const SlabClass`
- `slab_bytes: usize`

Note: `slab_bytes` is currently not used directly by the shard; callers generally pre-compute `objects_per_slab` from a desired slab size.

### `pub const Summary`

- `deferred_total: usize` – total nodes in deferred queues
- `current_epoch: u64` – current global epoch
- `min_observed_epoch: u64` – last observed epoch value for this shard

### `pub const SlabStats`

Per-class snapshot:

- `class: SlabClass`
- `slabs: usize`
- `free_nodes: usize`
- `allocated: usize`
- `in_use: usize`
- `high_water: usize`
- `deferred: usize`
- `current_epoch: u64`
- `min_observed_epoch: u64`

### `pub const Shard = struct { ... }`

#### Lifecycle

- `pub fn init(allocator, config) !Shard`
  - allocates `states: []ClassState` (one per class)
  - initializes `global_epoch = 1`, `thread_epoch = 0`
- `pub fn assignOwner(self: *Shard) void`
  - records `owner = self` on each class state (needed for `owningShard`)
- `pub fn deinit(self: *Shard) void`
  - frees all slab memory and the states array

#### Allocation

- `pub fn allocate(self, size, alignment, ret_addr) ?[*]u8`
  - finds the first class where `size <= class.size`
  - rejects alignments stricter than `@sizeOf(usize)`
  - refills the free list by allocating a slab when empty
  - returns `block_ptr + header_size`

#### Free paths

- `pub fn free(self: *Shard, ptr: [*]u8) bool`
  - pushes the block back onto the class free list immediately
- `pub fn freeDeferred(self: *Shard, ptr: [*]u8) bool`
  - pushes the block onto an atomic “deferred” stack tagged with the current epoch
  - intended for cross-thread frees

#### Garbage collection and epochs

- `pub fn collectGarbage(self: *Shard) void`
  - moves deferred nodes back onto the free list when `node.epoch <= min_observed_epoch`
- `pub fn currentEpoch(self: *Shard) u64`
- `pub fn advanceEpoch(self: *Shard) u64`
  - increments and returns the new epoch value
- `pub fn observeEpoch(self: *Shard, epoch: u64) void`
  - records an “observed” epoch; used as a simple reclamation barrier

#### Introspection

- `pub fn summary(self: *Shard) Summary`
- `pub fn snapshot(self: *Shard, allocator) ![]SlabStats`

Callers must free the `snapshot()` output slice.

#### Ownership

- `pub fn owningShard(ptr: [*]u8) ?*Shard`
  - reads the internal header associated with `ptr` to discover `class_state.owner`
  - requires that `assignOwner()` has been called

## Key internal helpers

- `refill(self, state, ret_addr)` allocates a new slab and rebuilds the free list for that class.
- `findState(self, size)` selects a class by size.
- `ownsState(self, state)` validates that a `ClassState` pointer belongs to this shard.

## Concurrency model (as implemented)

- The class free list (`free_list`) is not synchronized and is expected to be used by a single owning thread.
- The deferred stack (`deferred`) is an atomic `?*FreeNode` updated via CAS.
- Epoch gating uses:
  - `global_epoch` (monotonic counter)
  - `thread_epoch` (“min observed epoch”)

## Tests

This file includes tests for:

- allocate/free lifecycle
- `owningShard` correctness
- deferred frees appearing in snapshots and being reclaimed after an epoch advance + observe + garbage collection

## Code excerpts

```zig title="src/sydra/alloc/slab_shard.zig (allocation classes)"
pub const SlabClass = struct {
    size: usize,
    alloc_size: usize,
    objects_per_slab: usize,
};

pub const ShardConfig = struct {
    classes: []const SlabClass,
    slab_bytes: usize,
};
```

```zig title="src/sydra/alloc/slab_shard.zig (allocate/freeDeferred/collectGarbage excerpt)"
pub fn allocate(self: *Shard, size: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const state = self.findState(size) orelse return null;
    if (alignment.toByteUnits() > default_alignment.toByteUnits()) return null;
    if (state.free_list == null) {
        self.refill(state, ret_addr) catch return null;
    }
    const node = state.free_list orelse return null;
    state.free_list = node.next;
    state.allocations += 1;
    state.in_use += 1;
    if (state.in_use > state.high_water) state.high_water = state.in_use;
    const base_ptr = @as([*]u8, @ptrCast(node));
    return base_ptr + header_size;
}

pub fn freeDeferred(self: *Shard, ptr: [*]u8) bool {
    const base = ptr - header_size;
    const node = @as(*FreeNode, @ptrCast(@alignCast(base)));
    const state = node.class_state;
    const owned = self.ownsState(state);
    std.debug.assert(owned);
    if (!owned) return false;
    std.debug.assert(state.owner == self);
    const epoch = self.global_epoch.load(.monotonic);
    node.epoch = epoch;
    var expected = state.deferred.load(.monotonic);
    while (true) {
        node.next = expected;
        const result = state.deferred.compareExchangeWeak(expected, node, .monotonic, .monotonic);
        switch (result) {
            .success => return true,
            .failure => |actual| {
                expected = actual;
                continue;
            },
        }
    }
}

pub fn collectGarbage(self: *Shard) void {
    const min_epoch = self.thread_epoch.load(.monotonic);
    for (self.states) |*state| {
        while (true) {
            const head = state.deferred.load(.monotonic);
            const node = head orelse break;
            if (node.epoch > min_epoch) break;
            const next = node.next;
            if (state.deferred.compareExchangeWeak(head, next, .monotonic, .monotonic) == .success) {
                node.next = state.free_list;
                state.free_list = node;
                if (state.in_use > 0) state.in_use -= 1;
            }
        }
    }
}
```
