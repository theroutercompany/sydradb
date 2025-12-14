---
sidebar_position: 18
title: src/sydra/query/translator.zig
---

# `src/sydra/query/translator.zig`

## Purpose

Provides a string-based SQL → sydraQL translation layer for the PostgreSQL compatibility surface.

This is not a full SQL parser; it uses case-insensitive substring searches and simple parenthesis matching.

The main consumer is the pgwire server (`src/sydra/compat/wire/server.zig`), which translates SQL from Postgres clients into sydraQL before running the normal sydraQL pipeline.

## Definition index (public)

### `pub const Result = union(enum)`

- `success: Success`
- `failure: Failure`

### `pub const Success`

- `sydraql: []const u8` – allocator-owned string; callers must free it.

### `pub const Failure`

- `sqlstate: []const u8` – borrowed SQLSTATE string (from `compat.sqlstate`)
- `message: []const u8` – borrowed default message for that SQLSTATE (from `compat.sqlstate`)

### `pub fn translate(alloc: std.mem.Allocator, sql: []const u8) !Result`

Memory / ownership:

- On `.success`, `result.success.sydraql` is allocated with `alloc` and must be freed by the caller.
- On `.failure`, no allocation is returned (the SQLSTATE/message are borrowed constants).

Metrics/logging:

- The translator measures `duration_ns` with `std.time.nanoTimestamp()`.
- It always calls `compat.clog.global().record(...)`:
  - success: `translated = sydraql`, `fell_back = false`
  - fallback: `translated = ""`, `fell_back = true`
- `used_cache` is always `false` (there is no cache layer in this module today).

## Supported patterns (as implemented)

The translator operates on `trimmed = trim(sql, " \\t\\r\\n")` and is intentionally conservative: if it can’t confidently translate a shape, it returns `feature_not_supported`.

### `SELECT`

Special case:

- `SELECT 1` (case-insensitive exact match) → `select const 1`

General shape:

```
SELECT <cols> FROM <table> [WHERE <cond>]
```

Rules:

- Requires the substring `" FROM "` (case-insensitive search). Joins, subqueries, etc. are not recognized.
- Column list is split on commas and trimmed; empty column entries are skipped.
- Requires at least one non-empty column.
- Trailing semicolons are trimmed from the tail (`trim(..., " \\t\\r\\n;")`).

Output shape:

```
from <table> [where <cond>] select <col1>,<col2>,...
```

Note: commas are emitted without a following space.

### `INSERT`

Shape:

```
INSERT INTO <table> [(<columns>)] VALUES (<values>) [RETURNING <exprs>]
```

Rules:

- `<table>` is scanned until whitespace or `(`.
- Optional `(<columns>)` is captured using a raw parenthesis match (see `findMatchingParen`).
- Requires `VALUES` keyword and a parenthesized values list.
- Optional `RETURNING` is accepted only when it appears immediately after the values clause and is the only trailing keyword.
  - `RETURNING` with an empty clause is treated as malformed and falls back.

Output shape:

```
insert into <table> [(<columns>)] values (<values>) [returning <exprs>]
```

### `UPDATE`

Shape:

```
UPDATE <table> SET <set_clause> [WHERE <cond>] [RETURNING <exprs>]
```

Rules:

- Requires `" SET "` delimiter (case-insensitive search).
- Optional `RETURNING` is extracted using a case-insensitive search for the *last* `"RETURNING"` token and basic “word boundary” checks (whitespace before/after).
- Optional `WHERE` is split on `" WHERE "` (case-insensitive).

Output shape:

```
update <table> set <set_clause> [where <cond>] [returning <exprs>]
```

### `DELETE`

Shape:

```
DELETE FROM <table> [WHERE <cond>] [RETURNING <exprs>]
```

Rules:

- Optional `RETURNING` is extracted like `UPDATE`.
- Optional `WHERE` is split on `" WHERE "` (case-insensitive).

Output shape:

```
delete from <table> [where <cond>] [returning <exprs>]
```

## Fallback behavior

If no rule matches, `translate` returns:

- `Result.failure` with payload from `compat.sqlstate.buildPayload(.feature_not_supported, null, null, null)`
- records the fallback via `compat.clog.global().record(trimmed, "", false, true, duration_ns)`

## Important internal helpers (non-public)

These helpers are not `pub`, but they define what “supported” means:

- `startsWithCaseInsensitive(text, prefix) bool` – ASCII-only case-insensitive prefix match
- `findCaseInsensitive(haystack, needle) ?usize` – first occurrence, ASCII-only
- `findLastCaseInsensitive(haystack, needle) ?usize` – last occurrence, ASCII-only
- `findMatchingParen(text, open_index) ?usize` – balances `(` / `)` with a depth counter
  - does not account for quotes/strings, so parentheses in string literals can confuse it

## Tests

The inline test `test "translator fixtures"` loads JSONL fixtures from `tests/translator/cases.jsonl` and asserts:

- expected translation strings for `.success` cases
- expected SQLSTATE codes for `.failure` cases
- global compat stats counters match fixture expectations
