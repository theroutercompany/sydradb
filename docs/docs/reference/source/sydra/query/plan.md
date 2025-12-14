---
sidebar_position: 10
title: src/sydra/query/plan.zig
---

# `src/sydra/query/plan.zig`

## Purpose

Builds a logical plan from the sydraQL AST.

Logical plans are later optimized and lowered into a physical plan.

## Public API

### `pub const Node = union(enum)`

Logical node kinds:

- `scan`
- `filter`
- `project`
- `aggregate`
- `sort`
- `limit`

### `pub const ColumnInfo`

- `name: []const u8`
- `expr: *const ast.Expr`

### `pub fn nodeOutput(node: *Node) []const ColumnInfo`

Returns the output schema for a node.

### `pub const Builder`

Key methods:

- `Builder.init(allocator)`
- `build(statement)` – currently supports `SELECT` only

## Key behaviors (as implemented)

- Builds a default scan schema of `time` and `value` identifiers.
- Splits `WHERE a AND b AND c` into `Filter.conjunctive_predicates`.
- Determines whether aggregation is needed if:
  - any `GROUP BY` exists, or
  - any projection contains an aggregate/window function (via the function registry).
- Detects a rollup hint when `GROUP BY` includes `time_bucket(...)`.
- Projection column naming:
  - Uses explicit aliases when present
  - Otherwise uses identifier name, or `fnName_<n>`, or `_col<n>`

## Tests

Inline tests cover simple select planning, conjunctive predicates, rollup hints, and alias retention.

