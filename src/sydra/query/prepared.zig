const std = @import("std");

const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const codegen = @import("codegen.zig");
const compiler = @import("compiler.zig");
const engine_mod = @import("../engine.zig");
const exec = @import("exec.zig");
const frontend = @import("frontend.zig");
const common = @import("common.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const plan = @import("plan.zig");
const types = @import("../types.zig");
const value_mod = @import("value.zig");
const vm = @import("vm.zig");

pub const QueryLanguage = enum {
    sydraql,
    sql_core,
};

pub const PrepareFlags = packed struct(u8) {
    explain_bytecode: bool = false,
    shadow_compare: bool = false,
    reserved: u6 = 0,
};

pub const ParameterSlot = frontend.normalize.ParameterSlot;
pub const ParameterBinding = frontend.normalize.ParameterBinding;
pub const NamedParameterBinding = frontend.normalize.NamedParameterBinding;
pub const NormalizedStmt = frontend.normalize.NormalizedStmt;

pub const BindingContext = struct {
    language: QueryLanguage,
    source_text: []const u8,
    statement_kind: frontend.stmt.StatementKind,
    statement_span: common.Span,
    diagnostics: []const frontend.diagnostics.Diagnostic = &.{},
    parameters: []const ParameterBinding = &.{},
    named_parameters: []const NamedParameterBinding = &.{},
    translation_fallback: bool = false,

    pub fn parameterCount(self: @This()) usize {
        return self.parameters.len;
    }

    pub fn slotForNamed(self: @This(), name: []const u8) ?ParameterSlot {
        for (self.named_parameters) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding.slot;
        }
        return null;
    }
};

pub const StepResult = union(enum) {
    row: []const value_mod.Value,
    done,
};

pub const ShadowParityResult = struct {
    columns_match: bool,
    rows_match: bool,
    row_count: usize,
    mismatch_reason: []const u8 = "",
};

pub const TableUseKind = enum {
    series,
};

pub const TableUse = struct {
    kind: TableUseKind,
    name: []const u8,
    series_id: ?types.SeriesId = null,
};

pub const PreparedStmt = struct {
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    language: QueryLanguage,
    source_text: []const u8,
    flags: PrepareFlags,
    binding: BindingContext,
    program: bytecode.Program,
    columns: []const plan.ColumnInfo = &.{},
    normalized: NormalizedStmt,
    typed_query: ?compiler.TypedQuery = null,
    owned_columns: bool = false,
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    machine: ?vm.VirtualMachine = null,
    finalized: bool = false,

    pub fn step(self: *PreparedStmt) StepError!StepResult {
        if (self.finalized) return error.Finalized;
        if (self.machine) |*machine| {
            return switch (try machine.step()) {
                .row => |row| .{ .row = row },
                .done => .done,
            };
        }
        return error.NotImplemented;
    }

    pub fn reset(self: *PreparedStmt) void {
        if (self.machine) |*machine| machine.reset();
    }

    pub fn finalize(self: *PreparedStmt) void {
        if (self.finalized) return;
        if (self.machine) |*machine| machine.deinit();
        self.program.deinit();
        if (self.owned_columns and self.columns.len != 0) {
            self.allocator.free(self.columns);
        }
        if (self.arena_ptr) |arena_ptr| {
            arena_ptr.deinit();
            self.allocator.destroy(arena_ptr);
        }
        if (self.binding.diagnostics.len != 0) self.allocator.free(self.binding.diagnostics);
        self.finalized = true;
    }

    pub fn explainBytecode(self: *PreparedStmt, allocator: std.mem.Allocator) ![]bytecode.DisassemblyLine {
        return try bytecode.disassemble(allocator, self.program);
    }

    pub fn tablesUsed(self: *const PreparedStmt, allocator: std.mem.Allocator) ![]TableUse {
        var uses = std.array_list.Managed(TableUse).init(allocator);
        errdefer for (uses.items) |use| allocator.free(use.name);
        defer uses.deinit();

        if (self.typed_query) |typed_query| {
            if (typed_query.bound_selector) |selector| {
                try appendBoundSelectorTableUse(allocator, &uses, selector);
            } else if (typed_query.select.selector) |selector| {
                try appendAstSelectorTableUse(allocator, &uses, selector);
            }
        } else {
            try appendFrontendStatementTableUses(allocator, &uses, self.normalized.statement);
        }

        return try uses.toOwnedSlice();
    }
};

