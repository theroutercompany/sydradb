---
sidebar_position: 15
title: src/sydra/query/operator.zig
---

# `src/sydra/query/operator.zig`

## Purpose

Implements the physical execution pipeline as a tree of operators producing rows.

This is the core runtime layer used by `executor.zig`.

## Public API

### `pub const Row`

- `schema: []const plan.ColumnInfo`
- `values: []Value`

### `pub const Operator`

An operator is a heap-allocated struct with:

- `next()` – returns the next row or `null` for end-of-stream
- `destroy()` – frees operator and internal payload
- `collectStats(list)` – collects operator stats snapshots from the pipeline

Operator types (payload variants):

- `scan`
- `filter`
- `project`
- `aggregate`
- `sort`
- `limit`
- `test_source` (test-only helper)

### `pub fn buildPipeline(allocator, engine, node: *physical.Node) !*Operator`

Builds an operator pipeline from a physical plan node.

Notable constraints (as implemented):

- Scan currently supports only `series_ref.by_id` selectors; name-based selection returns `UnsupportedPlan`.
- Time bounds are taken from the physical scan node (`TimeBounds`) and passed into `Engine.queryRange`.

## Observability

Each operator tracks:

- `name` (e.g. `"scan"`)
- `elapsed_us` (accumulated time spent in `next()`)
- `rows_out`

These stats are exposed via `ExecutionCursor.collectOperatorStats()`.

