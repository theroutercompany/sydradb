const std = @import("std");

const binder = @import("compiler/binder.zig");
const cfg_mod = @import("../config.zig");
const diagnostics = @import("compiler/diagnostics.zig");
const engine_mod = @import("../engine.zig");
const errors = @import("compiler/errors.zig");
const ir = @import("compiler/ir.zig");
const lowerer = @import("compiler/lowerer.zig");
const parser = @import("parser.zig");
const passes = @import("compiler/passes.zig");

pub const ExecutionMode = cfg_mod.QueryCompilerMode;

pub const DeferredFeature = ir.DeferredFeature;
pub const BoundSelectorSource = ir.BoundSelectorSource;
pub const BoundSelector = ir.BoundSelector;
pub const TypedExpr = ir.TypedExpr;
pub const TypedProjection = ir.TypedProjection;
pub const TypedGrouping = ir.TypedGrouping;
pub const TypedOrdering = ir.TypedOrdering;
pub const TimeBound = ir.TimeBound;
pub const TimeRange = ir.TimeRange;
pub const AggregateKind = ir.AggregateKind;
pub const AggregateSpec = ir.AggregateSpec;
pub const QueryProperties = ir.QueryProperties;
pub const TypedQuery = ir.TypedQuery;
pub const BackendLoweringResult = ir.BackendLoweringResult;
pub const CompiledSelect = ir.CompiledSelect;
pub const CompileSelectDetailedResult = ir.CompileSelectDetailedResult;
pub const CompilationDiagnostic = diagnostics.CompilationDiagnostic;
pub const FallbackReason = diagnostics.FallbackReason;
pub const ShadowCompareResult = diagnostics.ShadowCompareResult;
pub const CompileError = errors.CompileError;

pub fn canCompile(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    statement: *const @import("ast.zig").Statement,
) CompileError!bool {
    const detailed = try compileSelectDetailed(allocator, engine, statement);
    return detailed.isSupported();
}

pub fn compileSelectDetailed(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    statement: *const @import("ast.zig").Statement,
) CompileError!CompileSelectDetailedResult {
    if (statement.* != .select) {
        return try unsupportedResult(allocator, .unsupported_statement, null, 0);
    }

    const bind_start = std.time.microTimestamp();
    const bind_result = try binder.bindSelector(allocator, engine, statement.select.selector);
    const bind_end = std.time.microTimestamp();
    const bind_us = durationMicros(bind_end - bind_start);

    if (bind_result.fallback_reason) |reason| {
        return .{
            .compiled = null,
            .diagnostics = bind_result.diagnostics,
            .fallback_reason = reason,
            .bind_us = bind_us,
        };
    }

    const typed_query = passes.buildTypedSelect(allocator, statement, bind_result.selector) catch |err| {
        if (diagnostics.fromCompileError(err)) |reason| {
            return try unsupportedResult(allocator, reason, null, bind_us);
        }
        return err;
    };
    const backend = lowerer.lowerTypedQuery(allocator, &typed_query) catch |err| {
        if (diagnostics.fromCompileError(err)) |reason| {
            return try unsupportedResult(allocator, reason, null, bind_us);
        }
        return err;
    };

    return .{
        .compiled = .{
            .typed_query = typed_query,
            .backend = backend,
            .bind_us = bind_us,
        },
        .diagnostics = &.{},
        .fallback_reason = null,
        .bind_us = bind_us,
    };
}

pub fn compileSelect(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    statement: *const @import("ast.zig").Statement,
) CompileError!CompiledSelect {
    const detailed = try compileSelectDetailed(allocator, engine, statement);
    if (detailed.compiled) |compiled| return compiled;
    return fallbackReasonToError(detailed.fallback_reason orelse .unsupported_statement);
}

pub fn lowerToBackend(
    allocator: std.mem.Allocator,
    typed_query: *const TypedQuery,
) CompileError!BackendLoweringResult {
    return try lowerer.lowerTypedQuery(allocator, typed_query);
}

