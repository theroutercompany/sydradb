---
sidebar_position: 11
title: src/sydra/query/optimizer.zig
---

# `src/sydra/query/optimizer.zig`

## Purpose

Applies logical rewrites to improve the plan before physical lowering.

## Public API

### `pub fn optimize(allocator: std.mem.Allocator, root: *plan.Node) !*plan.Node`

Currently applies:

1. **Projection pruning / merge** (`pruneProjects`)
2. **Predicate pushdown** (`pushdownPredicates`)

## Notable rewrite behaviors

- Collapses adjacent `project` nodes in some cases by merging column sets.
- Pushes `filter` nodes below:
  - `project`
  - `sort`
  - `limit`
  - other `filter` nodes (merging conjunctive predicate lists)
- Contains logic to push parts of a filter below an aggregate when predicates reference grouping expressions.

