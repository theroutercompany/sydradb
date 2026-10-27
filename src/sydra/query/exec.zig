const std = @import("std");
const builtin = @import("builtin");

const bytecode = @import("bytecode.zig");
const codegen = @import("codegen.zig");
const compiler = @import("compiler.zig");
const compiler_diagnostics = @import("compiler/diagnostics.zig");
const frontend = @import("frontend.zig");
const parser = @import("parser.zig");
const table_use = @import("table_use.zig");
const validator = @import("validator.zig");
const plan_builder = @import("plan.zig");
const optimizer = @import("optimizer.zig");
const physical = @import("physical.zig");
const executor = @import("executor.zig");
const vm = @import("vm.zig");
const cfg = @import("../config.zig");
const engine_mod = @import("../engine.zig");
const monotime = @import("../time.zig");

pub const ExecuteError = parser.ParseError || validator.AnalyzeError || frontend.normalize.NormalizeError || plan_builder.BuildError || optimizer.OptimizeError || physical.BuildError || executor.ExecuteError || compiler.CompileError || codegen.CodegenError || vm.VmError || std.mem.Allocator.Error || error{ValidationFailed};

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

    var phase_timer = monotime.startTimer();
    var parser_inst = parser.Parser.init(arena_ptr.allocator(), query);
    var statement = try parser_inst.parse();
    const parse_us = phase_timer.read() / std.time.ns_per_us;
    phase_timer.reset();

    var analyzer = validator.Analyzer.init(arena_ptr.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    if (!analysis.is_valid) return error.ValidationFailed;
    const validate_us = phase_timer.read() / std.time.ns_per_us;

    const prepared = Prepared{
        .allocator = allocator,
        .engine = engine,
        .arena_ptr = arena_ptr,
        .statement = &statement,
        .parse_us = parse_us,
        .validate_us = validate_us,
    };

    if (statement == .explain and statement.explain.mode == .bytecode) {
        const result = try executeExplainBytecode(prepared, mode, statement.explain);
        arena_cleanup = false;
        return result;
    }
    if (statement == .explain and statement.explain.mode == .tables_used) {
        const result = try executeExplainTablesUsed(prepared, mode, statement.explain);
        arena_cleanup = false;
        return result;
    }

    const result = switch (mode) {
        .legacy => try executeLegacy(prepared, .legacy, false, ""),
        .compiled => try executeCompiledPreferred(prepared, .compiled),
        .shadow => try executeCompiledPreferred(prepared, .shadow),
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
    var phase_timer = monotime.startTimer();
    var builder = plan_builder.Builder.init(prepared.arena_ptr.allocator());
    const logical_plan = try builder.build(prepared.statement);
    const logical_us = phase_timer.read() / std.time.ns_per_us;
    phase_timer.reset();
    const optimized_plan = try optimizer.optimize(prepared.arena_ptr.allocator(), logical_plan);
    const optimize_us = phase_timer.read() / std.time.ns_per_us;
    phase_timer.reset();
    const physical_plan = try physical.build(prepared.arena_ptr.allocator(), optimized_plan);
    const physical_us = phase_timer.read() / std.time.ns_per_us;

    var exec_inst = executor.Executor.init(prepared.allocator, prepared.engine, physical_plan);
    defer exec_inst.deinit();
    phase_timer.reset();
    var cursor = try exec_inst.run();
    const pipeline_us = phase_timer.read() / std.time.ns_per_us;

    try finalizeCursor(
        prepared,
        &cursor,
        mode,
        legacy_fallback,
        fallback_reason,
        0,
        0,
        logical_us,
        optimize_us,
        physical_us,
        pipeline_us,
    );
    return cursor;
}

fn executeCompiled(
    prepared: Prepared,
    mode: ExecutionMode,
) ExecuteError!executor.ExecutionCursor {
    var compile_timer = monotime.startTimer();
    recordCompileAttempt(prepared.engine);
    const detailed = try compiler.compileSelectDetailed(prepared.arena_ptr.allocator(), prepared.engine, prepared.statement);
    const compiled = detailed.compiled orelse return compiler.fallbackReasonToError(detailed.fallback_reason.?);
    recordCompileSuccess(prepared.engine);
    const total_compile_us = compile_timer.read() / std.time.ns_per_us;
    const backend_us = compiled.backend.logical_us + compiled.backend.optimize_us + compiled.backend.physical_us;
    const frontend_compile_us = total_compile_us -| backend_us;

    const lowered = codegen.buildProgram(prepared.allocator, compiled) catch |err| {
        if (codegenFallbackReason(err) != null) {
            return executeCompiledPhysical(prepared, mode, compiled, frontend_compile_us);
        }
        return err;
    };
    return executeCompiledBytecode(prepared, mode, compiled, lowered, frontend_compile_us);
}

fn executeCompiledPhysical(
    prepared: Prepared,
    mode: ExecutionMode,
    compiled: compiler.CompiledSelect,
    frontend_compile_us: u64,
) ExecuteError!executor.ExecutionCursor {
    var exec_inst = executor.Executor.init(prepared.allocator, prepared.engine, compiled.backend.physical_plan);
    defer exec_inst.deinit();
    var pipeline_timer = monotime.startTimer();
    var cursor = try exec_inst.run();
    const pipeline_us = pipeline_timer.read() / std.time.ns_per_us;

    try finalizeCursor(
        prepared,
        &cursor,
        mode,
        false,
        "",
        compiled.bind_us,
        frontend_compile_us,
        compiled.backend.logical_us,
        compiled.backend.optimize_us,
        compiled.backend.physical_us,
        pipeline_us,
    );
    return cursor;
}

fn executeCompiledBytecode(
    prepared: Prepared,
    mode: ExecutionMode,
    compiled: compiler.CompiledSelect,
    lowered: codegen.CodegenResult,
    frontend_compile_us: u64,
) ExecuteError!executor.ExecutionCursor {
    var lowered_program = lowered;
    defer {
        lowered_program.program.deinit();
        if (lowered_program.columns.len != 0) prepared.allocator.free(lowered_program.columns);
    }

    var machine = try vm.VirtualMachine.init(prepared.allocator, prepared.engine, &lowered_program.program);
    defer machine.deinit();

    var row_list = std.array_list.Managed([]executor.Value).init(prepared.allocator);
    defer row_list.deinit();

    const arena = prepared.arena_ptr.allocator();
    var pipeline_timer = monotime.startTimer();
    while (true) {
        const step = try machine.step();
        switch (step) {
            .done => break,
            .row => |row| {
                const values = try arena.alloc(executor.Value, row.len);
                for (row, 0..) |value, idx| values[idx] = try copyValueForCursor(arena, value);
                try row_list.append(values);
            },
        }
    }
    const rows = try arena.alloc([]executor.Value, row_list.items.len);
    @memcpy(rows, row_list.items);
    const columns = try arena.dupe(plan_builder.ColumnInfo, lowered_program.columns);
    var cursor = try executor.cursorFromRows(prepared.allocator, columns, rows);
    cursor.arena = prepared.arena_ptr;
    const pipeline_us = pipeline_timer.read() / std.time.ns_per_us;

    try finalizeCursor(
        prepared,
        &cursor,
        mode,
        false,
        "",
        compiled.bind_us,
        frontend_compile_us,
        compiled.backend.logical_us,
        compiled.backend.optimize_us,
        compiled.backend.physical_us,
        pipeline_us,
    );
    return cursor;
}

fn executeCompiledPreferred(
    prepared: Prepared,
    mode: ExecutionMode,
) ExecuteError!executor.ExecutionCursor {
    return executeCompiled(prepared, mode) catch |err| {
        if (compiler_diagnostics.fromCompileError(err)) |reason| {
            recordCompileFallback(prepared.engine, reason);
            return executeLegacy(prepared, mode, true, compiler_diagnostics.reasonName(reason)) catch |legacy_err| {
                if (reason == .ambiguous_selector and legacy_err == error.AmbiguousMetricFamilyQuery) {
                    return error.AmbiguousSelector;
                }
                return legacy_err;
            };
        }
        return err;
    };
}

fn copyValueForCursor(allocator: std.mem.Allocator, value: executor.Value) !executor.Value {
    return switch (value) {
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        else => value,
    };
}

fn executeExplainBytecode(
    prepared: Prepared,
    mode: ExecutionMode,
    explain: *const ast.Explain,
) ExecuteError!executor.ExecutionCursor {
    var compile_timer = monotime.startTimer();
    recordCompileAttempt(prepared.engine);

    const compiled = compiler.compileSelect(prepared.arena_ptr.allocator(), prepared.engine, explain.target) catch |err| {
        if (compiler_diagnostics.fromCompileError(err)) |reason| {
            recordCompileFallback(prepared.engine, reason);
        }
        return err;
    };

    var lowered = codegen.buildProgram(prepared.allocator, compiled) catch |err| {
        if (codegenFallbackReason(err)) |reason| {
            recordCompileFallback(prepared.engine, reason);
        }
        return err;
    };
    defer {
        lowered.program.deinit();
        if (lowered.columns.len != 0) prepared.allocator.free(lowered.columns);
    }

    recordCompileSuccess(prepared.engine);

    const lines = try bytecode.disassemble(prepared.arena_ptr.allocator(), lowered.program);
    const columns = try buildExplainBytecodeColumns(prepared.arena_ptr.allocator());
    const rows = try buildExplainBytecodeRows(prepared.arena_ptr.allocator(), lines);
    var cursor = try executor.cursorFromRows(prepared.allocator, columns, rows);
    const compile_us = compile_timer.read() / std.time.ns_per_us;

    try finalizeCursor(
        prepared,
        &cursor,
        mode,
        false,
        "",
        compiled.bind_us,
        compile_us -| compiled.bind_us,
        0,
        0,
        0,
        0,
    );
    return cursor;
}

fn executeExplainTablesUsed(
    prepared: Prepared,
    mode: ExecutionMode,
    explain: *const ast.Explain,
) ExecuteError!executor.ExecutionCursor {
    const normalized = try frontend.normalize.normalizeAstStatement(prepared.arena_ptr.allocator(), explain.target);

    var typed_query: ?compiler.TypedQuery = null;
    var bind_us: u64 = 0;
    var compile_us: u64 = 0;
    var logical_us: u64 = 0;
    var optimize_us: u64 = 0;
    var physical_us: u64 = 0;

    if (explain.target.* == .select) {
        var compile_timer = monotime.startTimer();
        recordCompileAttempt(prepared.engine);
        const detailed = compiler.compileSelectDetailed(prepared.arena_ptr.allocator(), prepared.engine, explain.target) catch |err| {
            if (compiler_diagnostics.fromCompileError(err)) |reason| {
                recordCompileFallback(prepared.engine, reason);
            }
            return err;
        };
        bind_us = detailed.bind_us;
        if (detailed.compiled) |compiled| {
            recordCompileSuccess(prepared.engine);
            typed_query = compiled.typed_query;
            logical_us = compiled.backend.logical_us;
            optimize_us = compiled.backend.optimize_us;
            physical_us = compiled.backend.physical_us;
            const backend_us = logical_us + optimize_us + physical_us;
            compile_us = (compile_timer.read() / std.time.ns_per_us) -| backend_us;
        } else if (detailed.fallback_reason) |reason| {
            recordCompileFallback(prepared.engine, reason);
            compile_us = (compile_timer.read() / std.time.ns_per_us) -| bind_us;
        }
    }

    const uses = try table_use.collectTableUses(prepared.arena_ptr.allocator(), typed_query, normalized.statement);
    const columns = try buildExplainTablesUsedColumns(prepared.arena_ptr.allocator());
    const rows = try buildExplainTablesUsedRows(prepared.arena_ptr.allocator(), uses);
    var cursor = try executor.cursorFromRows(prepared.allocator, columns, rows);

    try finalizeCursor(
        prepared,
        &cursor,
        mode,
        false,
        "",
        bind_us,
        compile_us,
        logical_us,
        optimize_us,
        physical_us,
        0,
    );
    return cursor;
}

fn buildExplainBytecodeColumns(allocator: std.mem.Allocator) ![]const plan_builder.ColumnInfo {
    const names = [_][]const u8{
        "addr",
        "opcode",
        "p1",
        "p2",
        "p3",
        "p4",
        "p5",
        "comment",
    };

    const columns = try allocator.alloc(plan_builder.ColumnInfo, names.len);
    for (names, 0..) |name, idx| {
        const expr = try allocator.create(ast.Expr);
        expr.* = .{
            .identifier = .{
                .value = name,
                .quoted = false,
                .span = .{ .start = 0, .end = 0 },
            },
        };
        columns[idx] = .{ .name = name, .expr = expr };
    }
    return columns;
}

fn buildExplainBytecodeRows(
    allocator: std.mem.Allocator,
    lines: []const bytecode.DisassemblyLine,
) ![]([]executor.Value) {
    const rows = try allocator.alloc([]executor.Value, lines.len);
    for (lines, 0..) |line, idx| {
        const values = try allocator.alloc(executor.Value, 8);
        values[0] = .{ .integer = @intCast(line.pc) };
        values[1] = .{ .string = line.opcode };
        values[2] = .{ .integer = line.p1 };
        values[3] = .{ .integer = line.p2 };
        values[4] = .{ .integer = line.p3 };
        values[5] = .{ .string = line.p4 };
        values[6] = .{ .integer = line.p5 };
        values[7] = .{ .string = line.comment };
        rows[idx] = values;
    }
    return rows;
}

fn buildExplainTablesUsedColumns(allocator: std.mem.Allocator) ![]const plan_builder.ColumnInfo {
    const names = [_][]const u8{
        "kind",
        "name",
        "series_id",
    };

    const columns = try allocator.alloc(plan_builder.ColumnInfo, names.len);
    for (names, 0..) |name, idx| {
        const expr = try allocator.create(ast.Expr);
        expr.* = .{
            .identifier = .{
                .value = name,
                .quoted = false,
                .span = .{ .start = 0, .end = 0 },
            },
        };
        columns[idx] = .{ .name = name, .expr = expr };
    }
    return columns;
}

fn buildExplainTablesUsedRows(
    allocator: std.mem.Allocator,
    uses: []const table_use.TableUse,
) ![]([]executor.Value) {
    const rows = try allocator.alloc([]executor.Value, uses.len);
    for (uses, 0..) |use, idx| {
        const values = try allocator.alloc(executor.Value, 3);
        values[0] = .{ .string = @tagName(use.kind) };
        values[1] = .{ .string = use.name };
        values[2] = if (use.series_id) |series_id|
            .{ .integer = @intCast(series_id) }
        else
            .null;
        rows[idx] = values;
    }
    return rows;
}

fn codegenFallbackReason(err: anyerror) ?compiler.FallbackReason {
    return switch (err) {
        error.UnsupportedPreparedQuery => .unsupported_statement,
        error.UnsupportedProjection => .unsupported_projection,
        error.UnsupportedPredicate => .unsupported_predicate,
        error.InvalidLiteral => .unsupported_expression,
        else => null,
    };
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
    const has_selector = prepared.statement.* == .select and prepared.statement.select.selector != null;
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
        .selector_mode = if (has_selector) "exact" else "",
        .selected_series_count = if (has_selector) 1 else 0,
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

fn recordCompileAttempt(engine: *engine_mod.Engine) void {
    _ = engine.metrics.query_compile_attempts_total.fetchAdd(1, .monotonic);
}

fn recordCompileSuccess(engine: *engine_mod.Engine) void {
    _ = engine.metrics.query_compile_success_total.fetchAdd(1, .monotonic);
}

fn recordCompileFallback(engine: *engine_mod.Engine, reason: compiler.FallbackReason) void {
    _ = engine.metrics.query_compile_fallback_total.fetchAdd(1, .monotonic);
    switch (reason) {
        .series_not_found => _ = engine.metrics.query_compile_series_not_found_total.fetchAdd(1, .monotonic),
        .ambiguous_selector => _ = engine.metrics.query_compile_ambiguous_selector_total.fetchAdd(1, .monotonic),
        .shadow_mismatch => _ = engine.metrics.query_compile_shadow_mismatch_total.fetchAdd(1, .monotonic),
        else => _ = engine.metrics.query_compile_unsupported_total.fetchAdd(1, .monotonic),
    }
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

    try std.testing.expectEqualStrings("compiled", cursor.stats.execution_mode);
    try std.testing.expect(!cursor.stats.legacy_fallback);
    try std.testing.expectEqual(@as(usize, 1), cursor.columns.len);

    const first = try cursor.next();
    try std.testing.expect(first != null);
    const row = first.?;
    try std.testing.expectEqual(@as(usize, 1), row.values.len);
    try std.testing.expect(executor.Value.equals(row.values[0], executor.Value{ .integer = 1 }));

    const second = try cursor.next();
    try std.testing.expect(second == null);
}

test "execute supports explain bytecode" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/explain-bytecode", .{tmp.sub_path});
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

    var cursor = try execute(talloc, engine, "explain bytecode select 1");
    defer cursor.deinit();

    try std.testing.expectEqualStrings("compiled", cursor.stats.execution_mode);
    const snapshot = try collectCursorSnapshot(talloc, &cursor);
    defer talloc.free(snapshot);
    try std.testing.expectEqualStrings(
        \\addr|opcode|p1|p2|p3|p4|p5|comment
        \\0|load_const|0|0|0|const[0]|0|_col0
        \\1|result_row|0|1|0|schema[0]|0|
        \\2|halt|0|0|0||0|
        \\
    , snapshot);
}

test "execute supports explain tables-used" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/explain-tables-used", .{tmp.sub_path});
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

    try engine.registerSeries("weather.room1", "{\"host\":\"a\"}", 41);

    var cursor = try execute(talloc, engine, "explain tables_used select value from weather.room1 where time >= 0");
    defer cursor.deinit();

    try std.testing.expectEqualStrings("compiled", cursor.stats.execution_mode);
    const snapshot = try collectCursorSnapshot(talloc, &cursor);
    defer talloc.free(snapshot);
    try std.testing.expectEqualStrings(
        \\kind|name|series_id
        \\series|weather.room1|41
        \\
    , snapshot);
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

    try std.testing.expectError(error.AmbiguousSelector, executeWithMode(talloc, engine, "select value from weather.room1 where time >= 0", .shadow));
}