fn unsupportedResult(
    allocator: std.mem.Allocator,
    reason: FallbackReason,
    span: ?@import("common.zig").Span,
    bind_us: u64,
) !CompileSelectDetailedResult {
    const diags = try allocator.alloc(CompilationDiagnostic, 1);
    diags[0] = try diagnostics.makeDiagnostic(allocator, reason, span);
    return .{
        .compiled = null,
        .diagnostics = diags,
        .fallback_reason = reason,
        .bind_us = bind_us,
    };
}

pub fn fallbackReasonToError(reason: FallbackReason) CompileError {
    return switch (reason) {
        .unsupported_statement => error.UnsupportedStatement,
        .unsupported_fill => error.UnsupportedFill,
        .unsupported_tag_filter => error.UnsupportedTagFilter,
        .unsupported_grouping => error.UnsupportedGrouping,
        .unsupported_aggregate => error.UnsupportedAggregate,
        .unsupported_projection => error.UnsupportedProjection,
        .unsupported_ordering => error.UnsupportedOrdering,
        .unsupported_predicate => error.UnsupportedPredicate,
        .unsupported_expression => error.UnsupportedExpression,
        .unsupported_function => error.UnsupportedFunction,
        .series_not_found => error.SeriesNotFound,
        .ambiguous_selector => error.AmbiguousSelector,
        .shadow_mismatch => error.ShadowMismatch,
    };
}

fn durationMicros(value: i64) u64 {
    return @intCast(@max(value, 0));
}

test "can compile constant select" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/compiler-constant", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config = try testConfig(alloc, data_path);
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var parser_inst = parser.Parser.init(arena.allocator(), "select 1");
    var statement = try parser_inst.parse();

    try std.testing.expect(try canCompile(arena.allocator(), engine, &statement));
}

test "compiler binds unique series names and lowers to backend" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/compiler-bind", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config = try testConfig(alloc, data_path);
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    try engine.registerSeries("weather.room1", "{}", 99);

    var parser_inst = parser.Parser.init(arena.allocator(), "select time, value from weather.room1 where time >= 0 order by time limit 5");
    var statement = try parser_inst.parse();
    const compiled = try compileSelect(arena.allocator(), engine, &statement);

    try std.testing.expect(compiled.typed_query.bound_selector != null);
    try std.testing.expectEqual(@as(@import("../types.zig").SeriesId, 99), compiled.typed_query.bound_selector.?.series_id);
    try std.testing.expect(compiled.backend.physical_plan.root.* == .limit);
    try std.testing.expect(compiled.bind_us > 0);
}

test "compileSelectDetailed surfaces fallback diagnostics" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/compiler-detailed", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config = try testConfig(alloc, data_path);
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var parser_inst = parser.Parser.init(arena.allocator(), "select abs(-1)");
    var statement = try parser_inst.parse();
    const detailed = try compileSelectDetailed(arena.allocator(), engine, &statement);

    try std.testing.expect(detailed.compiled == null);
    try std.testing.expectEqual(FallbackReason.unsupported_function, detailed.fallback_reason.?);
    try std.testing.expectEqual(@as(usize, 1), detailed.diagnostics.len);
}

test "compiler rejects ambiguous series names" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/compiler-ambiguous", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config = try testConfig(alloc, data_path);
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    try engine.registerSeries("weather.room1", "{\"host\":\"a\"}", 100);
    try engine.registerSeries("weather.room1", "{\"host\":\"b\"}", 101);

    var parser_inst = parser.Parser.init(arena.allocator(), "select value from weather.room1 where time >= 0");
    var statement = try parser_inst.parse();

    const detailed = try compileSelectDetailed(arena.allocator(), engine, &statement);
    try std.testing.expect(detailed.compiled == null);
    try std.testing.expectEqual(FallbackReason.ambiguous_selector, detailed.fallback_reason.?);
}

fn testConfig(alloc: std.mem.Allocator, data_path: []const u8) !cfg_mod.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .legacy,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}
