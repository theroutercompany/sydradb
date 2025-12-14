---
sidebar_position: 4
title: src/sydra/query/ast.zig
---

# `src/sydra/query/ast.zig`

## Purpose

Defines the sydraQL abstract syntax tree (AST) produced by the parser and consumed by later stages.

Every syntactic node carries a `Span` (a half-open byte range into the original query text) so later stages can attach diagnostics.

## Definition index (public)

### `pub const Statement = union(enum) { ... }`

Top-level statement variants:

- `invalid: Invalid`
- `select: *const Select`
- `insert: *const Insert`
- `delete: *const Delete`
- `explain: *const Explain`

Notes:

- The parser allocates statement payload structs (`Select`, `Insert`, …) and stores pointers in the `Statement` union.
- In the current implementation, these allocations typically live in an arena owned by the execution cursor (see `src/sydra/query/exec.zig`).

### `pub const Invalid = struct { ... }`

- `span: Span`

### `pub const Select = struct { ... }`

Represents a `SELECT` statement:

- `projections: []const Projection`
- `selector: ?Selector` — present when `FROM` was provided
- `predicate: ?*const Expr` — present when `WHERE` was provided
- `groupings: []const GroupExpr`
- `fill: ?FillClause`
- `ordering: []const OrderExpr`
- `limit: ?LimitClause`
- `span: Span`

### `pub const Insert = struct { ... }`

Represents an `INSERT` statement:

- `series: Identifier`
- `columns: []const Identifier` — may be empty if no column list is provided
- `values: []const *const Expr` — expression list inside `VALUES (...)`
- `span: Span`

### `pub const Delete = struct { ... }`

Represents a `DELETE` statement:

- `selector: Selector`
- `predicate: ?*const Expr`
- `span: Span`

### `pub const Explain = struct { ... }`

Represents `EXPLAIN <statement>`:

- `target: *const Statement`
- `span: Span`

### `pub const Selector = struct { ... }`

Selects a series to read from:

- `series: SeriesRef`
- `tag_filter: ?*const Expr` — currently always `null` in the parser implementation
- `span: Span`

### `pub const SeriesRef = union(enum) { ... }`

- `name: Identifier` — series name path
- `by_id: ById` — special selector `by_id(<u64>)`

### `pub const ById = struct { ... }`

- `value: u64`
- `span: Span`

### `pub const Identifier = struct { ... }`

- `value: []const u8` — slice of the original source (may include dots)
- `quoted: bool` — true when any segment came from a quoted identifier
- `span: Span`

### `pub const LimitClause = struct { ... }`

- `limit: usize`
- `offset: ?usize`
- `span: Span`

### `pub const LiteralValue = union(enum) { ... }`

- `integer: i64`
- `float: f64`
- `string: []const u8`
- `boolean: bool`
- `null`

### `pub const Literal = struct { ... }`

- `value: LiteralValue`
- `span: Span`

### `pub const BinaryOp = enum { ... }`

Binary operators:

```text
add, subtract, multiply, divide, modulo,
equal, not_equal,
less, less_equal, greater, greater_equal,
regex_match, regex_not_match,
logical_and, logical_or
```

### `pub const UnaryOp = enum { ... }`

```text
negate, logical_not, positive
```

### `pub const Expr = union(enum) { ... }`

Expression variants:

- `identifier: Identifier`
- `literal: Literal`
- `call: Call`
- `binary: Binary`
- `unary: Unary`

### `pub const Projection = struct { ... }`

A projection item in a SELECT list:

- `expr: *const Expr`
- `alias: ?Identifier`
- `span: Span`

### `pub const GroupExpr = struct { ... }`

- `expr: *const Expr`
- `span: Span`

### `pub const FillStrategy = union(enum) { ... }`

- `previous`
- `linear`
- `null_value`
- `constant: *const Expr`

### `pub const FillClause = struct { ... }`

- `strategy: FillStrategy`
- `span: Span`

### `pub const OrderDirection = enum { ... }`

- `asc`
- `desc`

### `pub const OrderExpr = struct { ... }`

- `expr: *const Expr`
- `direction: OrderDirection`
- `span: Span`

### `pub const Call = struct { ... }`

- `callee: Identifier`
- `args: []const *const Expr`
- `span: Span`

### `pub const Binary = struct { ... }`

- `op: BinaryOp`
- `left: *const Expr`
- `right: *const Expr`
- `span: Span`

### `pub const Unary = struct { ... }`

- `op: UnaryOp`
- `operand: *const Expr`
- `span: Span`

### `pub fn placeholderStatement(span: Span) Statement`

Creates a synthetic `.invalid` statement (used for placeholders or error recovery).

## Notes on memory ownership

The parser allocates `Expr` and statement payload structs using its `allocator`.

In the HTTP surface, `exec.execute` constructs an arena allocator for parsing/planning artifacts and attaches it to the returned `ExecutionCursor`, so:

- AST pointers remain valid while the cursor is in use.
- `cursor.deinit()` releases the arena allocations.

## Code excerpt

```zig title="src/sydra/query/ast.zig (statement + expression nodes, excerpt)"
pub const Statement = union(enum) {
    invalid: Invalid,
    select: *const Select,
    insert: *const Insert,
    delete: *const Delete,
    explain: *const Explain,
};

pub const Select = struct {
    projections: []const Projection,
    selector: ?Selector,
    predicate: ?*const Expr,
    groupings: []const GroupExpr,
    fill: ?FillClause,
    ordering: []const OrderExpr,
    limit: ?LimitClause,
    span: common.Span,
};

pub const Expr = union(enum) {
    identifier: Identifier,
    literal: Literal,
    call: Call,
    binary: Binary,
    unary: Unary,
};
```