pub const PrepareError = std.mem.Allocator.Error || lexer.LexError || parser.ParseError || compiler.CompileError || frontend.normalize.NormalizeError || error{
    InvalidCharacter,
    NotImplemented,
    InvalidTrace,
} || codegen.CodegenError;

pub const StepError = vm.VmError || error{
    NotImplemented,
    Finalized,
};

pub fn freeTableUses(allocator: std.mem.Allocator, uses: []TableUse) void {
    for (uses) |use| {
        if (use.name.len != 0) allocator.free(use.name);
    }
    allocator.free(uses);
}

pub fn prepareSydraQL(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    text: []const u8,
    flags: PrepareFlags,
) PrepareError!PreparedStmt {
    var shadow = try frontend.shadow.parseSydraqlShadow(allocator, text);
    errdefer shadow.deinit();

    const normalized = if (shadow.generated_stmt) |generated_stmt|
        try frontend.normalize.normalizeFrontendStmt(shadow.arena_ptr.allocator(), generated_stmt)
    else
        try frontend.normalize.normalizeAstStatement(shadow.arena_ptr.allocator(), &shadow.statement);

    allocator.free(shadow.emitted.emitted_source);
    shadow.emitted.emitted_source = &.{};

    return try prepareNormalizedStatement(
        allocator,
        engine,
        .{
            .language = .sydraql,
            .source_text = text,
            .statement_kind = normalized.kind(),
            .statement_span = normalized.span(),
            .diagnostics = shadow.diagnostics,
            .parameters = normalized.parameters,
            .named_parameters = normalized.named_parameters,
            .translation_fallback = false,
        },
        flags,
        normalized,
        shadow.arena_ptr,
    );
}

pub fn prepareSqlCore(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    text: []const u8,
    flags: PrepareFlags,
) PrepareError!PreparedStmt {
    var skeleton = try frontend.sql_core.parseSqlCoreSkeleton(allocator, text);
    errdefer skeleton.deinit();

    if (skeleton.stmt) |stmt| {
        const arena_ptr = skeleton.arena_ptr orelse return error.NotImplemented;
        const normalized = try frontend.normalize.normalizeFrontendStmt(arena_ptr.allocator(), stmt);
        return try prepareNormalizedStatement(
            allocator,
            engine,
            .{
                .language = .sql_core,
                .source_text = text,
                .statement_kind = normalized.kind(),
                .statement_span = normalized.span(),
                .diagnostics = skeleton.diagnostics,
                .parameters = normalized.parameters,
                .named_parameters = normalized.named_parameters,
                .translation_fallback = false,
            },
            flags,
            normalized,
            arena_ptr,
        );
    }
    return error.NotImplemented;
}

pub fn shadowCompareSydraQL(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    text: []const u8,
) !ShadowParityResult {
    var prepared = try prepareSydraQL(allocator, engine, text, .{});
    defer prepared.finalize();

    var cursor = try exec.executeWithMode(allocator, engine, text, .compiled);
    defer cursor.deinit();

    if (prepared.columns.len != cursor.columns.len) {
        return .{ .columns_match = false, .rows_match = false, .row_count = 0, .mismatch_reason = "column_count" };
    }
    for (prepared.columns, 0..) |column, idx| {
        if (!std.mem.eql(u8, column.name, cursor.columns[idx].name)) {
            return .{ .columns_match = false, .rows_match = false, .row_count = 0, .mismatch_reason = "column_name" };
        }
    }

    var row_count: usize = 0;
    while (true) {
        const prepared_step = try prepared.step();
        const legacy_row = try cursor.next();
        if (prepared_step == .done and legacy_row == null) {
            return .{ .columns_match = true, .rows_match = true, .row_count = row_count };
        }
        if (prepared_step == .done or legacy_row == null) {
            return .{ .columns_match = true, .rows_match = false, .row_count = row_count, .mismatch_reason = "row_count" };
        }
        if (!valuesEqual(prepared_step.row, legacy_row.?.values)) {
            return .{ .columns_match = true, .rows_match = false, .row_count = row_count, .mismatch_reason = "row_values" };
        }
        row_count += 1;
    }
}

