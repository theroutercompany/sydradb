---
sidebar_position: 17
title: src/sydra/query/exec.zig
---

# `src/sydra/query/exec.zig`

## Purpose

End-to-end sydraQL execution entrypoint used by the HTTP `/api/v1/sydraql` handler.

This module orchestrates:

- parse → validate → logical plan → optimize → physical plan → execute

## Public API

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

