---
sidebar_position: 16
title: src/sydra/query/executor.zig
---

# `src/sydra/query/executor.zig`

## Purpose

Wraps the operator pipeline with a cursor API suitable for HTTP/pgwire surfaces.

## Definition index (public)

### `pub const Value`

Alias:

- `value.Value` from `src/sydra/query/value.zig`

### `pub const ExecuteError`

Alias:

- `operator.ExecuteError`

### `pub const OperatorStats`

Alias:

- `operator.Operator.StatsSnapshot`

### `pub const ExecutionStats`

Timing and counters set by `exec.execute`, including:

- parse/validate/optimize/physical/pipeline timings (microseconds)
- `trace_id`
- `rows_emitted`, `rows_scanned`

Full field list:

- `parse_us`, `validate_us`, `optimize_us`, `physical_us`, `pipeline_us`
- `trace_id: []const u8`
- `rows_emitted: u64`
- `rows_scanned: u64`

### `pub const ExecutionCursor`

Fields:

- `allocator: std.mem.Allocator` – allocator used for operator + optional arena cleanup
- `operator: *operator.Operator` – root of the operator pipeline
- `columns: []const plan.ColumnInfo` – output schema (from `physical.nodeOutput(root)`)
- `arena: ?*std.heap.ArenaAllocator` – optionally owned arena for AST/plan lifetime
- `stats: ExecutionStats` – timings/counters; filled by `exec.execute`

Methods:

- `next()` – returns the next row from the operator pipeline
- `deinit()` – destroys the operator and (if present) frees the arena
- `collectOperatorStats(allocator)` – returns a snapshot list from the pipeline

Ownership notes:

- `next()` returns `operator.Row` values that are owned by the underlying operator; treat them as valid until the next `next()` call on the same cursor/operator.
- `collectOperatorStats` returns an owned slice; callers must free it with the allocator they passed in.
- If `arena` is non-null, it is owned by the cursor and is freed by `deinit()` (this is how `exec.execute` keeps AST/plan pointers alive for the cursor lifetime).

```zig title="ExecutionCursor (excerpt)"
pub const ExecutionCursor = struct {
    allocator: std.mem.Allocator,
    operator: *operator.Operator,
    columns: []const plan.ColumnInfo,
    arena: ?*std.heap.ArenaAllocator = null,
    stats: ExecutionStats = .{},

    pub fn next(self: *ExecutionCursor) ExecuteError!?operator.Row {
        return self.operator.next();
    }

    pub fn deinit(self: *ExecutionCursor) void {
        self.operator.destroy();
        if (self.arena) |arena_ptr| {
            arena_ptr.deinit();
            self.allocator.destroy(arena_ptr);
            self.arena = null;
        }
    }

    pub fn collectOperatorStats(self: *ExecutionCursor, allocator: std.mem.Allocator) ![]OperatorStats {
        var list = ManagedArrayList(OperatorStats).init(allocator);
        errdefer list.deinit();
        try self.operator.collectStats(&list);
        return try list.toOwnedSlice();
    }
};
```

### `pub const Executor`

Creates an `ExecutionCursor` from a physical plan:

- `Executor.init(allocator, engine, physical_plan)`
- `run()` → `ExecutionCursor`
- `deinit()` – no-op (present for symmetry)

Fields:

- `allocator: std.mem.Allocator`
- `engine: *Engine`
- `plan: physical.PhysicalPlan`

Behavior notes:

- `run()` builds the operator pipeline (`operator.buildPipeline`) and sets `columns` from `physical.nodeOutput(plan.root)`.
- `run()` returns a cursor with `arena = null` and zeroed stats; the orchestration entrypoint (`exec.execute`) wraps this and fills the timing fields + attaches an arena.
