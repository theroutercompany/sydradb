const std = @import("std");

const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const codegen = @import("codegen.zig");
const compiler = @import("compiler.zig");
const engine_mod = @import("../engine.zig");
const frontend = @import("frontend.zig");
const parser = @import("parser.zig");
const plan = @import("plan.zig");
const translator = @import("translator.zig");
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

pub const NormalizedStmt = union(enum) {
    ast_statement: *const ast.Statement,
    typed_query: compiler.TypedQuery,
};

pub const BindingContext = struct {
    language: QueryLanguage,
    source_text: []const u8,
    diagnostics: []const frontend.diagnostics.Diagnostic = &.{},
};

pub const StepResult = union(enum) {
    row: []const value_mod.Value,
    done,
};

pub const PreparedStmt = struct {
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    language: QueryLanguage,
    source_text: []const u8,
    flags: PrepareFlags,
    program: bytecode.Program,
    columns: []const plan.ColumnInfo = &.{},
    normalized: NormalizedStmt,
    diagnostics: []const frontend.diagnostics.Diagnostic = &.{},
    owned_source_text: bool = false,
    owned_statement: ?*const ast.Statement = null,
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    machine: ?vm.VirtualMachine = null,
    finalized: bool = false,

    pub fn step(self: *PreparedStmt) StepError!StepResult {
        if (self.finalized) return error.Finalized;
        var machine = &(self.machine orelse return error.NotImplemented);
        return switch (try machine.step()) {
            .row => |row| .{ .row = row },
            .done => .done,
        };
    }

    pub fn reset(self: *PreparedStmt) void {
        if (self.machine) |*machine| machine.reset();
    }

    pub fn finalize(self: *PreparedStmt) void {
        if (self.finalized) return;
        if (self.machine) |*machine| machine.deinit();
        self.program.deinit();
        if (self.owned_source_text) {
            self.allocator.free(self.source_text);
        }
        if (self.owned_statement) |stmt| {
            self.allocator.destroy(@constCast(stmt));
        }
        if (self.arena_ptr) |arena_ptr| {
            arena_ptr.deinit();
            self.allocator.destroy(arena_ptr);
        }
        if (self.diagnostics.len != 0) self.allocator.free(self.diagnostics);
        self.finalized = true;
    }

    pub fn explainBytecode(self: *PreparedStmt, allocator: std.mem.Allocator) ![]bytecode.DisassemblyLine {
        return try bytecode.disassemble(allocator, self.program);
    }
};

pub const PrepareError = std.mem.Allocator.Error || parser.ParseError || compiler.CompileError || error{
    SqlTranslationFailed,
    NotImplemented,
};

pub const StepError = vm.VmError || error{
    NotImplemented,
    Finalized,
};

pub fn prepareSydraQL(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    text: []const u8,
    flags: PrepareFlags,
) PrepareError!PreparedStmt {
    var arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_ptr.deinit();
        allocator.destroy(arena_ptr);
    }

    var parser_inst = parser.Parser.init(arena_ptr.allocator(), text);
    var statement = try parser_inst.parse();
    const compiled = try compiler.compileSelect(arena_ptr.allocator(), engine, &statement);
    const lowered = try codegen.buildProgram(allocator, compiled);

    var stmt = PreparedStmt{
        .allocator = allocator,
        .engine = engine,
        .language = .sydraql,
        .source_text = text,
        .flags = flags,
        .program = lowered.program,
        .columns = lowered.columns,
        .normalized = .{ .typed_query = compiled.typed_query },
        .arena_ptr = arena_ptr,
    };
    stmt.machine = try vm.VirtualMachine.init(allocator, engine, &stmt.program);
    return stmt;
}

pub fn prepareSqlCore(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    text: []const u8,
    flags: PrepareFlags,
) PrepareError!PreparedStmt {
    const translation = try translateSqlToSydraql(allocator, text);
    errdefer allocator.free(translation);
    const stmt = try allocator.create(ast.Statement);
    errdefer allocator.destroy(stmt);
    stmt.* = ast.placeholderStatement(.{ .start = 0, .end = 0 });
    return PreparedStmt{
        .allocator = allocator,
        .engine = engine,
        .language = .sql_core,
        .source_text = translation,
        .flags = flags,
        .program = .{
            .allocator = allocator,
            .instructions = try allocator.alloc(bytecode.Instruction, 0),
            .source_name = "sql_core",
        },
        .normalized = .{ .ast_statement = stmt },
        .owned_source_text = true,
        .owned_statement = stmt,
    };
}

fn translateSqlToSydraql(allocator: std.mem.Allocator, text: []const u8) PrepareError![]const u8 {
    const translated = try translator.translate(allocator, text);
    return switch (translated) {
        .success => |payload| payload.sydraql,
        .failure => error.SqlTranslationFailed,
    };
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
    const placeholder_stmt = try alloc.create(ast.Statement);
    placeholder_stmt.* = ast.placeholderStatement(.{ .start = 0, .end = 0 });

    const instructions = try alloc.dupe(bytecode.Instruction, &.{
        .{ .opcode = .load_const, .p1 = 0, .p4 = .{ .constant = 0 } },
        .{ .opcode = .halt },
    });
    var stmt = PreparedStmt{
        .allocator = alloc,
        .engine = &engine,
        .language = .sydraql,
        .source_text = "select 1",
        .flags = .{},
        .program = .{
            .allocator = alloc,
            .instructions = instructions,
            .constants = try alloc.dupe(value_mod.Value, &.{value_mod.Value{ .integer = 1 }}),
            .source_name = "unit",
        },
        .normalized = .{ .ast_statement = placeholder_stmt },
        .owned_statement = placeholder_stmt,
    };
    stmt.machine = try vm.VirtualMachine.init(alloc, &engine, &stmt.program);
    defer stmt.finalize();

    const lines = try stmt.explainBytecode(alloc);
    defer bytecode.freeDisassembly(alloc, lines);

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("load_const", lines[0].opcode);
    const first = try stmt.step();
    try std.testing.expect(first == .row);
    try std.testing.expectEqual(@as(i64, 1), first.row[0].integer);
    try std.testing.expect((try stmt.step()) == .done);
    stmt.reset();
    const replay = try stmt.step();
    try std.testing.expect(replay == .row);
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

    var constant_stmt = try prepareSydraQL(alloc, &engine, "select 1", .{});
    defer constant_stmt.finalize();
    const constant_row = try constant_stmt.step();
    try std.testing.expect(constant_row == .row);
    try std.testing.expectEqual(@as(i64, 1), constant_row.row[0].integer);

    const sid = @import("../types.zig").seriesIdFrom("weather.room1", "{}");
    try engine.registerSeries("weather.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 42.5, .tags_json = try alloc.dupe(u8, "{}") });
    std.time.sleep(20 * std.time.ns_per_ms);

    var scan_stmt = try prepareSydraQL(alloc, &engine, "select time, value from weather.room1 where time >= 0", .{});
    defer scan_stmt.finalize();
    const first = try scan_stmt.step();
    try std.testing.expect(first == .row);
    try std.testing.expectEqual(@as(i64, 10), first.row[0].integer);
}