pub fn formatBytecodeSnapshot(allocator: std.mem.Allocator, stmt: *PreparedStmt) ![]u8 {
    const lines = try stmt.explainBytecode(allocator);
    defer bytecode.freeDisassembly(allocator, lines);

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (lines) |line| {
        try out.writer().print("{d}|{s}|{d}|{d}|{d}|{s}|{d}|{s}\n", .{
            line.pc,
            line.opcode,
            line.p1,
            line.p2,
            line.p3,
            line.p4,
            line.p5,
            line.comment,
        });
    }
    return try out.toOwnedSlice();
}

fn prepareNormalizedStatement(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    binding: BindingContext,
    flags: PrepareFlags,
    normalized: NormalizedStmt,
    arena_ptr: *std.heap.ArenaAllocator,
) PrepareError!PreparedStmt {
    var statement = try frontend.normalize.toAstStatement(arena_ptr.allocator(), normalized);
    const compiled = try compiler.compileSelect(arena_ptr.allocator(), engine, &statement);
    var lowered = try codegen.buildProgram(allocator, compiled);
    errdefer lowered.program.deinit();
    errdefer if (lowered.columns.len != 0) allocator.free(lowered.columns);

    var stmt = PreparedStmt{
        .allocator = allocator,
        .engine = engine,
        .language = binding.language,
        .source_text = binding.source_text,
        .flags = flags,
        .binding = binding,
        .program = lowered.program,
        .columns = lowered.columns,
        .normalized = normalized,
        .typed_query = compiled.typed_query,
        .owned_columns = true,
        .arena_ptr = arena_ptr,
    };
    stmt.machine = try vm.VirtualMachine.init(allocator, engine, &stmt.program);
    return stmt;
}

fn appendFrontendStatementTableUses(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    statement: frontend.normalize.Statement,
) !void {
    switch (statement) {
        .select => |select| {
            if (select.selector) |selector| {
                try appendFrontendSelectorTableUse(allocator, uses, selector);
            }
        },
        .insert => |insert| {
            try appendTableUse(allocator, uses, .series, insert.target.value, null);
        },
        .delete => |delete| {
            try appendTableUse(allocator, uses, .series, delete.target.value, null);
        },
        .explain => |explain| try appendFrontendStatementTableUses(allocator, uses, explain.target.*),
    }
}

fn appendBoundSelectorTableUse(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    selector: compiler.BoundSelector,
) !void {
    if (selector.name) |name| {
        try appendTableUse(allocator, uses, .series, name, selector.series_id);
        return;
    }

    const rendered = try std.fmt.allocPrint(allocator, "series_id:{d}", .{selector.series_id});
    errdefer allocator.free(rendered);
    for (uses.items) |existing| {
        if (existing.kind == .series and existing.series_id == selector.series_id and std.mem.eql(u8, existing.name, rendered)) {
            allocator.free(rendered);
            return;
        }
    }
    try appendOwnedTableUse(uses, .series, rendered, selector.series_id);
}

fn appendFrontendSelectorTableUse(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    selector: frontend.normalize.Selector,
) !void {
    switch (selector.series) {
        .name => |name| try appendTableUse(allocator, uses, .series, name.value, null),
        .by_id => |by_id| {
            const rendered = try std.fmt.allocPrint(allocator, "series_id:{d}", .{by_id.value});
            errdefer allocator.free(rendered);
            for (uses.items) |existing| {
                if (existing.kind == .series and existing.series_id == @as(types.SeriesId, @intCast(by_id.value)) and std.mem.eql(u8, existing.name, rendered)) {
                    allocator.free(rendered);
                    return;
                }
            }
            try appendOwnedTableUse(uses, .series, rendered, @intCast(by_id.value));
        },
    }
}

fn appendAstSelectorTableUse(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    selector: ast.Selector,
) !void {
    switch (selector.series) {
        .name => |name| try appendTableUse(allocator, uses, .series, name.value, null),
        .by_id => |by_id| {
            const rendered = try std.fmt.allocPrint(allocator, "series_id:{d}", .{by_id.value});
            errdefer allocator.free(rendered);
            for (uses.items) |existing| {
                if (existing.kind == .series and existing.series_id == @as(types.SeriesId, @intCast(by_id.value)) and std.mem.eql(u8, existing.name, rendered)) {
                    allocator.free(rendered);
                    return;
                }
            }
            try appendOwnedTableUse(uses, .series, rendered, @intCast(by_id.value));
        },
    }
}

