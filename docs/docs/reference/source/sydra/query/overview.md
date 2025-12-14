---
sidebar_position: 1
title: Query pipeline overview (src/sydra/query)
---

# Query pipeline overview (`src/sydra/query/*`)

This directory implements the sydraQL parsing, planning, and execution pipeline used by `POST /api/v1/sydraql`.

## High-level stages

1. **Lexing**: `lexer.zig`
2. **Parsing (AST)**: `parser.zig` → `ast.zig`
3. **Validation / diagnostics**: `validator.zig` (+ `errors.zig`, `type_inference.zig`, `functions.zig`)
4. **Logical planning**: `plan.zig`
5. **Optimization**: `optimizer.zig`
6. **Physical planning**: `physical.zig`
7. **Execution**: `operator.zig` + `executor.zig`
8. **Orchestration entrypoint**: `exec.zig` (ties it together and returns an `ExecutionCursor`)

## Related docs

- Language design: `Concepts/sydraQL Design`
- Supplemental implementation notes: `Architecture/sydraDB Architecture & Engineering Design (Supplementary, Oct 18 2025)`

