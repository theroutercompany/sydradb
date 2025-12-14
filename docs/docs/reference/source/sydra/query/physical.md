---
sidebar_position: 12
title: src/sydra/query/physical.zig
---

# `src/sydra/query/physical.zig`

## Purpose

Lowers a logical plan into a physical plan with execution-oriented metadata.

The physical plan carries hints such as extracted time bounds for scan pushdown.

## Public API

### `pub const PhysicalPlan`

- `root: *Node`

### `pub const Node = union(enum)`

Physical node kinds:

- `scan`
- `filter`
- `project`
- `aggregate`
- `sort`
- `limit`

### `pub fn build(allocator, logical_root) !PhysicalPlan`

Recursively transforms logical nodes into physical nodes, propagating context (notably time bounds).

### `pub fn nodeOutput(node: *Node) []const plan.ColumnInfo`

Returns the output schema for a physical node.

## Time bounds extraction

`TimeBounds` is derived from filter conjunctive predicates when it recognizes comparisons between:

- an identifier whose name is `time` (case-insensitive), and
- an integer literal

Supported operators include:

- `>=`, `>`, `<=`, `<`, `=`

Extracted bounds are merged and propagated down into the scan node to constrain `Engine.queryRange`.

