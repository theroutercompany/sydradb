const std = @import("std");
const common = @import("common.zig");

pub const Statement = union(enum) {
    invalid: Invalid,
    select: *const Select,
    insert: *const Insert,
    delete: *const Delete,
    explain: *const Explain,
};

pub const Invalid = struct {
    span: common.Span,
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

pub const Insert = struct {
    series: Identifier,
    columns: []const Identifier,
    values: []const *const Expr,
    span: common.Span,
};

pub const Delete = struct {
    selector: Selector,
    predicate: ?*const Expr,
    span: common.Span,
};

pub const Explain = struct {
    target: *const Statement,
    span: common.Span,
};

pub const Selector = struct {
    series: SeriesRef,
    tag_filter: ?*const Expr,
    span: common.Span,
};

pub const SeriesRef = union(enum) {
    name: Identifier,
    by_id: ById,
};

pub const ById = struct {
    value: u64,
    span: common.Span,
};

pub const Identifier = struct {
    value: []const u8,
    quoted: bool,
    span: common.Span,
};

pub const LimitClause = struct {
    limit: usize,
    offset: ?usize,
    span: common.Span,
};

pub const LiteralValue = union(enum) {
    integer: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    null,
};

pub const Literal = struct {
    value: LiteralValue,
    span: common.Span,
};

pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    modulo,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    regex_match,
    regex_not_match,
    logical_and,
    logical_or,
};

pub const UnaryOp = enum {
    negate,
    logical_not,
    positive,
};

pub const Expr = union(enum) {
    identifier: Identifier,
    literal: Literal,
    call: Call,
    binary: Binary,
    unary: Unary,
};

pub const Projection = struct {
    expr: *const Expr,
    alias: ?Identifier = null,
    span: common.Span,
};

pub const GroupExpr = struct {
    expr: *const Expr,
    span: common.Span,
};

pub const FillStrategy = union(enum) {
    previous,
    linear,
    null_value,
    constant: *const Expr,
};

pub const FillClause = struct {
    strategy: FillStrategy,
    span: common.Span,
};

pub const OrderDirection = enum {
    asc,
    desc,
};

pub const OrderExpr = struct {
    expr: *const Expr,
    direction: OrderDirection,
    span: common.Span,
};
pub const Call = struct {
    callee: Identifier,
    args: []const *const Expr,
    span: common.Span,
};

pub const Binary = struct {
    op: BinaryOp,
    left: *const Expr,
    right: *const Expr,
    span: common.Span,
};

pub const Unary = struct {
    op: UnaryOp,
    operand: *const Expr,
    span: common.Span,
};

pub fn placeholderStatement(span: common.Span) Statement {
    return .{ .invalid = .{ .span = span } };
}

test "placeholder statement helper" {
    const stmt = placeholderStatement(common.Span.init(0, 4));
    try std.testing.expect(stmt == .invalid);
    try std.testing.expectEqual(@as(usize, 0), stmt.invalid.span.start);
    try std.testing.expectEqual(@as(usize, 4), stmt.invalid.span.end);
}
