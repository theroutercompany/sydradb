---
sidebar_position: 15
title: src/sydra/query/operator.zig
---

# `src/sydra/query/operator.zig`

## Purpose

Implements the physical execution pipeline as a tree of operators producing rows.

This is the core runtime layer used by `executor.zig`.

## See also

- [Executor](./executor.md)
- [Physical plan builder](./physical.md)
- [Expression evaluation](./expression.md) and [Value representation](./value.md)
- [Engine](../engine.md) (scan operator delegates to `Engine.queryRange`)

## Definition index (public)

### `pub const Value`

Alias:

- `value.Value` from `src/sydra/query/value.zig`

### `pub const ExecuteError`

Composite error set:

- `std.mem.Allocator.Error` – allocations for operator buffers / owned rows / group state
- `expression.EvalError` – expression evaluation inside operators
- `QueryRangeError` – derived from `Engine.queryRange` return type (scan I/O)
- plus:
  - `UnsupportedPlan`
  - `UnsupportedAggregate`

```zig title="ExecuteError (from src/sydra/query/operator.zig)"
const QueryRangeError = @typeInfo(@typeInfo(@TypeOf(engine_mod.Engine.queryRange)).@"fn".return_type.?).error_union.error_set;

pub const ExecuteError = std.mem.Allocator.Error || expression.EvalError || QueryRangeError || error{
    UnsupportedPlan,
    UnsupportedAggregate,
};
```

### `pub const Row`

Row returned by `Operator.next()`:

- `schema: []const plan.ColumnInfo` – borrowed schema slice
- `values: []Value` – values aligned with `schema`

Lifetime notes:

- Most operators reuse an internal buffer (`scan`, `project`, `aggregate`), so `values` is only valid until the next `next()` call.
- `filter` and `limit` pass through child row buffers without copying.
- `sort` returns owned row copies valid until the sort operator is destroyed.

### `pub const Operator`

An operator is a heap-allocated struct with:

- `next()` – returns the next row or `null` for end-of-stream
- `destroy()` – frees operator and internal payload
- `collectStats(list)` – collects operator stats snapshots from the pipeline

Operator types (payload variants):

- `scan`
- `one_row`
- `filter`
- `project`
- `aggregate`
- `sort`
- `limit`
- `test_source` (test-only helper)

Important fields (public + runtime internals):

- `allocator: std.mem.Allocator`
- `schema: []const plan.ColumnInfo`
- `next_fn`, `destroy_fn`: function pointers implementing the operator behavior
- `stats: Stats` – name, elapsed_us, rows_out

Nested public types:

- `Stats` – live counters
- `StatsSnapshot` – copyable view collected by `collectStats`

Behavior notes:

- `Operator.next()` wraps `next_fn` to measure elapsed time (`std.time.microTimestamp`) and increments `rows_out` when a row is produced.
- `Operator.destroy()` calls the payload destroy routine then frees the operator allocation.

```zig title="Operator.next() wrapper (excerpt)"
pub fn next(self: *Operator) ExecuteError!?Row {
    const start = std.time.microTimestamp();
    const result = self.next_fn(self);
    const elapsed = std.time.microTimestamp() - start;
    self.stats.elapsed_us += @as(u64, @intCast(elapsed));
    const maybe_row = result catch |err| return err;
    if (maybe_row) |_| {
        self.stats.rows_out += 1;
    }
    return maybe_row;
}
```

### `pub fn buildPipeline(allocator, engine, node: *physical.Node) ExecuteError!*Operator`

Builds an operator pipeline from a physical plan node.

Notable constraints (as implemented):

- Scan currently supports only `series_ref.by_id` selectors; name-based selection returns `UnsupportedPlan`.
- Time bounds are taken from the physical scan node (`TimeBounds`) and passed into `Engine.queryRange`.
  - Current implementation uses `min`/`max` only; inclusive flags are ignored at execution time.
  - When bounds are absent, it queries `[minInt(i64), maxInt(i64)]`.

Physical-to-operator mapping:

- `scan` → `scan`
- `one_row` → `one_row`
- `filter` → `filter` (recursively builds child)
- `project` → `project` (may be elided when schema is reusable)
- `aggregate` → `aggregate` (recursively builds child)
- `sort` → `sort` (materializes child rows; then sorts)
- `limit` → `limit`
  - Special case: `limit(child=sort)` becomes a sort with a `limit_hint` (top-k-ish behavior)

## Observability

Each operator tracks:

- `name` (e.g. `"scan"`)
- `elapsed_us` (accumulated time spent in `next()`)
- `rows_out`

These stats are exposed via `ExecutionCursor.collectOperatorStats()`.

## Operator payloads (implementation details)

