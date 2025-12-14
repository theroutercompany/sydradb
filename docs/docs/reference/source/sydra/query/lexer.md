---
sidebar_position: 5
title: src/sydra/query/lexer.zig
---

# `src/sydra/query/lexer.zig`

## Purpose

Tokenizes sydraQL source text into a stream of tokens for the parser.

## Definition index (public)

### `pub const TokenKind = enum { ... }`

Full set of token kinds (as implemented):

- Identifiers and literals:
  - `identifier`
  - `quoted_identifier` (double-quoted identifiers)
  - `number`
  - `string` (single-quoted strings)
  - `keyword`
- Punctuation:
  - `comma`, `period`, `semicolon`, `colon`
  - `l_paren`, `r_paren`
  - `l_bracket`, `r_bracket`
  - `l_brace`, `r_brace`
- Arithmetic:
  - `plus`, `minus`, `star`, `slash`, `percent`, `caret`
- Comparisons and matching:
  - `equal`, `bang_equal`
  - `less`, `less_equal`, `greater`, `greater_equal`
  - `regex_match` (`=~`), `regex_not_match` (`!~`)
- Logical tokens:
  - `and_and` (`&&`), `or_or` (`||`)
- Misc:
  - `arrow` (`->`)
  - `eof`
  - `unknown`

### `pub const Keyword = enum { ... }`

Recognized sydraQL keywords, including:

```text
select, from, where, group, by, fill, order, limit, offset,
insert, into, values, delete, explain, as,
tag, time, now, between,
logical_and, logical_or, logical_not,
previous, linear,
asc, desc,
boolean_true, boolean_false,
null_literal
```

Notes:

- Keyword recognition is case-insensitive.
- The lexer maps `and/or/not` to `logical_and/logical_or/logical_not` (as keywords).
- Boolean and null literals are recognized as keywords: `true`, `false`, `null`.

### `pub const Token = struct { ... }`

- `kind: TokenKind`
- `lexeme: []const u8` — slice of the original source
- `span: Span` — byte offsets into the original source
- `keyword: ?Keyword` — set only when `kind == .keyword`

### `pub const LexError = error { ... }`

Returned for malformed literals:

- `InvalidLiteral`
- `UnterminatedString`

### `pub const Lexer = struct { ... }`

Key fields:

- `allocator: std.mem.Allocator`
- `source: []const u8`
- `index: usize`

Public methods:

- `init(allocator, source) Lexer` — constructs a lexer at `index = 0`
- `next() LexError!Token` — returns the next token (skipping whitespace and comments)
- `peek() LexError!Token` — lookahead without consuming (`next` + rewind)
- `reset() void` — rewinds to the start (`index = 0`)

## Lexing rules (as implemented)

### Whitespace and comments

Whitespace: spaces, tabs, `\n`, and `\r` are skipped.

Comments:

- `-- line comments`
- `/* block comments */` (unterminated block comment falls through to EOF)

### Identifiers and keywords

- Identifiers match:
  - start: `[A-Za-z_]`
  - body: `[A-Za-z0-9_]`
- Keyword lookup is case-insensitive and uses a static `keyword_table`.

### Strings vs quoted identifiers

The lexer uses the delimiter to decide the token kind:

- `"double quotes"` → `quoted_identifier`
- `'single quotes'` → `string`

Escaping:

- The delimiter is escaped by doubling it:
  - `'can''t'` includes a literal `'`
  - `"a""b"` includes a literal `"`

### Numbers

Numbers are scanned with support for:

- integer form (`42`)
- decimal form (`3.14`)
- exponent suffix (`1e6`, `1.2E-3`)

Parsing into `i64` vs `f64` happens in the parser (not in the lexer).

### Operators and punctuation

Notable multi-character tokens:

- `->` → `arrow`
- `=~` → `regex_match`
- `!~` → `regex_not_match`
- `!=` → `bang_equal`
- `<=`/`>=` → `less_equal`/`greater_equal`
- `&&`/`||` → `and_and`/`or_or`

### EOF and unknown tokens

- When `index >= source.len`, `next()` returns an `eof` token with an empty lexeme and a zero-width span at the end.
- Any unrecognized character produces an `unknown` token for that single byte.

## Internal helpers (non-public)

These are worth knowing when debugging tokenization:

- `skipWhitespaceAndComments`, `skipLineComment`, `skipBlockComment`
- `scanIdentifier`, `scanString`, `scanNumber`, `scanDigits`
- `keywordFromSlice` (case-insensitive, backed by `keyword_table`)
- `eofToken`, `isIdentifierStart`, `isIdentifierBody`, `isDigit`

## Tests

Inline tests cover:

- emitting EOF for empty input
- keyword recognition (`SELECT` → `.keyword/.select`)
- scanning numbers and strings
- skipping `--` and `/* */` comments
- `peek()` not consuming tokens
- unterminated strings returning `LexError.UnterminatedString`
