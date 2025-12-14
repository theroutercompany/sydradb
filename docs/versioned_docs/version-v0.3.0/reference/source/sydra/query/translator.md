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

## Code excerpt

```zig title="src/sydra/query/translator.zig (SELECT 1 + SELECT ... FROM ... translation excerpt)"
pub fn translate(alloc: std.mem.Allocator, sql: []const u8) !Result {
    const trimmed = std.mem.trim(u8, sql, " \t\r\n");
    const start = std.time.nanoTimestamp();
    if (std.ascii.eqlIgnoreCase(trimmed, "SELECT 1")) {
        const out = try alloc.dupe(u8, "select const 1");
        const duration = std.time.nanoTimestamp() - start;
        const duration_ns: u64 = @intCast(@max(duration, @as(i128, 0)));
        compat.clog.global().record(trimmed, out, false, false, duration_ns);
        return Result{ .success = .{ .sydraql = out } };
    }

    if (startsWithCaseInsensitive(trimmed, "SELECT ")) {
        if (findCaseInsensitive(trimmed, " FROM ")) |from_idx| {
            const cols_raw = std.mem.trim(u8, trimmed["SELECT ".len..from_idx], " \t\r\n");
            const remainder = std.mem.trim(u8, trimmed[from_idx + " FROM ".len ..], " \t\r\n;");
            if (cols_raw.len != 0 and remainder.len != 0) {
                var table_part = remainder;
                var where_part: ?[]const u8 = null;
                if (findCaseInsensitive(remainder, " WHERE ")) |where_idx| {
                    table_part = std.mem.trim(u8, remainder[0..where_idx], " \t\r\n");
                    const cond_slice = std.mem.trim(u8, remainder[where_idx + " WHERE ".len ..], " \t\r\n;");
                    if (cond_slice.len != 0) where_part = cond_slice;
                }
                if (table_part.len != 0) {
                    var builder = std.array_list.Managed(u8).init(alloc);
                    defer builder.deinit();
                    try builder.appendSlice("from ");
                    try builder.appendSlice(table_part);
                    if (where_part) |cond| {
                        try builder.appendSlice(" where ");
                        try builder.appendSlice(cond);
                    }
                    try builder.appendSlice(" select ");
                    var col_iter = std.mem.splitScalar(u8, cols_raw, ',');
                    var first = true;
                    while (col_iter.next()) |raw| {
                        const trimmed_col = std.mem.trim(u8, raw, " \t\r\n");
                        if (trimmed_col.len == 0) continue;
                        if (!first) try builder.appendSlice(",");
                        first = false;
                        try builder.appendSlice(trimmed_col);
                    }
                    if (!first) {
                        const sydra_str = try builder.toOwnedSlice();
                        const duration = std.time.nanoTimestamp() - start;
                        const duration_ns: u64 = @intCast(@max(duration, @as(i128, 0)));
                        compat.clog.global().record(trimmed, sydra_str, false, false, duration_ns);
                        return Result{ .success = .{ .sydraql = sydra_str } };
                    }
                }
            }
        }
    }

    // ... INSERT / UPDATE / DELETE cases

    const payload = compat.sqlstate.buildPayload(.feature_not_supported, null, null, null);
    const duration = std.time.nanoTimestamp() - start;
    const duration_ns: u64 = @intCast(@max(duration, @as(i128, 0)));
    compat.clog.global().record(trimmed, "", false, true, duration_ns);
    return Result{ .failure = .{ .sqlstate = payload.sqlstate, .message = payload.message } };
}
```
