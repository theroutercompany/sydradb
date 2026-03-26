const std = @import("std");
const functions = @import("../functions.zig");

pub const CompileError = std.mem.Allocator.Error || functions.TypeCheckError || error{
    UnsupportedStatement,
    UnsupportedFill,
    UnsupportedTagFilter,
    UnsupportedGrouping,
    UnsupportedAggregate,
    UnsupportedProjection,
    UnsupportedOrdering,
    UnsupportedPredicate,
    UnsupportedExpression,
    UnsupportedFunction,
    SeriesNotFound,
    AmbiguousSelector,
    ShadowMismatch,
};
