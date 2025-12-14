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

