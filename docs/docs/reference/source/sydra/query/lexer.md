---
sidebar_position: 5
title: src/sydra/query/lexer.zig
---

# `src/sydra/query/lexer.zig`

## Purpose

Tokenizes sydraQL source text into a stream of tokens for the parser.

## Public API

### `pub const TokenKind`

Includes:

- identifiers and literals (`identifier`, `number`, `string`, …)
- delimiters (`comma`, `l_paren`, `r_paren`, …)
- operators (`plus`, `minus`, `equal`, `greater_equal`, `regex_match`, `and_and`, …)
- `keyword`, `eof`, and `unknown`

### `pub const Keyword`

Recognized sydraQL keywords, including:

- `select`, `from`, `where`, `group`, `fill`, `order`, `limit`, `offset`
- `insert`, `delete`, `explain`
- `previous`, `linear`, `asc`, `desc`, boolean and null literals

### `pub const Token`

- `kind: TokenKind`
- `lexeme: []const u8` (slice of the original source)
- `span: Span` (byte offsets)
- `keyword: ?Keyword` (only set when `kind == .keyword`)

### `pub const Lexer`

Methods:

- `Lexer.init(allocator, source)`
- `next()` → `Token` (skipping whitespace and comments)
- `peek()` – lookahead without consuming
- `reset()` – rewind to start

Comments supported:

- `-- line comments`
- `/* block comments */` (unterminated block comment falls through to EOF)