This section documents the concrete payload structs inside `Operator.Payload`. These types are not `pub`, but they define the runtime semantics and ownership rules.

### `scan`

Backs scan plans by materializing points from storage:

- Creation (`createScanOperator`):
  - Requires `physical.Scan.selector != null`; otherwise `UnsupportedPlan`
  - Only supports `selector.series.by_id`; `.name` returns `UnsupportedPlan`
  - Executes a single `engine.queryRange(series_id, start_ts, end_ts, &points)` during construction
  - Allocates a `buffer: []Value` sized to the output schema and reuses it per row
- Row production (`scanNext`):
  - Only supports identifier columns named `time` and `value` (case-insensitive)
  - Any non-identifier output column or unknown identifier name returns `UnsupportedPlan`
- Destruction (`scanDestroy`): frees points and buffer

```zig title="scanNext column mapping (excerpt)"
for (op.schema, 0..) |column, idx| {
    if (column.expr.* != .identifier) return error.UnsupportedPlan;
    const name = column.expr.identifier.value;
    if (namesEqual(name, "time")) {
        payload.buffer[idx] = Value{ .integer = point.ts };
    } else if (namesEqual(name, "value")) {
        payload.buffer[idx] = Value{ .float = point.value };
    } else {
        return error.UnsupportedPlan;
    }
}
```

### `one_row`

Single-row source used for constant `SELECT` without a selector:

- Payload: `{ emitted: bool }`
- Row production (`oneRowNext`):
  - first call returns a row with empty schema/values
  - second call returns `null`
- Destruction (`oneRowDestroy`): no-op

### `filter`

Streams child rows and keeps only those matching a boolean predicate:

- Payload: `{ child, predicate }`
- Row production (`filterNext`):
  - loops `child.next()` until predicate evaluates to true
  - returns the child row values without copying
- Destruction (`filterDestroy`): destroys child

### `project`

Computes a new schema by evaluating expressions per incoming row:

- `buildProjectOperator` may return the child operator directly when:
  - `physical.Project.reuse_child_schema == true`, or
  - the child schema already matches the requested schema (names + expression equality)
- Payload: `{ child, buffer }`
- Row production (`projectNext`):
  - reads one child row
  - evaluates each output column expression with `expression.evaluate`
  - writes into `buffer` and returns it
- Destruction (`projectDestroy`): destroys child, frees buffer

### `aggregate`

Grouping/aggregation implementation that materializes all groups before producing output.

Constraints:

- Output columns must be either a grouping expression (structural match), or an aggregate call `avg`, `sum`, `count` (case-insensitive).
- Other output column forms return `UnsupportedAggregate`.

Key payload fields:

- `child`, `group_exprs`, `aggregates`, `column_meta`
- `groups`, `key_buffer`, `output_buffer`
- `initialized`, `index`

Initialization and execution:

- First `next()` triggers `materializeGroups` which:
  - iterates every child row
  - evaluates group keys into `key_buffer`
  - finds/creates a `GroupState` by linear scan (`valuesEqual`)
  - updates per-group aggregate states (0 args means `count(*)`-like)
- After materialization, emits one row per group using key values and `finalizeState`.

Ownership notes:

- Group key `[]Value` arrays are owned by the aggregate operator (`Value.copySlice`), but `.string` values still borrow their underlying bytes.
- `output_buffer` is reused per emitted row.

### `sort`

Materializes all rows from its child, computes ordering keys, sorts, then streams the sorted results.

Key points:

- Child is always destroyed after materialization (`defer child.destroy()`).
- Each row is copied into an `OwnedRow`:
  - `values` is an owned copy of the `[]Value` array (shallow copy; `.string` bytes are not duplicated)
  - `keys` are computed by evaluating ordering expressions against the copied values
- Sort order:
  - `null` sorts first
  - numeric-ish (`integer`, `float`, `boolean`) are compared as floats
  - strings compare lexicographically
  - `DESC` is implemented by inverting the ordering

`LIMIT` hint optimization:

- With `limit_hint = { offset, take }`, the sort operator caps memory to `offset + take` rows while scanning and evicts the current “worst” row.
- After sorting, it drops the first `offset` rows and truncates to `take`.

Lifetime notes:

- Returned `Row.values` remain valid until sort operator destruction (owned `[]Value` arrays), but `.string` values still borrow their underlying bytes from upstream storage (often the query arena).

### `limit`

Offset + take streaming wrapper:

- Payload: `{ child, offset, remaining }`
- Row production discards `offset` rows then emits up to `remaining`.
- Destruction destroys child.

### `test_source` (test-only)

Simple row source used by inline tests: returns a pre-baked list of value slices sequentially without copying.
