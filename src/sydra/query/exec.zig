const std = @import("std");
const builtin = @import("builtin");

const compiler = @import("compiler.zig");
const compiler_diagnostics = @import("compiler/diagnostics.zig");
const parser = @import("parser.zig");
const validator = @import("validator.zig");
const plan_builder = @import("plan.zig");
const optimizer = @import("optimizer.zig");
const physical = @import("physical.zig");
const executor = @import("executor.zig");
const cfg = @import("../config.zig");
const engine_mod = @import("../engine.zig");

pub const ExecuteError = parser.ParseError || validator.AnalyzeError || plan_builder.BuildError || optimizer.OptimizeError || physical.BuildError || executor.ExecuteError || compiler.CompileError || std.mem.Allocator.Error || error{ValidationFailed};

pub const ExecutionMode = compiler.ExecutionMode;

pub fn execute(allocator: std.mem.Allocator, engine: *engine_mod.Engine, query: []const u8) ExecuteError!executor.ExecutionCursor {
    return executeWithMode(allocator, engine, query, engine.config.query_compiler_mode);
}

pub fn executeWithMode(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    query: []const u8,
    mode: ExecutionMode,
) ExecuteError!executor.ExecutionCursor {
    var arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    var arena_cleanup = true;
    errdefer {
        if (arena_cleanup) {
            arena_ptr.deinit();
            allocator.destroy(arena_ptr);
        }
    }

    const t_start = std.time.microTimestamp();
    var parser_inst = parser.Parser.init(arena_ptr.allocator(), query);
    var statement = try parser_inst.parse();
    const t_parse = std.time.microTimestamp();

    var analyzer = validator.Analyzer.init(arena_ptr.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    if (!analysis.is_valid) return error.ValidationFailed;
    const t_validate = std.time.microTimestamp();

    const parse_us = durationMicros(t_parse - t_start);
    const validate_us = durationMicros(t_validate - t_parse);

    const prepared = Prepared{
        .allocator = allocator,
        .engine = engine,
        .arena_ptr = arena_ptr,
        .statement = &statement,
        .parse_us = parse_us,
        .validate_us = validate_us,
    };

    const result = switch (mode) {
        .legacy => try executeLegacy(prepared, .legacy, false, ""),
        .compiled => try executeCompiled(prepared, false, "", .compiled),
        .shadow => executeCompiled(prepared, false, "", .shadow) catch |err| switch (err) {
            error.UnsupportedStatement,
            error.UnsupportedFill,
            error.UnsupportedTagFilter,
            error.UnsupportedGrouping,
            error.UnsupportedAggregate,
            error.UnsupportedProjection,
            error.UnsupportedOrdering,
            error.UnsupportedPredicate,
            error.UnsupportedExpression,
            error.UnsupportedFunction,
            error.SeriesNotFound,
            error.AmbiguousSelector,
            => try executeLegacy(prepared, .shadow, true, fallbackReasonText(err)),
            else => try executeLegacy(prepared, .shadow, true, fallbackReasonText(err)),
        },
    };
    arena_cleanup = false;
    return result;
}

fn randomTraceId(allocator: std.mem.Allocator) ![]const u8 {
    const buf = try allocator.alloc(u8, 16);
    errdefer allocator.free(buf);

    std.crypto.random.bytes(buf);

    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    for (buf) |*byte| {
        const idx: usize = @intCast(byte.* % alphabet.len);
        byte.* = alphabet[idx];
    }

    return buf;
}

const Prepared = struct {
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    arena_ptr: *std.heap.ArenaAllocator,
    statement: *const ast.Statement,
    parse_us: u64,
    validate_us: u64,
};

const ast = @import("ast.zig");

fn executeLegacy(
    prepared: Prepared,
    mode: ExecutionMode,
    legacy_fallback: bool,
    fallback_reason: []const u8,
) ExecuteError!executor.ExecutionCursor {
    const logical_start = std.time.microTimestamp();
    var builder = plan_builder.Builder.init(prepared.arena_ptr.allocator());
    const logical_plan = try builder.build(prepared.statement);
    const logical_end = std.time.microTimestamp();
    const optimized_plan = try optimizer.optimize(prepared.arena_ptr.allocator(), logical_plan);
    const optimize_end = std.time.microTimestamp();
    const physical_plan = try physical.build(prepared.arena_ptr.allocator(), optimized_plan);
    const physical_end = std.time.microTimestamp();

    var exec_inst = executor.Executor.init(prepared.allocator, prepared.engine, physical_plan);
    defer exec_inst.deinit();
    const pipeline_start = std.time.microTimestamp();
    var cursor = try exec_inst.run();
    const pipeline_end = std.time.microTimestamp();

    try finalizeCursor(
        prepared,
        &cursor,
        mode,
        legacy_fallback,
        fallback_reason,
        0,
        0,
        durationMicros(logical_end - logical_start),
        durationMicros(optimize_end - logical_end),
        durationMicros(physical_end - optimize_end),
        durationMicros(pipeline_end - pipeline_start),
    );
    return cursor;
}

fn executeCompiled(
    prepared: Prepared,
    legacy_fallback: bool,
    fallback_reason: []const u8,
    mode: ExecutionMode,
) ExecuteError!executor.ExecutionCursor {
    const compile_start = std.time.microTimestamp();
    const detailed = try compiler.compileSelectDetailed(prepared.arena_ptr.allocator(), prepared.engine, prepared.statement);
    const compile_end = std.time.microTimestamp();
    const compiled = detailed.compiled orelse return compiler.fallbackReasonToError(detailed.fallback_reason.?);
    const total_compile_us = durationMicros(compile_end - compile_start);
    const backend_us = compiled.backend.logical_us + compiled.backend.optimize_us + compiled.backend.physical_us;
    const frontend_compile_us = total_compile_us -| backend_us;

    var exec_inst = executor.Executor.init(prepared.allocator, prepared.engine, compiled.backend.physical_plan);
    defer exec_inst.deinit();
    const pipeline_start = std.time.microTimestamp();
    var cursor = try exec_inst.run();
    const pipeline_end = std.time.microTimestamp();

    try finalizeCursor(
        prepared,
        &cursor,
        mode,
        legacy_fallback,
        fallback_reason,
        compiled.bind_us,
        frontend_compile_us,
        compiled.backend.logical_us,
        compiled.backend.optimize_us,
        compiled.backend.physical_us,
        durationMicros(pipeline_end - pipeline_start),
    );
    return cursor;
}

fn finalizeCursor(
    prepared: Prepared,
    cursor: *executor.ExecutionCursor,
    mode: ExecutionMode,
    legacy_fallback: bool,
    fallback_reason: []const u8,
    bind_us: u64,
    compile_us: u64,
    logical_us: u64,
    optimize_us: u64,
    physical_us: u64,
    pipeline_us: u64,
) !void {
    const trace_id = try randomTraceId(prepared.arena_ptr.allocator());
    cursor.stats = .{
        .parse_us = prepared.parse_us,
        .validate_us = prepared.validate_us,
        .bind_us = bind_us,
        .compile_us = compile_us,
        .logical_us = logical_us,
        .optimize_us = optimize_us,
        .physical_us = physical_us,
        .pipeline_us = pipeline_us,
        .trace_id = trace_id,
        .execution_mode = modeName(mode),
        .legacy_fallback = legacy_fallback,
        .fallback_reason = try dupeOptionalString(prepared.arena_ptr.allocator(), fallback_reason),
    };
    cursor.arena = prepared.arena_ptr;
}

pub fn shadowCompareSelect(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    query: []const u8,
) ExecuteError!compiler.ShadowCompareResult {
    _ = builtin;
    var compiled_cursor = try executeWithMode(allocator, engine, query, .compiled);
    defer compiled_cursor.deinit();
    var legacy_cursor = try executeWithMode(allocator, engine, query, .legacy);
    defer legacy_cursor.deinit();

    if (!columnsMatch(compiled_cursor.columns, legacy_cursor.columns)) {
        return .{ .matched = false, .rows_compared = 0, .mismatch = .schema };
    }

    var rows_compared: usize = 0;
    while (true) {
        const compiled_row = try compiled_cursor.next();
        const legacy_row = try legacy_cursor.next();
        if (compiled_row == null and legacy_row == null) {
            return .{ .matched = true, .rows_compared = rows_compared, .mismatch = null };
        }
        if (compiled_row == null or legacy_row == null) {
            return .{ .matched = false, .rows_compared = rows_compared, .mismatch = .row_count };
        }
        if (!valuesMatch(compiled_row.?.values, legacy_row.?.values)) {
            return .{ .matched = false, .rows_compared = rows_compared, .mismatch = .row_values };
        }
        rows_compared += 1;
    }
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0) return "";
    return allocator.dupe(u8, value);
}

