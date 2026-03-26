const std = @import("std");
const common = @import("../common.zig");

pub const FallbackReason = enum {
    unsupported_statement,
    unsupported_fill,
    unsupported_tag_filter,
    unsupported_grouping,
    unsupported_aggregate,
    unsupported_projection,
    unsupported_ordering,
    unsupported_predicate,
    unsupported_expression,
    unsupported_function,
    series_not_found,
    ambiguous_selector,
    shadow_mismatch,
};

pub const CompilationDiagnostic = struct {
    code: FallbackReason,
    message: []const u8,
    span: ?common.Span = null,
};

pub const ShadowCompareMismatch = enum {
    schema,
    row_count,
    row_values,
};

pub const ShadowCompareResult = struct {
    matched: bool,
    rows_compared: usize,
    mismatch: ?ShadowCompareMismatch = null,
};

pub fn diagnosticMessage(code: FallbackReason) []const u8 {
    return switch (code) {
        .unsupported_statement => "statement is not supported by the native compiler",
        .unsupported_fill => "fill clauses stay on the legacy path",
        .unsupported_tag_filter => "tag filters stay on the legacy path",
        .unsupported_grouping => "grouping shape is not supported by the native compiler",
        .unsupported_aggregate => "aggregate shape is not supported by the native compiler",
        .unsupported_projection => "projection shape is not supported by the native compiler",
        .unsupported_ordering => "ordering shape is not supported by the native compiler",
        .unsupported_predicate => "predicate shape is not supported by the native compiler",
        .unsupported_expression => "expression shape is not supported by the native compiler",
        .unsupported_function => "function is not supported by the native compiler",
        .series_not_found => "series selector could not be resolved",
        .ambiguous_selector => "series selector is ambiguous",
        .shadow_mismatch => "compiled and legacy execution did not match",
    };
}

pub fn reasonName(reason: FallbackReason) []const u8 {
    return @tagName(reason);
}

pub fn fromCompileError(err: anyerror) ?FallbackReason {
    return switch (err) {
        error.UnsupportedStatement => .unsupported_statement,
        error.UnsupportedFill => .unsupported_fill,
        error.UnsupportedTagFilter => .unsupported_tag_filter,
        error.UnsupportedGrouping => .unsupported_grouping,
        error.UnsupportedAggregate => .unsupported_aggregate,
        error.UnsupportedProjection => .unsupported_projection,
        error.UnsupportedOrdering => .unsupported_ordering,
        error.UnsupportedPredicate => .unsupported_predicate,
        error.UnsupportedExpression => .unsupported_expression,
        error.UnsupportedFunction => .unsupported_function,
        error.SeriesNotFound => .series_not_found,
        error.AmbiguousSelector => .ambiguous_selector,
        else => null,
    };
}

pub fn makeDiagnostic(
    allocator: std.mem.Allocator,
    code: FallbackReason,
    span: ?common.Span,
) !CompilationDiagnostic {
    return .{
        .code = code,
        .message = try allocator.dupe(u8, diagnosticMessage(code)),
        .span = span,
    };
}
