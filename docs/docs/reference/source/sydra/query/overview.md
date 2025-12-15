---
sidebar_position: 1
title: Query pipeline overview (src/sydra/query)
---

# Query pipeline overview (`src/sydra/query/*`)

This directory implements the sydraQL parsing, planning, and execution pipeline used by `POST /api/v1/sydraql`.

## High-level stages

1. **Lexing**: [`lexer.zig`](./lexer.md)
2. **Parsing (AST)**: [`parser.zig`](./parser.md) → [`ast.zig`](./ast.md)
3. **Validation / diagnostics**: [`validator.zig`](./validator.md) (+ [`errors.zig`](./errors.md), [`type_inference.zig`](./type-inference.md), [`functions.zig`](./functions.md))
4. **Logical planning**: [`plan.zig`](./plan.md)
5. **Optimization**: [`optimizer.zig`](./optimizer.md)
6. **Physical planning**: [`physical.zig`](./physical.md)
7. **Execution**: [`operator.zig`](./operator.md) + [`executor.zig`](./executor.md)
8. **Orchestration entrypoint**: [`exec.zig`](./exec.md) (ties it together and returns an `ExecutionCursor`)

## Related docs

- User-facing HTTP surface: [Reference: HTTP API](../../../http-api.md) (`POST /api/v1/sydraql`)
- Language design: [Concepts: sydraQL Design](../../../../concepts/sydraql-design.md)
- Supplemental implementation notes: [Architecture & Engineering Design (Supplementary, Oct 18 2025)](../../../../architecture/supplementary-design-2025-10-18.md)

## Code excerpt (pipeline entrypoint)

```zig title="src/sydra/query/exec.zig (execute excerpt)"
pub const ExecuteError = parser.ParseError || validator.AnalyzeError || plan_builder.BuildError || optimizer.OptimizeError || physical.BuildError || executor.ExecuteError || std.mem.Allocator.Error || error{ValidationFailed};

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

    var parser_inst = parser.Parser.init(arena_ptr.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = validator.Analyzer.init(arena_ptr.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    if (!analysis.is_valid) return error.ValidationFailed;

    var builder = plan_builder.Builder.init(arena_ptr.allocator());
    const logical_plan = try builder.build(&statement);
    const optimized_plan = try optimizer.optimize(arena_ptr.allocator(), logical_plan);
    const physical_plan = try physical.build(arena_ptr.allocator(), optimized_plan);

    var exec = executor.Executor.init(allocator, engine, physical_plan);
    defer exec.deinit();
    var cursor = try exec.run();
    cursor.arena = arena_ptr;
    arena_cleanup = false;
    return cursor;
}
```