fn modeName(mode: ExecutionMode) []const u8 {
    return switch (mode) {
        .legacy => "legacy",
        .shadow => "shadow",
        .compiled => "compiled",
    };
}

fn fallbackReasonText(err: anyerror) []const u8 {
    if (compiler_diagnostics.fromCompileError(err)) |reason| {
        return @tagName(reason);
    }
    return @errorName(err);
}

fn durationMicros(value: i64) u64 {
    return @intCast(@max(value, 0));
}

fn columnsMatch(lhs: []const plan_builder.ColumnInfo, rhs: []const plan_builder.ColumnInfo) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.ascii.eqlIgnoreCase(left.name, right.name)) return false;
    }
    return true;
}

fn valuesMatch(lhs: []const executor.Value, rhs: []const executor.Value) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!executor.Value.equals(left, right)) return false;
    }
    return true;
}

test "execute supports select 1" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 512,
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try engine_mod.Engine.init(talloc, config);
    defer engine.deinit();

    var cursor = try execute(talloc, engine, "select 1");
    defer cursor.deinit();

    try std.testing.expectEqual(@as(usize, 1), cursor.columns.len);

    const first = try cursor.next();
    try std.testing.expect(first != null);
    const row = first.?;
    try std.testing.expectEqual(@as(usize, 1), row.values.len);
    try std.testing.expect(executor.Value.equals(row.values[0], executor.Value{ .integer = 1 }));

    const second = try cursor.next();
    try std.testing.expect(second == null);
}

