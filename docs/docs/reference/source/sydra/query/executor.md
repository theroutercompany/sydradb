---
sidebar_position: 16
title: src/sydra/query/executor.zig
---

# `src/sydra/query/executor.zig`

## Purpose

Wraps the operator pipeline with a cursor API suitable for HTTP/pgwire surfaces.

## Public API

### `pub const ExecutionStats`

Timing and counters set by `exec.execute`, including:

- parse/validate/optimize/physical/pipeline timings (microseconds)
- `trace_id`
- `rows_emitted`, `rows_scanned`

### `pub const ExecutionCursor`

Fields:

- `operator: *Operator` – root of the operator pipeline
- `columns: []const plan.ColumnInfo` – output schema
- `arena: ?*ArenaAllocator` – optionally owned arena for AST/plan lifetime
- `stats: ExecutionStats`

Methods:

- `next()` – returns the next row from the operator pipeline
- `deinit()` – destroys the operator and (if present) frees the arena
- `collectOperatorStats(allocator)` – returns a snapshot list from the pipeline

### `pub const Executor`

Creates an `ExecutionCursor` from a physical plan:

- `Executor.init(allocator, engine, physical_plan)`
- `run()` → `ExecutionCursor`

