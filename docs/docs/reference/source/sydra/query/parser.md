---
sidebar_position: 6
title: src/sydra/query/parser.zig
---

# `src/sydra/query/parser.zig`

## Purpose

Parses sydraQL text into an AST ([`ast.zig`](./ast.md)) using the lexer ([`lexer.zig`](./lexer.md)).

## See also

- [Query pipeline overview](./overview.md)
- [Lexer](./lexer.md)
- [AST types](./ast.md)
- [Validator](./validator.md)

## Definition index (public)

### `pub const ParseError`

Error set:

- `lexer.LexError`
- `std.mem.Allocator.Error`
- Parser-specific errors:
  - `UnexpectedToken`
  - `UnexpectedStatement`
  - `UnexpectedExpression`
  - `UnterminatedParenthesis`
  - `InvalidNumber`

Notes:

- `UnterminatedParenthesis` exists in the error set but is currently not emitted by the implementation (parenthesis mismatches surface as `UnexpectedToken`/`UnexpectedExpression` depending on context).

### `pub const Parser`

Key fields:

- `allocator: std.mem.Allocator`
- `lexer: lexer.Lexer`
- `source: []const u8` — retained so identifier paths can return source slices
- Token cache:
  - `current: lexer.Token`, `has_current: bool` — one-token lookahead cache
  - `last: lexer.Token`, `has_last: bool` — last-consumed token (used to compute spans)

Public methods:

- `Parser.init(allocator, source)`
- `parse()` → `ast.Statement`

`parse()` behavior:

- Parses exactly one statement.
- Optionally consumes a trailing `;`.
- Requires EOF afterward (extra tokens return `UnexpectedToken`).

## Grammar surface (as implemented)

### Statements

The parser recognizes one top-level statement:

- `SELECT ...`
- `INSERT INTO ... VALUES (...)`
- `DELETE FROM ... [WHERE ...]`
- `EXPLAIN <statement>`

`EXPLAIN` wraps another full statement node (it is not limited to SELECT).

### SELECT shape

- `SELECT` (with optional `FROM`, `WHERE`, `GROUP BY`, `FILL`, `ORDER BY`, `LIMIT [OFFSET]`)

The full parse order for SELECT clauses:

1. projection list (required)
2. `FROM <selector>` (optional)
3. `WHERE <expr>` (optional)
4. `GROUP BY <expr[, ...]>` (optional)
5. `FILL(<strategy>)` (optional)
6. `ORDER BY <expr [asc|desc][, ...]>` (optional)
7. `LIMIT <n> [OFFSET <m>]` (optional)

### Projection aliases

- `expr AS alias`
- or implicit alias when a token is an alias candidate

Alias parsing rules:

- `parseAliasIdentifier` accepts:
  - `quoted_identifier` (from `"..."`) → `Identifier{ quoted = true }`
  - `identifier` → `Identifier{ quoted = false }`
  - keywords `time` and `tag` (so `select time as time` and `select tag.host as tag` can work)
- Implicit aliasing triggers when the next token is `identifier` or `quoted_identifier`.

### Identifiers and paths

`parseIdentifierPath` produces a single `ast.Identifier` covering a dotted path, for example:

- `metrics`
- `tag.host`
- `"weird.schema"."table"`

Behavior:

- Consumes `(<identifier>|<quoted_identifier>) ('.' (<identifier>|<quoted_identifier>))*`
- `Identifier.value` is a slice of the original source spanning the full path.
- `Identifier.quoted` is true if *any* segment is quoted.

### Selector special form: `by_id(...)`

In `FROM`, the selector `by_id(<number>)` is parsed as a series reference by id:

- `SeriesRef.by_id = { value: u64 }`

Everything else is parsed as `SeriesRef.name`.

### Expressions (precedence)

Expression parsing is a classic recursive-descent precedence ladder:

1. logical OR: `||` or keyword `or`
2. logical AND: `&&` or keyword `and`
3. equality/matching: `=`, `!=`, `=~`, `!~`
4. comparisons: `<`, `<=`, `>`, `>=`
5. term: `+`, `-`
6. factor: `*`, `/`, `%`
7. unary: prefix `-` and keyword `not`
8. calls: `identifier(...)`
9. primary: literals, identifiers, parenthesized expressions

```zig title="Precedence ladder entrypoints (excerpt)"
fn parseExpression(self: *Parser) ParseError!*const ast.Expr {
    return self.parseLogicalOr();
}

fn parseLogicalOr(self: *Parser) ParseError!*const ast.Expr {
    var expr = try self.parseLogicalAnd();
    while (true) {
        if (try self.matchLogicalOr()) |_| {
            const right = try self.parseLogicalAnd();
            expr = try self.makeBinary(ast.BinaryOp.logical_or, expr, right);
            continue;
        }
        break;
    }
    return expr;
}

fn parseLogicalAnd(self: *Parser) ParseError!*const ast.Expr {
    var expr = try self.parseEquality();
    while (true) {
        if (try self.matchLogicalAnd()) |_| {
            const right = try self.parseEquality();
            expr = try self.makeBinary(ast.BinaryOp.logical_and, expr, right);
            continue;
        }
        break;
    }
    return expr;
}
```

### Literals

- Numbers are parsed into `i64` or `f64` based on whether the token contains `.` or `e`/`E`.
- Strings are single-quoted and decoded by un-escaping doubled quotes:
  - `'can''t'` → `can't`
- Keywords `true`, `false`, `null` map to literal nodes.

### Fill clause

`FILL(<strategy>)` supports:

- `previous`
- `linear`
- `null`
- a constant expression: `fill(0)` / `fill(1.23)` / `fill('x')`

## Notable internal helpers (non-public)

These helpers define most of the parser’s behavior:

- `parseStatement`, `parseSelect`, `parseInsert`, `parseDelete`
- `parseProjectionList`, `parseGroupings`, `parseOrderings`
- `parseFillClause`, `parseLimitClause`, `parseSelector`
- `parseIdentifierPath` and `isIdentifierToken`
- Expression ladder: `parseLogicalOr` → … → `parsePrimary`
- Node constructors: `makeBinary`, `makeUnary`, `finishCall`, `make*Literal`
- Token stream utilities: `peek`, `advance`, `matchKind`, `matchKeyword`, `expectKind`, `expectKeyword`

## Tests

Inline tests cover:

- parsing a basic SELECT with FROM/WHERE/LIMIT
- projection aliases (`AS`)
- INSERT with VALUES
- DELETE with WHERE
