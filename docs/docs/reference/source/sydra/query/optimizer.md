---
sidebar_position: 11
title: src/sydra/query/optimizer.zig
---

# `src/sydra/query/optimizer.zig`

## Purpose

Applies logical rewrites to improve the plan before physical lowering.

## See also

- [Logical plan builder](./plan.md)
- [Physical plan builder](./physical.md)
- [Orchestration entrypoint](./exec.md) (calls `optimize` during execution)

## Definition index (public)

### `pub const OptimizeError`

Alias:

- `plan.BuildError || std.mem.Allocator.Error`

### `pub fn optimize(allocator: std.mem.Allocator, root: *plan.Node) !*plan.Node`

Currently applies:

1. **Projection pruning / merge** (`pruneProjects`)
2. **Predicate pushdown** (`pushdownPredicates`)

## Notable rewrite behaviors

### Projection pruning / merge

`pruneProjects` walks the plan and collapses stacked projection layers:

- `project(project(child))`:
  - merges the parent projection column set into the child’s output schema
  - rewires the parent to point at the grandchild
- `project(aggregate(child))`:
  - merges projection columns into the aggregate output schema

Merging logic:

- `mergeColumns` tries to reuse existing `ColumnInfo` entries when the projection expression pointer matches a child column expression.
- Otherwise it generates a column name using:
  - alias if present
  - `_col{index}` fallback

### Predicate pushdown

`pushdownPredicates` tries to move filters as far down as possible by rewriting:

- `filter(project(x))` → `project(filter(x))`
- `filter(sort(x))` → `sort(filter(x))`
- `filter(limit(x))` → `limit(filter(x))`
- `filter(filter(x))` → merges predicate lists and rebuilds a combined predicate expression

### Pushing below aggregates (grouping-aware)

For `filter(aggregate(x))`, the optimizer splits conjunctive predicates into:

- **pushable** predicates that depend only on grouping keys/expressions
- **kept** predicates that depend on aggregate outputs or non-grouping expressions

The helper `exprUsesGrouping` attempts to recognize:

- direct grouping identifiers
- grouping expressions (call match against `GROUP BY` call with identical argument pointers)
- aliases that match grouping expressions

If there are pushable predicates, it inserts a new filter node *below* the aggregate.

## Internal helpers (non-public)

Key rewrite helpers in the implementation:

- `pruneProjects`
- `pushdownPredicates`
- `moveFilterBelowProject` / `moveFilterBelowSort` / `moveFilterBelowLimit`
- `mergeFilters` (concatenates predicate slices and rebuilds `predicate` via `buildPredicateExpr`)
- `pushFilterBelowAggregate`

Grouping/alias analysis helpers:

- `exprUsesGrouping`
- `exprIsGroupingKey` / `exprIsGroupingExpr`
- `identifierAliasMatchesGrouping` / `exprMatchesGrouping`
- `expressionsEqual` / `literalEqual` / `callEqual`

## Code excerpt

```zig title="src/sydra/query/optimizer.zig (top-level optimize + a pushdown rewrite excerpt)"
pub fn optimize(allocator: std.mem.Allocator, root: *plan.Node) OptimizeError!*plan.Node {
    try pruneProjects(allocator, root);
    try pushdownPredicates(root, allocator);
    return root;
}

fn moveFilterBelowProject(node_ptr: *plan.Node) void {
    const filter_data = node_ptr.filter;
    const project_ptr = filter_data.input;
    var project_data = project_ptr.project;

    var new_filter = filter_data;
    new_filter.input = project_data.input;
    new_filter.output = plan.nodeOutput(project_data.input);

    project_data.input = project_ptr;
    project_ptr.* = .{ .filter = new_filter };

    node_ptr.* = .{ .project = project_data };
}
```