test "executeWithMode shadow compiles constant scalar functions" {
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
    try std.testing.expect(!cursor.stats.legacy_fallback);
    try std.testing.expectEqualStrings("", cursor.stats.fallback_reason);

    const first = try cursor.next();
    try std.testing.expect(first != null);
    try std.testing.expect(executor.Value.equals(first.?.values[0], executor.Value{ .float = 1.0 }));
    try std.testing.expect((try cursor.next()) == null);
}

test "executeWithMode compiled compiles constant scalar functions and records success metrics" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-legacy-fallback", .{tmp.sub_path});
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

    var cursor = try executeWithMode(talloc, engine, "select abs(-1)", .compiled);
    defer cursor.deinit();

    try std.testing.expectEqualStrings("compiled", cursor.stats.execution_mode);
    try std.testing.expect(!cursor.stats.legacy_fallback);
    try std.testing.expectEqualStrings("", cursor.stats.fallback_reason);
    try std.testing.expectEqual(@as(u64, 1), engine.metrics.query_compile_attempts_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), engine.metrics.query_compile_success_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), engine.metrics.query_compile_fallback_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), engine.metrics.query_compile_unsupported_total.load(.monotonic));

    const first = try cursor.next();
    try std.testing.expect(first != null);
    try std.testing.expect(executor.Value.equals(first.?.values[0], executor.Value{ .float = 1.0 }));
    try std.testing.expect((try cursor.next()) == null);
}

