---
sidebar_position: 17
title: src/sydra/query/exec.zig
---

# `src/sydra/query/exec.zig`

## Purpose

End-to-end sydraQL execution entrypoint used by the HTTP `/api/v1/sydraql` handler.

This module orchestrates:

- parse → validate → logical plan → optimize → physical plan → execute

## See also

- [Query pipeline overview](./overview.md)
- [HTTP server](../http.md) (`POST /api/v1/sydraql`)
- [pgwire server](../compat/wire-server.md) (SQL → sydraQL → execute)
- Pipeline stages: [lexer](./lexer.md), [parser](./parser.md), [validator](./validator.md), [plan](./plan.md), [optimizer](./optimizer.md), [physical](./physical.md), [executor](./executor.md)

## Definition index (public)

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

```zig title="execute orchestrator (excerpt)"
pub fn execute(allocator: std.mem.Allocator, engine: *engine_mod.Engine, query: []const u8) ExecuteError!executor.ExecutionCursor {
    var arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    var arena_cleanup = true;
    errdefer {
        if (arena_cleanup) {
            arena_ptr.deinit();
            allocator.destroy(arena_ptr);
        }
    }

    const t_start = std.time.microTimestamp();
    var parser_inst = parser.Parser.init(arena_ptr.allocator(), query);
    var statement = try parser_inst.parse();
    const t_parse = std.time.microTimestamp();

    var analyzer = validator.Analyzer.init(arena_ptr.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    if (!analysis.is_valid) return error.ValidationFailed;
    const t_validate = std.time.microTimestamp();

    var builder = plan_builder.Builder.init(arena_ptr.allocator());
    const logical_plan = try builder.build(&statement);
    const optimized_plan = try optimizer.optimize(arena_ptr.allocator(), logical_plan);
    const t_optimize = std.time.microTimestamp();
    const physical_plan = try physical.build(arena_ptr.allocator(), optimized_plan);
    const t_physical = std.time.microTimestamp();

    var exec = executor.Executor.init(allocator, engine, physical_plan);
    defer exec.deinit();
    const pipeline_start = std.time.microTimestamp();
    var cursor = try exec.run();
    const pipeline_end = std.time.microTimestamp();

    const trace_id = try randomTraceId(arena_ptr.allocator());

    cursor.stats = .{
        .parse_us = @as(u64, @intCast(t_parse - t_start)),
        .validate_us = @as(u64, @intCast(t_validate - t_parse)),
        .optimize_us = @as(u64, @intCast(t_optimize - t_validate)),
        .physical_us = @as(u64, @intCast(t_physical - t_optimize)),
        .pipeline_us = @as(u64, @intCast(pipeline_end - pipeline_start)),
        .trace_id = trace_id,
    };
    cursor.arena = arena_ptr;
    arena_cleanup = false;
    return cursor;
}
```

## Implementation notes (non-public)

### Arena lifetime

`execute` allocates a `std.heap.ArenaAllocator` on the heap (`allocator.create`) and:

- uses it for parsing, validation, planning, optimization, and physical lowering
- stores the arena pointer on the returned cursor (`cursor.arena`)

This keeps the AST/plan pointers valid for as long as the cursor is alive.

### Stage timings

The function records timestamps via `std.time.microTimestamp()` and stores deltas into `cursor.stats`:

- `parse_us`
- `validate_us`
- `optimize_us`
- `physical_us`
- `pipeline_us`

### Trace IDs

The helper `randomTraceId`:

- allocates a 16-byte buffer from the arena
- fills it with crypto-random bytes
- maps each byte to a character in `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`
