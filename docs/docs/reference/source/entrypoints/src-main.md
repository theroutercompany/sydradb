---
sidebar_position: 1
title: src/main.zig
---

# `src/main.zig`

## Purpose

Process entrypoint for the SydraDB binary.

## Imports

- `std` – Zig standard library
- `sydra/server.zig` – CLI dispatch + runtime orchestration
- `sydra/alloc.zig` – allocator handle wrapper

## Public API

### `pub fn main() !void`

High-level behavior:

1. Initializes `alloc_mod.AllocatorHandle`.
2. Prints `sydraDB pre-alpha`.
3. Calls `server.run(&alloc_handle)`.

Notes:

- The allocator handle must remain alive for the duration of `server.run`.
- All command-line behavior is implemented in `src/sydra/server.zig`.