test "executeWithMode compiled supports coalesce in constant and row projections" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-coalesce", .{tmp.sub_path});
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

    const sid: u64 = 7555;
    try engine.registerSeries("coalesce.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.5, .tags_json = "{}" });
    try waitForFlushForTest(engine, 1, 1_000);

    var constant_cursor = try executeWithMode(talloc, engine, "select coalesce(null, 7)", .compiled);
    defer constant_cursor.deinit();
    const constant_row = (try constant_cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 7), constant_row.values[0].integer);
    try std.testing.expect((try constant_cursor.next()) == null);

    var row_cursor = try executeWithMode(talloc, engine, "select coalesce(value, 0) as value_or_zero from coalesce.room1 where time >= 0 order by time asc limit 1", .compiled);
    defer row_cursor.deinit();
    const row = (try row_cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try row.values[0].asFloat(), 1e-9);
    try std.testing.expect((try row_cursor.next()) == null);
}

test "executeWithMode compiled supports ordering by hidden scan identifiers" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-hidden-order", .{tmp.sub_path});
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

    const sid: u64 = 7666;
    try engine.registerSeries("hidden.room1", "{\"host\":\"b\"}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.5, .tags_json = "{\"host\":\"b\"}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 3.0, .tags_json = "{\"host\":\"a\"}" });
    try waitForFlushForTest(engine, 1, 1_000);

    var time_cursor = try executeWithMode(talloc, engine, "select value from hidden.room1 where time >= 0 order by time desc limit 1", .compiled);
    defer time_cursor.deinit();
    const time_row = (try time_cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), try time_row.values[0].asFloat(), 1e-9);
    try std.testing.expect((try time_cursor.next()) == null);

    var value_cursor = try executeWithMode(talloc, engine, "select time from hidden.room1 where time >= 0 order by value desc limit 1", .compiled);
    defer value_cursor.deinit();
    const value_row = (try value_cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 20), value_row.values[0].integer);
    try std.testing.expect((try value_cursor.next()) == null);
}