fn appendTableUse(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    kind: TableUseKind,
    name: []const u8,
    series_id: ?types.SeriesId,
) !void {
    for (uses.items) |existing| {
        if (existing.kind == kind and existing.series_id == series_id and std.mem.eql(u8, existing.name, name)) {
            return;
        }
    }
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try appendOwnedTableUse(uses, kind, owned_name, series_id);
}

fn appendOwnedTableUse(
    uses: *std.array_list.Managed(TableUse),
    kind: TableUseKind,
    owned_name: []const u8,
    series_id: ?types.SeriesId,
) !void {
    try uses.append(.{
        .kind = kind,
        .name = owned_name,
        .series_id = series_id,
    });
}

test "prepared statement disassembles bytecode programs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-contracts", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../config.zig").Config = .{
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
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    const instructions = try alloc.dupe(bytecode.Instruction, &.{
        .{ .opcode = .load_const, .p1 = 0, .p4 = .{ .constant = 0 } },
        .{ .opcode = .result_row, .p1 = 0, .p2 = 1 },
        .{ .opcode = .halt },
    });
    var stmt = PreparedStmt{
        .allocator = alloc,
        .engine = engine,
        .language = .sydraql,
        .source_text = "select 1",
        .flags = .{},
        .program = .{
            .allocator = alloc,
            .instructions = instructions,
            .constants = try alloc.dupe(value_mod.Value, &.{value_mod.Value{ .integer = 1 }}),
            .source_name = "unit",
        },
        .binding = .{
            .language = .sydraql,
            .source_text = "select 1",
            .statement_kind = .select,
            .statement_span = .{ .start = 0, .end = 8 },
        },
        .normalized = .{
            .statement = .{
                .select = .{
                    .projections = &.{},
                    .span = .{ .start = 0, .end = 8 },
                },
            },
        },
    };
    stmt.machine = try vm.VirtualMachine.init(alloc, engine, &stmt.program);
    defer stmt.finalize();

    const lines = try stmt.explainBytecode(alloc);
    defer bytecode.freeDisassembly(alloc, lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("load_const", lines[0].opcode);
    const first = try stmt.step();
    try std.testing.expect(first == .row);
    try std.testing.expectEqual(@as(i64, 1), first.row[0].integer);
    try std.testing.expect((try stmt.step()) == .done);
    stmt.reset();
    const replay = try stmt.step();
    try std.testing.expect(replay == .row);
}

test "prepared statement reports tables used for constant and scan queries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-tables-used", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../config.zig").Config = .{
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
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var constant_stmt = try prepareSydraQL(alloc, engine, "select 1", .{});
    defer constant_stmt.finalize();
    const constant_uses = try constant_stmt.tablesUsed(alloc);
    defer freeTableUses(alloc, constant_uses);
    try std.testing.expectEqual(@as(usize, 0), constant_uses.len);

    try engine.registerSeries("weather.room1", "{}", 41);
    var scan_stmt = try prepareSydraQL(alloc, engine, "select time, value from weather.room1 where time >= 0", .{});
    defer scan_stmt.finalize();
    const scan_uses = try scan_stmt.tablesUsed(alloc);
    defer freeTableUses(alloc, scan_uses);
    try std.testing.expectEqual(@as(usize, 1), scan_uses.len);
    try std.testing.expectEqual(TableUseKind.series, scan_uses[0].kind);
    try std.testing.expectEqual(@as(?types.SeriesId, 41), scan_uses[0].series_id);
    try std.testing.expectEqualStrings("weather.room1", scan_uses[0].name);
}