test "executeWithMode compiled supports uniquely bound series names" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-data", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 512,
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try engine_mod.Engine.init(talloc, config);
    defer engine.deinit();

    const sid: u64 = 4242;
    try engine.registerSeries("weather.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.5, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.5, .tags_json = "{}" });
    try waitForFlushForTest(engine, 1, 1_000);

    var cursor = try executeWithMode(talloc, engine, "select time, value from weather.room1 where time >= 0 order by time limit 10", .compiled);
    defer cursor.deinit();

    try std.testing.expectEqualStrings("compiled", cursor.stats.execution_mode);
    const first = try cursor.next();
    try std.testing.expect(first != null);
    try std.testing.expect(executor.Value.equals(first.?.values[0], executor.Value{ .integer = 10 }));
    try std.testing.expect(executor.Value.equals(first.?.values[1], executor.Value{ .float = 1.5 }));
}

test "executeWithMode shadow falls back for ambiguous series names" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/shadow-data", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 512,
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .shadow,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try engine_mod.Engine.init(talloc, config);
    defer engine.deinit();

    try engine.registerSeries("weather.room1", "{\"host\":\"a\"}", 5001);
    try engine.registerSeries("weather.room1", "{\"host\":\"b\"}", 5002);

    try std.testing.expectError(error.UnsupportedPlan, executeWithMode(talloc, engine, "select value from weather.room1 where time >= 0", .shadow));
}

test "executeWithMode shadow falls back to legacy for unsupported compiler projections" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/shadow-legacy-fallback", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 512,
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .shadow,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try engine_mod.Engine.init(talloc, config);
    defer engine.deinit();

    var cursor = try executeWithMode(talloc, engine, "select abs(-1)", .shadow);
    defer cursor.deinit();

    try std.testing.expectEqualStrings("shadow", cursor.stats.execution_mode);
    try std.testing.expect(cursor.stats.legacy_fallback);
    try std.testing.expectEqualStrings(@tagName(compiler_diagnostics.FallbackReason.unsupported_function), cursor.stats.fallback_reason);

    const first = try cursor.next();
    try std.testing.expect(first != null);
    try std.testing.expect(executor.Value.equals(first.?.values[0], executor.Value{ .float = 1.0 }));
    try std.testing.expect((try cursor.next()) == null);
}

test "shadowCompareSelect matches compiled and legacy rows for supported query" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/shadow-compare", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 512,
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .shadow,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try engine_mod.Engine.init(talloc, config);
    defer engine.deinit();

    const sid: u64 = 9001;
    try engine.registerSeries("compare.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 100, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 200, .value = 3.0, .tags_json = "{}" });
    try waitForFlushForTest(engine, 1, 1_000);

    const result = try shadowCompareSelect(talloc, engine, "select max(value) from compare.room1 where time >= 0");
    try std.testing.expect(result.matched);
    try std.testing.expect(result.rows_compared > 0);
}

fn waitForFlushForTest(engine: *engine_mod.Engine, min_flushes: u64, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        if (engine.metrics.flush_total.load(.monotonic) >= min_flushes) return;
        if (@hasDecl(std.time, "sleep")) {
            std.time.sleep(5 * std.time.ns_per_ms);
        } else {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
    return error.Timeout;
}