test "executeWithMode compiled supports visible selector tag projections" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-tag-projection", .{tmp.sub_path});
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

    const sid: u64 = 7777;
    const tags_json = "{\"host\":\"a\"}";
    try engine.registerSeries("tagged.room1", tags_json, sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 4.5, .tags_json = tags_json });
    try waitForFlushForTest(engine, 1, 1_000);

    var cursor = try executeWithMode(talloc, engine, "select tag.host as host, value from tagged.room1 where time >= 0 order by time asc limit 1", .compiled);
    defer cursor.deinit();
    const row = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", row.values[0].string);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), try row.values[1].asFloat(), 1e-9);
    try std.testing.expect((try cursor.next()) == null);
}

test "executeWithMode compiled keeps fill clauses on the native physical path" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-fill-fallback", .{tmp.sub_path});
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

    const sid: u64 = 7444;
    try engine.registerSeries("filltest.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.5, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 70, .value = 2.0, .tags_json = "{}" });
    try waitForFlushForTest(engine, 1, 1_000);

    var cursor = try executeWithMode(
        talloc,
        engine,
        "select time_bucket(60, time) as bucket, avg(value) as avg_value from filltest.room1 where time >= 0 group by time_bucket(60, time) fill(previous) order by bucket desc",
        .compiled,
    );
    defer cursor.deinit();

    try std.testing.expectEqualStrings("compiled", cursor.stats.execution_mode);
    try std.testing.expect(!cursor.stats.legacy_fallback);
    try std.testing.expectEqualStrings("", cursor.stats.fallback_reason);
    try std.testing.expectEqual(@as(u64, 1), engine.metrics.query_compile_attempts_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), engine.metrics.query_compile_success_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), engine.metrics.query_compile_fallback_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), engine.metrics.query_compile_unsupported_total.load(.monotonic));

    const first = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 60), first.values[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), try first.values[1].asFloat(), 1e-9);
    const second = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), second.values[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try second.values[1].asFloat(), 1e-9);
    try std.testing.expect((try cursor.next()) == null);
}