test "prepareSydraQL compiles constant and scan statements to bytecode" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-compile", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../config.zig").Config = .{
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
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var constant_stmt = try prepareSydraQL(alloc, engine, "select 1", .{});
    defer constant_stmt.finalize();
    const constant_row = try constant_stmt.step();
    try std.testing.expect(constant_row == .row);
    try std.testing.expectEqual(@as(i64, 1), constant_row.row[0].integer);

    const sid = @import("../types.zig").seriesIdFrom("weather.room1", "{}");
    try engine.registerSeries("weather.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 42.5, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 1, 1_000);

    var scan_stmt = try prepareSydraQL(alloc, engine, "select time, value from weather.room1 where time >= 0", .{});
    defer scan_stmt.finalize();
    const first = try scan_stmt.step();
    try std.testing.expect(first == .row);
    try std.testing.expectEqual(@as(i64, 10), first.row[0].integer);
}

test "prepared VM supports scalar ordering and limit offset" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-order-limit", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../config.zig").Config = .{
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
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    const sid = @import("../types.zig").seriesIdFrom("stage3.room1", "{}");
    try engine.registerSeries("stage3.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.5, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 2, 1_000);

    var scalar_stmt = try prepareSydraQL(alloc, engine, "select pow(value, 2) as squared from stage3.room1 where time >= 0 order by squared desc limit 1", .{});
    defer scalar_stmt.finalize();
    const scalar_row = try scalar_stmt.step();
    try std.testing.expect(scalar_row == .row);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), try scalar_row.row[0].asFloat(), 1e-9);
    try std.testing.expect((try scalar_stmt.step()) == .done);

    var offset_stmt = try prepareSydraQL(alloc, engine, "select time, value from stage3.room1 where time >= 0 order by time asc limit 1 offset 1", .{});
    defer offset_stmt.finalize();
    const offset_row = try offset_stmt.step();
    try std.testing.expect(offset_row == .row);
    try std.testing.expectEqual(@as(i64, 20), offset_row.row[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), try offset_row.row[1].asFloat(), 1e-9);
    try std.testing.expect((try offset_stmt.step()) == .done);
}

test "prepared bytecode snapshots stay stable for constant and scan plans" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-snapshot", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../config.zig").Config = .{
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
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var constant_stmt = try prepareSydraQL(alloc, engine, "select 1", .{});
    defer constant_stmt.finalize();
    const constant_snapshot = try formatBytecodeSnapshot(alloc, &constant_stmt);
    defer alloc.free(constant_snapshot);
    try std.testing.expectEqualStrings(
        \\0|load_const|0|0|0|const[0]|0|_col0
        \\1|result_row|0|1|0|schema[0]|0|
        \\2|halt|0|0|0||0|
        \\
    , constant_snapshot);

    const sid = @import("../types.zig").seriesIdFrom("weather.room1", "{}");
    try engine.registerSeries("weather.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 42.5, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 1, 1_000);

    var scan_stmt = try prepareSydraQL(alloc, engine, "select time, value from weather.room1 where time >= 0", .{});
    defer scan_stmt.finalize();
    const scan_snapshot = try formatBytecodeSnapshot(alloc, &scan_stmt);
    defer alloc.free(scan_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, scan_snapshot, "open_series") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan_snapshot, "next_point") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan_snapshot, "compare") != null);
}

test "prepared VM matches compiled executor on supported queries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-parity", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../config.zig").Config = .{
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
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    const constant_parity = try shadowCompareSydraQL(alloc, engine, "select 1");
    try std.testing.expect(constant_parity.columns_match);
    try std.testing.expect(constant_parity.rows_match);

    const sid = @import("../types.zig").seriesIdFrom("compare.room1", "{}");
    try engine.registerSeries("compare.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 100, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 200, .value = 3.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 2, 1_000);

    const scan_parity = try shadowCompareSydraQL(alloc, engine, "select time, value from compare.room1 where time >= 0");
    try std.testing.expect(scan_parity.columns_match);
    try std.testing.expect(scan_parity.rows_match);
    try std.testing.expectEqual(@as(usize, 2), scan_parity.row_count);
}

test "prepareSqlCore translates SQL into prepared bytecode programs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-sql-core", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../config.zig").Config = .{
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
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var constant_stmt = try prepareSqlCore(alloc, engine, "SELECT 1", .{});
    defer constant_stmt.finalize();
    try std.testing.expectEqual(QueryLanguage.sql_core, constant_stmt.language);
    try std.testing.expectEqual(@as(usize, 0), constant_stmt.binding.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), constant_stmt.binding.parameterCount());
    const constant_row = try constant_stmt.step();
    try std.testing.expect(constant_row == .row);
    try std.testing.expectEqual(@as(i64, 1), constant_row.row[0].integer);

    const sid = @import("../types.zig").seriesIdFrom("weather.room1", "{}");
    try engine.registerSeries("weather.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 42.5, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 1, 1_000);

    var scan_stmt = try prepareSqlCore(alloc, engine, "SELECT time, value FROM weather.room1 WHERE time >= 0", .{});
    defer scan_stmt.finalize();
    const lines = try scan_stmt.explainBytecode(alloc);
    defer bytecode.freeDisassembly(alloc, lines);
    try std.testing.expect(lines.len >= 4);
    try std.testing.expectEqualStrings("open_series", lines[0].opcode);

    const scan_row = try scan_stmt.step();
    try std.testing.expect(scan_row == .row);
    try std.testing.expectEqual(@as(i64, 10), scan_row.row[0].integer);
}

