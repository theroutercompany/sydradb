---
sidebar_position: 4
title: src/sydra/query/ast.zig
---

# `src/sydra/query/ast.zig`

## Purpose

Defines the sydraQL abstract syntax tree (AST) produced by the parser and consumed by later stages.

## Core types

### Statements

`pub const Statement = union(enum)`:

- `invalid: Invalid`
- `select: *const Select`
- `insert: *const Insert`
- `delete: *const Delete`
- `explain: *const Explain`

### Expressions

`pub const Expr = union(enum)`:

- `identifier`
- `literal`
- `call`
- `binary`
- `unary`

Operator enums:

- `BinaryOp` (arithmetic, comparisons, regex match, logical ops)
- `UnaryOp` (negate, logical not, positive)

### Select structure

`Select` includes:

- `projections` (with optional aliases)
- optional `selector` (`from ...`)
- optional `predicate` (`where ...`)
- `groupings`, optional `fill`, `ordering`, optional `limit`

## Utilities

### `pub fn placeholderStatement(span: Span) Statement`

Creates an `.invalid` statement for parse error recovery or placeholders.