test "executeWithMode compiled supports null fill on the native physical path" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-null-fill", .{tmp.sub_path});
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

    const sid: u64 = 7445;
    try engine.registerSeries("filltest.room2", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.5, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 130, .value = 4.0, .tags_json = "{}" });
    try waitForFlushForTest(engine, 1, 1_000);

    var cursor = try executeWithMode(
        talloc,
        engine,
        "select time_bucket(60, time) as bucket, avg(value) as avg_value from filltest.room2 where time >= 0 group by time_bucket(60, time) fill(null) order by bucket asc",
        .compiled,
    );
    defer cursor.deinit();

    try std.testing.expectEqualStrings("compiled", cursor.stats.execution_mode);
    try std.testing.expect(!cursor.stats.legacy_fallback);
    try std.testing.expectEqualStrings("", cursor.stats.fallback_reason);

    const first = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), first.values[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try first.values[1].asFloat(), 1e-9);
    const second = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 60), second.values[0].integer);
    try std.testing.expect(second.values[1] == .null);
    const third = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 120), third.values[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), try third.values[1].asFloat(), 1e-9);
    try std.testing.expect((try cursor.next()) == null);
}

test "executeWithMode compiled supports scalar alias ordering and first/last aggregates" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-stage4", .{tmp.sub_path});
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

    const sid: u64 = 7007;
    try engine.registerSeries("stage4.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.5, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try waitForFlushForTest(engine, 1, 1_000);

    var scalar_cursor = try executeWithMode(talloc, engine, "select pow(value, 2) as squared from stage4.room1 where time >= 0 order by squared desc limit 1", .compiled);
    defer scalar_cursor.deinit();

    const scalar_row = (try scalar_cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), try scalar_row.values[0].asFloat(), 1e-9);
    try std.testing.expect((try scalar_cursor.next()) == null);

    var aggregate_cursor = try executeWithMode(talloc, engine, "select first(value) as first_value, last(value) as last_value from stage4.room1 where time >= 0", .compiled);
    defer aggregate_cursor.deinit();

    const aggregate_row = (try aggregate_cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try aggregate_row.values[0].asFloat(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), try aggregate_row.values[1].asFloat(), 1e-9);
    try std.testing.expect((try aggregate_cursor.next()) == null);
}

