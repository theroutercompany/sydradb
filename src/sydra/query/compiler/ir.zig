const ast = @import("../ast.zig");
const common = @import("../common.zig");
const diagnostics = @import("diagnostics.zig");
const functions = @import("../functions.zig");
const plan = @import("../plan.zig");
const physical = @import("../physical.zig");
const types = @import("../../types.zig");

pub const DeferredFeature = enum {
    insert,
    delete,
    explain,
    fill,
    tag_filter,
    rate_window,
    tag_selector_binding,
};

pub const BoundSelectorSource = enum {
    by_id,
    unique_name,
    exact_match,
};

pub const BoundSelector = struct {
    source: BoundSelectorSource,
    series_id: types.SeriesId,
    name: ?[]const u8 = null,
    canonical_tags: ?[]const u8 = null,
    span: common.Span,
};

pub const TypedExpr = struct {
    expr: *const ast.Expr,
    ty: functions.Type,
    has_time: bool,
};

pub const TypedProjection = struct {
    expr: TypedExpr,
    name: []const u8,
    alias: ?ast.Identifier,
    is_grouping: bool,
    is_aggregate: bool,
};

pub const TypedGrouping = struct {
    expr: TypedExpr,
    is_time_bucket: bool,
};

pub const TypedOrdering = struct {
    expr: TypedExpr,
    direction: ast.OrderDirection,
};

pub const TimeBound = struct {
    value: i64,
    inclusive: bool,
};

pub const TimeRange = struct {
    start: ?TimeBound = null,
    end: ?TimeBound = null,
};

pub const AggregateKind = enum {
    avg,
    sum,
    count,
    min,
    max,
    percentile,
    rate,
    irate,
    delta,
    integral,
    first,
    last,
};

pub const AggregateSpec = struct {
    expr: *const ast.Expr,
    kind: AggregateKind,
    name: []const u8,
    args: []const TypedExpr,
    return_type: functions.Type,
};

pub const QueryProperties = struct {
    requires_sorted_input: bool = false,
    can_use_rollup: bool = false,
    materializes: bool = false,
    uses_top_n: bool = false,
};

pub const TypedQuery = struct {
    statement: *const ast.Statement,
    select: *const ast.Select,
    bound_selector: ?BoundSelector,
    predicate: ?TypedExpr,
    projections: []const TypedProjection,
    groupings: []const TypedGrouping,
    ordering: []const TypedOrdering,
    aggregates: []const AggregateSpec,
    time_range: TimeRange,
    properties: QueryProperties,
    deferred_features: []const DeferredFeature,
    is_aggregate_query: bool,
};

pub const BackendLoweringResult = struct {
    logical_plan: ?*plan.Node = null,
    optimized_plan: ?*plan.Node = null,
    physical_plan: physical.PhysicalPlan,
    logical_us: u64 = 0,
    optimize_us: u64 = 0,
    physical_us: u64,
};

pub const CompiledSelect = struct {
    typed_query: TypedQuery,
    backend: BackendLoweringResult,
    bind_us: u64,
};

pub const CompileSelectDetailedResult = struct {
    compiled: ?CompiledSelect,
    diagnostics: []const diagnostics.CompilationDiagnostic,
    fallback_reason: ?diagnostics.FallbackReason,
    bind_us: u64,

    pub fn isSupported(self: @This()) bool {
        return self.compiled != null;
    }
};

pub const ShadowCompareResult = diagnostics.ShadowCompareResult;
