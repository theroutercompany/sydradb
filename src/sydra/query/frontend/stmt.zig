const common = @import("../common.zig");

pub const StatementKind = enum {
    select,
    insert,
    delete,
    explain,
};

pub const FrontendStmt = union(enum) {
    select: Select,
    insert: Insert,
    delete: Delete,
    explain: Explain,

    pub fn kind(self: @This()) StatementKind {
        return switch (self) {
            .select => .select,
            .insert => .insert,
            .delete => .delete,
            .explain => .explain,
        };
    }

    pub fn span(self: @This()) common.Span {
        return switch (self) {
            .select => |select| select.span,
            .insert => |insert| insert.span,
            .delete => |delete| delete.span,
            .explain => |explain| explain.span,
        };
    }
};

pub const ExplainMode = enum {
    standard,
    bytecode,
};

pub const Explain = struct {
    mode: ExplainMode,
    target: *const FrontendStmt,
    span: common.Span,
};

pub const Select = struct {
    projections: []const Projection,
    selector: ?Selector = null,
    predicate: ?*const Expr = null,
    groupings: []const Grouping = &.{},
    ordering: []const Ordering = &.{},
    limit: ?LimitClause = null,
    span: common.Span,
};

pub const Insert = struct {
    target: Identifier,
    columns: []const *const Expr = &.{},
    values: []const *const Expr = &.{},
    span: common.Span,
};

pub const Delete = struct {
    target: Identifier,
    predicate: ?*const Expr = null,
    span: common.Span,
};

pub const Selector = struct {
    series: SeriesRef,
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
    quoted: bool = false,
    span: common.Span,
};

pub const LimitClause = struct {
    limit: usize,
    offset: ?usize = null,
    span: common.Span,
};

pub const Projection = struct {
    expr: *const Expr,
    span: common.Span,
};

pub const Grouping = struct {
    expr: *const Expr,
    span: common.Span,
};

pub const OrderDirection = enum {
    asc,
    desc,
};

pub const Ordering = struct {
    expr: *const Expr,
    direction: OrderDirection = .asc,
    span: common.Span,
};

pub const Expr = union(enum) {
    identifier: Identifier,
    integer: IntegerLiteral,
    string: StringLiteral,
    parameter: Parameter,
    comparison: Comparison,
    call: Call,

    pub fn span(self: @This()) common.Span {
        return switch (self) {
            .identifier => |identifier| identifier.span,
            .integer => |literal| literal.span,
            .string => |literal| literal.span,
            .parameter => |parameter| parameter.span,
            .comparison => |comparison| comparison.span,
            .call => |call| call.span,
        };
    }
};

pub const IntegerLiteral = struct {
    value: i64,
    text: []const u8,
    span: common.Span,
};

pub const StringLiteral = struct {
    value: []const u8,
    span: common.Span,
};

pub const ParameterKind = enum {
    positional,
    named,
};

pub const Parameter = struct {
    raw: []const u8,
    kind: ParameterKind,
    span: common.Span,
};

pub const ComparisonOp = enum {
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

pub const Comparison = struct {
    op: ComparisonOp,
    left: *const Expr,
    right: *const Expr,
    span: common.Span,
};

pub const Call = struct {
    callee: Identifier,
    args: []const *const Expr,
    span: common.Span,
};