test "executeWithMode compiled supports single-selector tag reads" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-tag-read", .{tmp.sub_path});
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

    const sid = @import("../types.zig").seriesIdFrom("tagged.room1", "{\"host\":\"web\",\"rack\":\"r1\"}");
    try engine.registerSeries("tagged.room1", "{\"host\":\"web\",\"rack\":\"r1\"}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{\"host\":\"web\",\"rack\":\"r1\"}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 3.0, .tags_json = "{\"host\":\"web\",\"rack\":\"r1\"}" });
    try waitForFlushForTest(engine, 1, 1_000);

    var cursor = try executeWithMode(
        talloc,
        engine,
        "select tag.host as host, avg(value) as avg_value from tagged.room1 where tag.host = 'web' group by tag.host",
        .compiled,
    );
    defer cursor.deinit();

    const row = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("web", row.values[0].string);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), try row.values[1].asFloat(), 1e-9);
    try std.testing.expect((try cursor.next()) == null);
    try std.testing.expect(!cursor.stats.legacy_fallback);
}

test "executeWithMode compiled supports time-bucket plus selector-tag grouping" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compiled-tag-buckets", .{tmp.sub_path});
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

    const tags = "{\"host\":\"web\",\"rack\":\"r1\"}";
    const sid = @import("../types.zig").seriesIdFrom("tagged.room1", tags);
    try engine.registerSeries("tagged.room1", tags, sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = tags });
    try engine.ingest(.{ .series_id = sid, .ts = 70, .value = 3.0, .tags_json = tags });
    try waitForFlushForTest(engine, 1, 1_000);

    var cursor = try executeWithMode(
        talloc,
        engine,
        "select time_bucket(60, time) as bucket, tag.host as host, max(value) as max_value from tagged.room1 where time >= 0 group by time_bucket(60, time), tag.host",
        .compiled,
    );
    defer cursor.deinit();

    const first = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), first.values[0].integer);
    try std.testing.expectEqualStrings("web", first.values[1].string);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), try first.values[2].asFloat(), 1e-9);

    const second = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 60), second.values[0].integer);
    try std.testing.expectEqualStrings("web", second.values[1].string);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), try second.values[2].asFloat(), 1e-9);

    try std.testing.expect((try cursor.next()) == null);
    try std.testing.expect(!cursor.stats.legacy_fallback);
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

test "compiled and legacy parity holds across metadata modes for public query classes" {
    const talloc = std.testing.allocator;
    const modes = [_]cfg.MetadataReadMode{ .legacy, .shadow, .primary };
    const queries = [_][]const u8{
        "select time, value from parity.room1 where time >= 0 order by time asc",
        "select max(value) as max_value from parity.room1 where time >= 0",
        "select time_bucket(60, time) as bucket, max(value) as max_value from parity.room1 where time >= 0 group by time_bucket(60, time) order by bucket asc",
        "select tag.host as host, avg(value) as avg_value from tagged.room1 where tag.host = 'web' group by tag.host",
    };

    for (modes) |mode| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/parity-{s}", .{ tmp.sub_path, @tagName(mode) });
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
            .cas_mode = .dual_write,
            .metadata_read_mode = mode,
            .query_compiler_mode = .compiled,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try engine_mod.Engine.init(talloc, config);
        defer engine.deinit();

        try seedParityDataset(engine);

        for (queries) |query| {
            const result = try shadowCompareSelect(talloc, engine, query);
            try std.testing.expect(result.matched);
            try std.testing.expect(result.rows_compared > 0);
        }

        try std.testing.expectEqual(@as(u64, 0), engine.metrics.cas_shadow_mismatch_total.load(.monotonic));
    }
}