test "prepareSqlCore reports uncovered SQL instead of translating implicitly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-sql-fallback", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config: @import("../config.zig").Config = .{
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
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    try std.testing.expectError(error.NotImplemented, prepareSqlCore(
        alloc,
        engine,
        "SELECT value FROM weather.room1 WHERE time >= 0 AND value <= 5",
        .{},
    ));
}

test "binding context tracks named parameter slots" {
    const binding: BindingContext = .{
        .language = .sql_core,
        .source_text = "SELECT value FROM weather.room1 WHERE time >= $1 AND value <= :cap",
        .statement_kind = .select,
        .statement_span = .{ .start = 0, .end = 61 },
        .parameters = &.{
            .{
                .slot = 1,
                .raw = "$1",
                .kind = .positional,
                .explicit_index = 1,
                .span = .{ .start = 41, .end = 43 },
            },
            .{
                .slot = 2,
                .raw = ":cap",
                .kind = .named,
                .name = "cap",
                .span = .{ .start = 57, .end = 61 },
            },
        },
        .named_parameters = &.{.{ .name = "cap", .slot = 2 }},
    };

    try std.testing.expectEqual(@as(usize, 2), binding.parameterCount());
    try std.testing.expectEqual(@as(?ParameterSlot, 2), binding.slotForNamed("cap"));
    try std.testing.expectEqual(@as(?ParameterSlot, null), binding.slotForNamed("missing"));
}

test "covered SQL and sydraql normalize to the same canonical statement shape" {
    const alloc = std.testing.allocator;
    const sydraql_text = "select value as reading from by_id(41) where time >= 1 limit 2 offset 1";
    const sql_text = "SELECT value AS reading FROM by_id(41) WHERE time >= 1 LIMIT 2 OFFSET 1";

    var shadow = try frontend.shadow.parseSydraqlShadow(alloc, sydraql_text);
    defer shadow.deinit();

    var skeleton = try frontend.sql_core.parseSqlCoreSkeleton(alloc, sql_text);
    defer skeleton.deinit();
    try std.testing.expect(skeleton.stmt != null);

    const sydraql_normalized = try frontend.normalize.normalizeAstStatement(shadow.arena_ptr.allocator(), &shadow.statement);
    const sql_normalized = try frontend.normalize.normalizeFrontendStmt(skeleton.arena_ptr.?.allocator(), skeleton.stmt.?);

    try expectNormalizedStatementEqual(sydraql_normalized.statement, sql_normalized.statement);
    try std.testing.expectEqual(@as(usize, 0), sydraql_normalized.parameters.len);
    try std.testing.expectEqual(@as(usize, 0), sql_normalized.parameters.len);
}

fn valuesEqual(lhs: []const value_mod.Value, rhs: []const value_mod.Value) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, 0..) |value, idx| {
        if (!value_mod.Value.equals(value, rhs[idx])) return false;
    }
    return true;
}

