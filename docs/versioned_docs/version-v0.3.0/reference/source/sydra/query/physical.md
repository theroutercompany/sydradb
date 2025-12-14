---
sidebar_position: 12
title: src/sydra/query/physical.zig
---

# `src/sydra/query/physical.zig`

## Purpose

Lowers a logical plan into a physical plan with execution-oriented metadata.

The physical plan carries hints such as extracted time bounds for scan pushdown.

## Definition index (public)

### `pub const BuildError`

Alias:

- `std.mem.Allocator.Error`

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

## Node payload structs (public)

Physical nodes are “execution oriented” versions of logical nodes:

- `Scan`:
  - `selector: ?ast.Selector`
  - `output: []const plan.ColumnInfo`
  - `rollup_hint: ?plan.RollupHint`
  - `time_bounds: TimeBounds`
- `Filter`:
  - `predicate: *const ast.Expr`
  - `output: []const plan.ColumnInfo`
  - `child: *Node`
  - `conjunction_count: usize` — number of flattened conjuncts in the logical filter
  - `time_bounds: TimeBounds` — bounds extracted from the filter conjuncts
- `Project`:
  - `columns: []const plan.ColumnInfo`
  - `child: *Node`
  - `reuse_child_schema: bool` — true when the child is also a project
- `Aggregate`:
  - `groupings: []const ast.GroupExpr`
  - `rollup_hint: ?plan.RollupHint`
  - `output: []const plan.ColumnInfo`
  - `child: *Node`
  - `requires_hash: bool` — true when `GROUP BY` exists
  - `has_fill_clause: bool` — true when a fill clause exists
- `Sort`:
  - `ordering: []const ast.OrderExpr`
  - `child: *Node`
  - `is_stable: bool` — currently always `true`
  - `output: []const plan.ColumnInfo`
- `Limit`:
  - `limit: ast.LimitClause`
  - `child: *Node`
  - `offset: usize` — `limit.offset orelse 0`
  - `output: []const plan.ColumnInfo`

### `pub const TimeBounds = struct { ... }`

Represents extracted time constraints:

- `min: ?i64` / `min_inclusive: bool`
- `max: ?i64` / `max_inclusive: bool`

## Time bounds extraction (as implemented)

`TimeBounds` is derived from filter conjunctive predicates when it recognizes comparisons between:

- an identifier whose name is `time` (case-insensitive), and
- an integer literal

Supported operators include:

- `>=`, `>`, `<=`, `<`, `=`

```zig title="timeBoundsFromExpr (excerpt)"
fn timeBoundsFromExpr(expr: *const ast.Expr) ?TimeBounds {
    if (expr.* != .binary) return null;
    const bin = expr.binary;
    const lhs_time = exprIsTimeIdentifier(bin.left);
    const rhs_time = exprIsTimeIdentifier(bin.right);
    if (!lhs_time and !rhs_time) return null;

    const op = bin.op;
    if (lhs_time and rhs_time) return null;

    const literal = if (lhs_time) convertTimeLiteral(bin.right) else convertTimeLiteral(bin.left);
    if (literal == null) return null;
    const value = literal.?;

    var bounds = TimeBounds{};
    if (lhs_time) {
        switch (op) {
            .greater_equal => { bounds.min = value; bounds.min_inclusive = true; },
            .greater => { bounds.min = value; bounds.min_inclusive = false; },
            .less_equal => { bounds.max = value; bounds.max_inclusive = true; },
            .less => { bounds.max = value; bounds.max_inclusive = false; },
            .equal => { bounds.min = value; bounds.max = value; },
            else => return null,
        }
    } else {
        // time on right side flips the bounds direction
        // ...
    }
    return bounds;
}
```

Extracted bounds are merged and propagated down into the scan node to constrain `Engine.queryRange`.

Important notes:

- Only the identifier value `time` is recognized (it does not match `tag.time` or other dotted identifiers).
- Only integer literals are accepted for bound extraction (no floats, strings, or `now()` yet).
- Bounds are merged across conjuncts using “tightest wins” semantics:
  - higher minimum replaces lower minimum
  - lower maximum replaces higher maximum
  - equal bounds combine inclusivity
