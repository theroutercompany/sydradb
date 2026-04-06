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
    mode: ExecutionMode,
) ExecuteError!executor.ExecutionCursor {
    const compile_start = std.time.microTimestamp();
    recordCompileAttempt(prepared.engine);
    const detailed = try compiler.compileSelectDetailed(prepared.arena_ptr.allocator(), prepared.engine, prepared.statement);
    const compile_end = std.time.microTimestamp();
    const compiled = detailed.compiled orelse return compiler.fallbackReasonToError(detailed.fallback_reason.?);
    recordCompileSuccess(prepared.engine);
    const total_compile_us = durationMicros(compile_end - compile_start);
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
    const pipeline_start = std.time.microTimestamp();
    var cursor = try exec_inst.run();
    const pipeline_end = std.time.microTimestamp();

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
        durationMicros(pipeline_end - pipeline_start),
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
    const pipeline_start = std.time.microTimestamp();
    while (true) {
        const step = try machine.step();
        switch (step) {
            .done => break,
            .row => |row| {
                const values = try arena.alloc(executor.Value, row.len);
                for (row, 0..) |value, idx| values[idx] = value;
                try row_list.append(values);
            },
        }
    }
    const rows = try arena.alloc([]executor.Value, row_list.items.len);
    @memcpy(rows, row_list.items);
    const columns = try arena.dupe(plan_builder.ColumnInfo, lowered_program.columns);
    var cursor = try executor.cursorFromRows(prepared.allocator, columns, rows);
    cursor.arena = prepared.arena_ptr;
    const pipeline_end = std.time.microTimestamp();

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
        durationMicros(pipeline_end - pipeline_start),
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
            return executeLegacy(prepared, mode, true, compiler_diagnostics.reasonName(reason));
        }
        return err;
    };
}

fn executeExplainBytecode(
    prepared: Prepared,
    mode: ExecutionMode,
    explain: *const ast.Explain,
) ExecuteError!executor.ExecutionCursor {
    const compile_start = std.time.microTimestamp();
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
    const compile_end = std.time.microTimestamp();

    try finalizeCursor(
        prepared,
        &cursor,
        mode,
        false,
        "",
        compiled.bind_us,
        durationMicros(compile_end - compile_start) -| compiled.bind_us,
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
        const compile_start = std.time.microTimestamp();
        recordCompileAttempt(prepared.engine);
        const detailed = compiler.compileSelectDetailed(prepared.arena_ptr.allocator(), prepared.engine, explain.target) catch |err| {
            if (compiler_diagnostics.fromCompileError(err)) |reason| {
                recordCompileFallback(prepared.engine, reason);
            }
            return err;
        };
        const compile_end = std.time.microTimestamp();
        bind_us = detailed.bind_us;
        if (detailed.compiled) |compiled| {
            recordCompileSuccess(prepared.engine);
            typed_query = compiled.typed_query;
            logical_us = compiled.backend.logical_us;
            optimize_us = compiled.backend.optimize_us;
            physical_us = compiled.backend.physical_us;
            const backend_us = logical_us + optimize_us + physical_us;
            compile_us = durationMicros(compile_end - compile_start) -| backend_us;
        } else if (detailed.fallback_reason) |reason| {
            recordCompileFallback(prepared.engine, reason);
            compile_us = durationMicros(compile_end - compile_start) -| bind_us;
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
    try std.testing.expectEqual(@as(usize, 8), cursor.columns.len);

    const first = try cursor.next();
    try std.testing.expect(first != null);
    try std.testing.expect(executor.Value.equals(first.?.values[0], executor.Value{ .integer = 0 }));
    try std.testing.expectEqualStrings("load_const", try first.?.values[1].asString());

    const second = try cursor.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("result_row", try second.?.values[1].asString());

    const third = try cursor.next();
    try std.testing.expect(third != null);
    try std.testing.expectEqualStrings("halt", try third.?.values[1].asString());
    try std.testing.expect((try cursor.next()) == null);
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
    try std.testing.expectEqual(@as(usize, 3), cursor.columns.len);

    const first = try cursor.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("series", try first.?.values[0].asString());
    try std.testing.expectEqualStrings("weather.room1", try first.?.values[1].asString());
    try std.testing.expect(executor.Value.equals(first.?.values[2], executor.Value{ .integer = 41 }));
    try std.testing.expect((try cursor.next()) == null);
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

test "executeWithMode compiled falls back to legacy and records metrics" {
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
    try std.testing.expect(cursor.stats.legacy_fallback);
    try std.testing.expectEqualStrings(@tagName(compiler_diagnostics.FallbackReason.unsupported_function), cursor.stats.fallback_reason);
    try std.testing.expectEqual(@as(u64, 1), engine.metrics.query_compile_attempts_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), engine.metrics.query_compile_success_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), engine.metrics.query_compile_fallback_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), engine.metrics.query_compile_unsupported_total.load(.monotonic));

    const first = try cursor.next();
    try std.testing.expect(first != null);
    try std.testing.expect(executor.Value.equals(first.?.values[0], executor.Value{ .float = 1.0 }));
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
            std.Thread.sleep(5 * std.time.ns_per_ms);
        } else {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
    return error.Timeout;
}
