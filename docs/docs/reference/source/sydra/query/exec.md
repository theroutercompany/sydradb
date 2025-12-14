---
sidebar_position: 17
title: src/sydra/query/exec.zig
---

# `src/sydra/query/exec.zig`

## Purpose

End-to-end sydraQL execution entrypoint used by the HTTP `/api/v1/sydraql` handler.

This module orchestrates:

- parse → validate → logical plan → optimize → physical plan → execute

## Definition index (public)

### `pub const ExecuteError`

Union of the error sets from:

- parser
- validator
- planner/optimizer/physical builder
- executor/operator pipeline
- allocator errors

Plus `ValidationFailed`.

### `pub fn execute(allocator, engine, query) !ExecutionCursor`

Behavior:

- Builds an arena allocator used for parsing/analysis/planning artifacts.
- Records timings (microseconds) for each stage.
- Runs the executor pipeline and returns an `ExecutionCursor`.
- Generates a random `trace_id` (16 chars from a base32-like alphabet).
- Attaches the arena to the cursor so `cursor.deinit()` can free it.

## Implementation notes (non-public)

### Arena lifetime

`execute` allocates a `std.heap.ArenaAllocator` on the heap (`allocator.create`) and:

- uses it for parsing, validation, planning, optimization, and physical lowering
- stores the arena pointer on the returned cursor (`cursor.arena`)

This keeps the AST/plan pointers valid for as long as the cursor is alive.

### Stage timings

The function records timestamps via `std.time.microTimestamp()` and stores deltas into `cursor.stats`:

- `parse_us`
- `validate_us`
- `optimize_us`
- `physical_us`
- `pipeline_us`

### Trace IDs

The helper `randomTraceId`:

- allocates a 16-byte buffer from the arena
- fills it with crypto-random bytes
- maps each byte to a character in `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`
