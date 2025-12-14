---
sidebar_position: 7
title: src/sydra/query/validator.zig
---

# `src/sydra/query/validator.zig`

## Purpose

Performs semantic checks over the AST and produces diagnostics.

This stage is used by `exec.execute` before planning.

## Public API

### `pub const AnalyzeResult`

- `diagnostics: DiagnosticList`
- `is_valid: bool`

### `pub const Analyzer`

Methods:

- `Analyzer.init(allocator)`
- `analyze(statement)` → `AnalyzeResult`
- `deinit(result)` – frees diagnostic messages and list storage

## Key validations (as implemented)

- `SELECT` requires a time predicate:
  - If `WHERE` is missing, emits `time_range_required`.
  - If `WHERE` exists but does not reference `time`, emits `time_range_required`.
- `DELETE` requires a time predicate with the same rule.
- Function calls are checked against `functions.lookup(...)`:
  - Unknown function names emit `invalid_syntax` diagnostics.

Time detection:

- An identifier is treated as “time” when its trailing segment (after `.`) equals `time` case-insensitively.