test "execution snapshots stay stable for supported and fallback query classes" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/execution-snapshots", .{tmp.sub_path});
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
    try seedParityDataset(engine);

    var read_cursor = try executeWithMode(talloc, engine, "select time, value from parity.room1 where time >= 0 order by time asc", .compiled);
    defer read_cursor.deinit();
    const read_snapshot = try collectCursorContractSnapshot(talloc, &read_cursor);
    defer talloc.free(read_snapshot);
    try std.testing.expectEqualStrings(
        \\mode=compiled|legacy_fallback=false|fallback_reason=
        \\time|value
        \\10|1.5
        \\20|2
        \\70|3.5
        \\
    , read_snapshot);

    var aggregate_cursor = try executeWithMode(talloc, engine, "select time_bucket(60, time) as bucket, max(value) as max_value from parity.room1 where time >= 0 group by time_bucket(60, time) order by bucket asc", .compiled);
    defer aggregate_cursor.deinit();
    const aggregate_snapshot = try collectCursorContractSnapshot(talloc, &aggregate_cursor);
    defer talloc.free(aggregate_snapshot);
    try std.testing.expectEqualStrings(
        \\mode=compiled|legacy_fallback=false|fallback_reason=
        \\bucket|max_value
        \\0|2
        \\60|3.5
        \\
    , aggregate_snapshot);

    var selector_cursor = try executeWithMode(talloc, engine, "select tag.host as host, avg(value) as avg_value from tagged.room1 where tag.host = 'web' group by tag.host", .compiled);
    defer selector_cursor.deinit();
    const selector_snapshot = try collectCursorContractSnapshot(talloc, &selector_cursor);
    defer talloc.free(selector_snapshot);
    try std.testing.expectEqualStrings(
        \\mode=compiled|legacy_fallback=false|fallback_reason=
        \\host|avg_value
        \\web|2
        \\
    , selector_snapshot);

    var fallback_cursor = try executeWithMode(
        talloc,
        engine,
        "select time_bucket(60, time) as bucket, avg(value) as avg_value from parity.room1 where time >= 0 group by time_bucket(60, time) fill(linear) order by bucket desc",
        .compiled,
    );
    defer fallback_cursor.deinit();
    const fallback_snapshot = try collectCursorContractSnapshot(talloc, &fallback_cursor);
    defer talloc.free(fallback_snapshot);
    try std.testing.expectEqualStrings(
        \\mode=compiled|legacy_fallback=true|fallback_reason=unsupported_fill
        \\bucket|avg_value
        \\60|3.5
        \\0|1.75
        \\
    , fallback_snapshot);
}

fn waitForFlushForTest(engine: *engine_mod.Engine, min_flushes: u64, timeout_ms: u64) !void {
    var wait_timer = monotime.startTimer();
    const timeout_ns = monotime.timeoutNanos(timeout_ms);
    var first_attempt = true;
    while (true) {
        const elapsed_ns = wait_timer.read();
        if (!first_attempt and elapsed_ns >= timeout_ns) return error.Timeout;
        first_attempt = false;
        const remaining_ms = (timeout_ns -| elapsed_ns) / std.time.ns_per_ms;
        _ = try engine.flushAndDrain(remaining_ms);
        if (engine.metrics.flush_total.load(.monotonic) >= min_flushes) {
            if (engine.config.cas_mode == .dual_write) {
                try engine.verifyCasState();
                if (engine.cas) |*cas| {
                    engine.metadata.refreshCasIndexIfStale(cas) catch {
                        if (wait_timer.read() >= timeout_ns) return error.Timeout;
                        std.Thread.sleep(5 * std.time.ns_per_ms);
                        continue;
                    };
                }
            }
            return;
        }
        if (wait_timer.read() >= timeout_ns) return error.Timeout;
        if (@hasDecl(std.time, "sleep")) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        } else {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
}

test "waitForFlushForTest accepts already drained false flush result" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/query-flush-barrier-false", .{tmp.sub_path});
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

    const types = @import("../types.zig");
    const sid = types.seriesIdFrom("query.barrier.false", "{}");
    try engine.registerSeries("query.barrier.false", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 1, .value = 1.0, .tags_json = "{}" });
    try waitForFlushForTest(engine, 1, 1_000);

    const flushed_total = engine.metrics.flush_total.load(.monotonic);
    try std.testing.expect(!(try engine.flushAndDrain(0)));
    try waitForFlushForTest(engine, flushed_total, 0);
}