fn expectNormalizedStatementEqual(expected: frontend.normalize.Statement, actual: frontend.normalize.Statement) !void {
    try std.testing.expectEqual(expected.kind(), actual.kind());
    switch (expected) {
        .select => |lhs| {
            try std.testing.expect(actual == .select);
            const rhs = actual.select;
            try std.testing.expectEqual(lhs.selector != null, rhs.selector != null);
            if (lhs.selector) |selector| {
                try std.testing.expect(rhs.selector != null);
                try expectNormalizedSelectorEqual(selector, rhs.selector.?);
            }
            try std.testing.expectEqual(lhs.projections.len, rhs.projections.len);
            for (lhs.projections, rhs.projections) |left, right| {
                try expectNormalizedExprEqual(left.expr, right.expr);
                try std.testing.expectEqual(left.alias != null, right.alias != null);
                if (left.alias) |alias| {
                    try std.testing.expect(right.alias != null);
                    try std.testing.expectEqualStrings(alias.value, right.alias.?.value);
                }
            }
            try std.testing.expectEqual(lhs.predicate != null, rhs.predicate != null);
            if (lhs.predicate) |predicate| {
                try std.testing.expect(rhs.predicate != null);
                try expectNormalizedExprEqual(predicate, rhs.predicate.?);
            }
            try std.testing.expectEqual(lhs.limit != null, rhs.limit != null);
            if (lhs.limit) |limit| {
                try std.testing.expect(rhs.limit != null);
                try std.testing.expectEqual(limit.limit, rhs.limit.?.limit);
                try std.testing.expectEqual(limit.offset, rhs.limit.?.offset);
            }
        },
        .insert => |lhs| {
            try std.testing.expect(actual == .insert);
            const rhs = actual.insert;
            try std.testing.expectEqualStrings(lhs.target.value, rhs.target.value);
            try std.testing.expectEqual(lhs.columns.len, rhs.columns.len);
            try std.testing.expectEqual(lhs.values.len, rhs.values.len);
        },
        .delete => |lhs| {
            try std.testing.expect(actual == .delete);
            const rhs = actual.delete;
            try std.testing.expectEqualStrings(lhs.target.value, rhs.target.value);
            try std.testing.expectEqual(lhs.predicate != null, rhs.predicate != null);
        },
        .explain => |lhs| {
            try std.testing.expect(actual == .explain);
            const rhs = actual.explain;
            try std.testing.expectEqual(lhs.mode, rhs.mode);
            try expectNormalizedStatementEqual(lhs.target.*, rhs.target.*);
        },
    }
}

fn expectNormalizedSelectorEqual(expected: frontend.normalize.Selector, actual: frontend.normalize.Selector) !void {
    switch (expected.series) {
        .name => |name| {
            try std.testing.expect(actual.series == .name);
            try std.testing.expectEqualStrings(name.value, actual.series.name.value);
        },
        .by_id => |by_id| {
            try std.testing.expect(actual.series == .by_id);
            try std.testing.expectEqual(by_id.value, actual.series.by_id.value);
        },
    }
}

fn expectNormalizedExprEqual(expected: *const frontend.normalize.Expr, actual: *const frontend.normalize.Expr) !void {
    switch (expected.*) {
        .identifier => |identifier| {
            try std.testing.expect(actual.* == .identifier);
            try std.testing.expectEqualStrings(identifier.value, actual.identifier.value);
        },
        .integer => |integer| {
            try std.testing.expect(actual.* == .integer);
            try std.testing.expectEqual(integer.value, actual.integer.value);
        },
        .string => |string| {
            try std.testing.expect(actual.* == .string);
            try std.testing.expectEqualStrings(string.value, actual.string.value);
        },
        .parameter => |parameter| {
            try std.testing.expect(actual.* == .parameter);
            try std.testing.expectEqual(parameter.kind, actual.parameter.kind);
            try std.testing.expectEqualStrings(parameter.raw, actual.parameter.raw);
        },
        .comparison => |comparison| {
            try std.testing.expect(actual.* == .comparison);
            try std.testing.expectEqual(comparison.op, actual.comparison.op);
            try expectNormalizedExprEqual(comparison.left, actual.comparison.left);
            try expectNormalizedExprEqual(comparison.right, actual.comparison.right);
        },
        .call => |call| {
            try std.testing.expect(actual.* == .call);
            try std.testing.expectEqualStrings(call.callee.value, actual.call.callee.value);
            try std.testing.expectEqual(call.args.len, actual.call.args.len);
            for (call.args, actual.call.args) |left, right| {
                try expectNormalizedExprEqual(left, right);
            }
        },
    }
}

fn waitForQueryablePoints(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    series_id: @import("../types.zig").SeriesId,
    expected_count: usize,
    timeout_ms: u64,
) !void {
    const deadline_ns = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
    while (std.time.nanoTimestamp() <= deadline_ns) {
        var points = std.array_list.Managed(@import("../types.zig").Point).init(allocator);
        defer points.deinit();

        try engine.queryRange(series_id, std.math.minInt(i64), std.math.maxInt(i64), &points);
        if (points.items.len >= expected_count) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.NotImplemented;
}
