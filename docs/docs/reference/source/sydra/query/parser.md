---
sidebar_position: 6
title: src/sydra/query/parser.zig
---

# `src/sydra/query/parser.zig`

## Purpose

Parses sydraQL text into an AST (`ast.zig`) using the lexer (`lexer.zig`).

## Public API

### `pub const ParseError`

Union of lexer errors, allocator errors, and parser-specific errors such as:

- `UnexpectedToken`
- `UnexpectedStatement`
- `UnexpectedExpression`
- `UnterminatedParenthesis`
- `InvalidNumber`

### `pub const Parser`

Key methods:

- `Parser.init(allocator, source)`
- `parse()` → `ast.Statement`

`parse()`:

- Parses exactly one statement.
- Optionally consumes a trailing `;`.
- Requires EOF afterward (extra tokens return `UnexpectedToken`).

## Supported statements (as observed in code)

- `SELECT` (with optional `FROM`, `WHERE`, `GROUP BY`, `FILL`, `ORDER BY`, `LIMIT [OFFSET]`)
- `INSERT INTO ... VALUES (...)`
- `DELETE FROM ... [WHERE ...]`
- `EXPLAIN <statement>`

Projection aliases:

- `expr AS alias`
- or implicit alias when a token is an alias candidate