test "waitForFlushForTest waits through CAS snapshot publication" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/wait-for-flush-cas-publication", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = std.math.maxInt(u32),
        .memtable_max_bytes = std.math.maxInt(usize),
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .dual_write,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };
    var engine = try engine_mod.Engine.init(talloc, config);
    defer engine.deinit();

    const sid = try engine.declareExactSeriesCanonical("svc.flush_barrier", "{}", null);
    _ = try engine.appendResolvedPoint(.{ .series_id = sid, .ts = 7, .value = 3.5 });
    const ingest_deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
    while ((!engine.queue.isDrained() or engine.mem.bytes.load(.monotonic) == 0) and std.time.nanoTimestamp() < ingest_deadline) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(engine.queue.isDrained());
    try std.testing.expect(engine.mem.bytes.load(.monotonic) > 0);

    const TriggerContext = struct {
        engine: *engine_mod.Engine,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            _ = ctx.engine.flushAndDrain(5_000) catch |err| {
                ctx.failure = err;
                ctx.done.store(true, .release);
                return;
            };
            ctx.done.store(true, .release);
        }
    };
    const PollerContext = struct {
        engine: *engine_mod.Engine,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            waitForFlushForTest(ctx.engine, 1, 5_000) catch |err| {
                ctx.failure = err;
                ctx.done.store(true, .release);
                return;
            };
            ctx.done.store(true, .release);
        }
    };

    engine.wal.lockForSnapshot();
    var gate_held = true;
    var trigger_thread: ?std.Thread = null;
    var poller_thread: ?std.Thread = null;
    defer {
        if (gate_held) engine.wal.unlockForSnapshot();
        if (poller_thread) |thread| thread.join();
        if (trigger_thread) |thread| thread.join();
    }

    var trigger_context = TriggerContext{ .engine = engine };
    trigger_thread = try std.Thread.spawn(.{}, TriggerContext.run, .{&trigger_context});
    const publication_deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
    while (engine.metrics.flush_total.load(.monotonic) == 0 and std.time.nanoTimestamp() < publication_deadline) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(engine.metrics.flush_total.load(.monotonic) >= 1);

    engine.drain_mu.lock();
    const generation_before_poller = engine.drain_generation;
    const writer_still_publishing = engine.flush_in_progress;
    engine.drain_mu.unlock();
    try std.testing.expect(writer_still_publishing);

    var poller_context = PollerContext{ .engine = engine };
    poller_thread = try std.Thread.spawn(.{}, PollerContext.run, .{&poller_context});
    const barrier_deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
    var poller_barrier_observed = false;
    while (!poller_barrier_observed and std.time.nanoTimestamp() < barrier_deadline) {
        engine.drain_mu.lock();
        poller_barrier_observed = engine.drain_generation != generation_before_poller;
        engine.drain_mu.unlock();
        if (!poller_barrier_observed) std.Thread.sleep(std.time.ns_per_ms);
    }
    const poller_stayed_blocked = !poller_context.done.load(.acquire);

    engine.wal.unlockForSnapshot();
    gate_held = false;
    if (poller_thread) |thread| {
        thread.join();
        poller_thread = null;
    }
    if (trigger_thread) |thread| {
        thread.join();
        trigger_thread = null;
    }

    try std.testing.expect(poller_barrier_observed);
    try std.testing.expect(poller_stayed_blocked);
    try std.testing.expect(trigger_context.failure == null);
    try std.testing.expect(poller_context.failure == null);
}

fn seedParityDataset(engine: *engine_mod.Engine) !void {
    const types = @import("../types.zig");

    const raw_sid = types.seriesIdFrom("parity.room1", "{}");
    try engine.registerSeries("parity.room1", "{}", raw_sid);
    try engine.ingest(.{ .series_id = raw_sid, .ts = 10, .value = 1.5, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = raw_sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = raw_sid, .ts = 70, .value = 3.5, .tags_json = "{}" });

    const tagged_tags = "{\"host\":\"web\",\"rack\":\"r1\"}";
    const tagged_sid = types.seriesIdFrom("tagged.room1", tagged_tags);
    try engine.registerSeries("tagged.room1", tagged_tags, tagged_sid);
    engine.noteTags(tagged_sid, tagged_tags);
    try engine.ingest(.{ .series_id = tagged_sid, .ts = 10, .value = 1.0, .tags_json = tagged_tags });
    try engine.ingest(.{ .series_id = tagged_sid, .ts = 20, .value = 3.0, .tags_json = tagged_tags });

    try waitForFlushForTest(engine, 1, 1_000);
}

fn collectCursorSnapshot(alloc: std.mem.Allocator, cursor: *executor.ExecutionCursor) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(alloc);
    errdefer buffer.deinit();

    for (cursor.columns, 0..) |column, idx| {
        if (idx != 0) try buffer.append('|');
        try buffer.appendSlice(column.name);
    }
    try buffer.append('\n');

    while (try cursor.next()) |row| {
        for (row.values, 0..) |value, idx| {
            if (idx != 0) try buffer.append('|');
            try appendSnapshotValue(&buffer, value);
        }
        try buffer.append('\n');
    }

    return try buffer.toOwnedSlice();
}

fn collectCursorContractSnapshot(alloc: std.mem.Allocator, cursor: *executor.ExecutionCursor) ![]u8 {
    const rows_snapshot = try collectCursorSnapshot(alloc, cursor);
    defer alloc.free(rows_snapshot);

    return try std.fmt.allocPrint(
        alloc,
        "mode={s}|legacy_fallback={}|fallback_reason={s}\n{s}",
        .{ cursor.stats.execution_mode, cursor.stats.legacy_fallback, cursor.stats.fallback_reason, rows_snapshot },
    );
}

fn appendSnapshotValue(buffer: *std.array_list.Managed(u8), value: executor.Value) !void {
    switch (value) {
        .null => try buffer.appendSlice("null"),
        .boolean => |bool_value| try buffer.appendSlice(if (bool_value) "true" else "false"),
        .integer => |int_value| try buffer.writer().print("{d}", .{int_value}),
        .float => |float_value| try buffer.writer().print("{d}", .{float_value}),
        .string => |string_value| try buffer.appendSlice(string_value),
    }
}
