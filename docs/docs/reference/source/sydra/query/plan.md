---
sidebar_position: 10
title: src/sydra/query/plan.zig
---

# `src/sydra/query/plan.zig`

## Purpose

Builds a logical plan from the sydraQL AST ([`ast.zig`](./ast.md)).

Logical plans are later optimized and lowered into a physical plan.

## See also

- [Validator](./validator.md) (ensures the AST is semantically valid)
- [Optimizer](./optimizer.md)
- [Physical plan builder](./physical.md)
- [Operator pipeline](./operator.md)

## Definition index (public)

### `pub const BuildError = error { ... }`

- `UnsupportedStatement` — currently only `SELECT` is supported by the logical planner

### `pub const Node = union(enum)`

Logical node kinds:

- `scan`
- `one_row`
- `filter`
- `project`
- `aggregate`
- `sort`
- `limit`

### `pub const ColumnInfo = struct { ... }`

- `name: []const u8`
- `expr: *const ast.Expr`

This is the “schema” that flows through planning and execution.

### `pub const RollupHint = struct { ... }`

- `bucket_expr: *const ast.Expr` — currently used to mark `time_bucket(...)` grouping expressions

### `pub fn nodeOutput(node: *Node) []const ColumnInfo`

Returns the output schema for a node.

### `pub const Builder`

Fields:

- `allocator: std.mem.Allocator`
- `column_counter: usize = 0` — used to generate stable column names across multiple SELECT lists

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

## Node payload structs (public)

Each `Node` tag has a corresponding payload struct:

- `Scan`:
  - `source: *const ast.Select`
  - `selector: ?ast.Selector`
  - `output: []const ColumnInfo`
- `OneRow`:
  - `output: []const ColumnInfo` — empty schema seed for constant `SELECT`
- `Filter`:
  - `input: *Node`
  - `predicate: *const ast.Expr` — combined predicate (may re-build an AND chain)
  - `output: []const ColumnInfo`
  - `conjunctive_predicates: []const *const ast.Expr` — flattened `AND` clauses from the WHERE predicate
- `Project`:
  - `input: *Node`
  - `projections: []const ast.Projection`
  - `output: []const ColumnInfo`
- `Aggregate`:
  - `input: *Node`
  - `groupings: []const ast.GroupExpr`
  - `projections: []const ast.Projection`
  - `fill: ?ast.FillClause`
  - `rollup_hint: ?RollupHint`
  - `output: []const ColumnInfo`
- `Sort`:
  - `input: *Node`
  - `ordering: []const ast.OrderExpr`
  - `output: []const ColumnInfo`
- `Limit`:
  - `input: *Node`
  - `limit: ast.LimitClause`
  - `output: []const ColumnInfo`

## Internal helpers (non-public)

Important builder helpers in the implementation:

- `buildSelect` — constructs the node chain in this order:
  - `one_row` (no selector) or `scan` (selector present)
  - optional `filter` → optional `aggregate` → `project` → optional `sort` → optional `limit`
- `collectPredicates` — flattens `a AND b` binary expressions into a slice
- `combinePredicates` — rebuilds a single AND-chain expression and unions spans
- `inferProjectionName` — generates output column names when no alias is provided
- `defaultScanColumns` — creates synthetic identifier expressions for `time` and `value`

## Tests

Inline tests cover simple select planning, conjunctive predicates, rollup hints, and alias retention.

## Code excerpt

```zig title="src/sydra/query/plan.zig (node chain + buildSelect excerpt)"
pub const Node = union(enum) {
    scan: Scan,
    one_row: OneRow,
    filter: Filter,
    project: Project,
    aggregate: Aggregate,
    sort: Sort,
    limit: Limit,
};

fn buildSelect(self: *Builder, select: *const ast.Select) (BuildError || std.mem.Allocator.Error)!*Node {
    const projection_columns = try self.buildColumns(select.projections);
    self.column_counter += projection_columns.len;

    var current: *Node = undefined;
    if (select.selector == null) {
        current = try self.makeNode(.{
            .one_row = .{
                .output = empty_columns[0..],
            },
        });
    } else {
        const scan_columns = try self.defaultScanColumns();
        current = try self.makeNode(.{
            .scan = .{
                .source = select,
                .selector = select.selector,
                .output = scan_columns,
            },
        });
    }

    var filter_list = ManagedArrayList(*const ast.Expr).init(self.allocator);
    try self.collectPredicates(select.predicate, &filter_list);
    var filter_conditions: []const *const ast.Expr = &.{};
    if (filter_list.items.len != 0) {
        filter_conditions = try filter_list.toOwnedSlice();
        const predicate = try self.combinePredicates(filter_conditions);
        current = try self.makeNode(.{
            .filter = .{
                .input = current,
                .predicate = predicate,
                .output = nodeOutput(current),
                .conjunctive_predicates = filter_conditions,
            },
        });
    }
    filter_list.deinit();

    if (needsAggregation(select)) {
        const rollup_hint = detectRollupHint(select.groupings);
        current = try self.makeNode(.{
            .aggregate = .{
                .input = current,
                .groupings = select.groupings,
                .projections = select.projections,
                .fill = select.fill,
                .rollup_hint = rollup_hint,
                .output = projection_columns,
            },
        });
    }

    current = try self.makeNode(.{
        .project = .{
            .input = current,
            .projections = select.projections,
            .output = projection_columns,
        },
    });

    return current;
}
```
