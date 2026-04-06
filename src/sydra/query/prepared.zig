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
const query_functions = @import("functions.zig");
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
    parameter_descriptions: []const ParameterDescription = &.{},
    translation_fallback: bool = false,
    generated_frontend_used: bool = false,
    fallback_reason: ?[]const u8 = null,

    pub fn parameterCount(self: @This()) usize {
        return self.parameters.len;
    }

    pub fn maxParameterSlot(self: @This()) ParameterSlot {
        if (self.parameter_descriptions.len != 0) return self.parameter_descriptions.len;
        var max_slot: ParameterSlot = 0;
        for (self.parameters) |binding| {
            if (binding.slot > max_slot) max_slot = binding.slot;
        }
        return max_slot;
    }

    pub fn hasSlot(self: @This(), slot: ParameterSlot) bool {
        for (self.parameters) |binding| {
            if (binding.slot == slot) return true;
        }
        return false;
    }

    pub fn slotForNamed(self: @This(), name: []const u8) ?ParameterSlot {
        for (self.named_parameters) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding.slot;
        }
        return null;
    }
};

pub const ParameterDescription = struct {
    slot: ParameterSlot,
    present: bool = false,
    raw: []const u8 = "",
    kind: frontend.stmt.ParameterKind = .positional,
    name: ?[]const u8 = null,
    explicit_index: ?u32 = null,
    span: common.Span = .{ .start = 0, .end = 0 },
    occurrences: usize = 0,
    inferred_type: query_functions.Type = query_functions.Type.init(.any, true),

    pub fn pgOid(self: @This()) u32 {
        if (!self.present) return 0;
        return switch (self.inferred_type.tag) {
            .boolean => 16,
            .integer, .duration, .timestamp => 20,
            .float => 701,
            .string, .tags => 25,
            .numeric, .value, .null, .any => 0,
        };
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

pub const StatementCapability = struct {
    kind: frontend.stmt.StatementKind,
    produces_rows: bool,
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
    described_columns: []const plan.ColumnInfo = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    compile_arena_ptr: ?*std.heap.ArenaAllocator = null,
    describe_compile_arena_ptr: ?*std.heap.ArenaAllocator = null,
    bound_values: []?value_mod.Value = &.{},
    needs_compile: bool = false,
    machine: ?vm.VirtualMachine = null,
    finalized: bool = false,

    pub fn step(self: *PreparedStmt) StepError!StepResult {
        if (self.finalized) return error.Finalized;
        try self.ensureCompiled();
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

    pub fn bindPositional(self: *PreparedStmt, slot: ParameterSlot, value: value_mod.Value) BindError!void {
        if (self.finalized) return error.Finalized;
        if (slot == 0 or slot > self.bound_values.len) return error.InvalidSlot;
        try self.replaceBoundValue(slot - 1, value);
        self.invalidateCompiledState();
    }

    pub fn bindNamed(self: *PreparedStmt, name: []const u8, value: value_mod.Value) BindError!void {
        if (self.finalized) return error.Finalized;
        const slot = self.binding.slotForNamed(name) orelse return error.UnknownParameter;
        try self.replaceBoundValue(slot - 1, value);
        self.invalidateCompiledState();
    }

    pub fn clearBindings(self: *PreparedStmt) void {
        for (self.bound_values) |*slot| {
            freeBoundValueStorage(self.allocator, slot.*);
            slot.* = null;
        }
        self.invalidateCompiledState();
    }

    pub fn finalize(self: *PreparedStmt) void {
        if (self.finalized) return;
        self.clearCompiledState();
        if (self.source_text.len != 0) self.allocator.free(@constCast(self.source_text));
        if (self.described_columns.len != 0) {
            self.allocator.free(self.described_columns);
        }
        if (self.describe_compile_arena_ptr) |arena_ptr| {
            arena_ptr.deinit();
            self.allocator.destroy(arena_ptr);
        }
        if (self.arena_ptr) |arena_ptr| {
            arena_ptr.deinit();
            self.allocator.destroy(arena_ptr);
        }
        if (self.bound_values.len != 0) {
            for (self.bound_values) |value| freeBoundValueStorage(self.allocator, value);
            self.allocator.free(self.bound_values);
        }
        freeParameterDescriptions(self.allocator, self.binding.parameter_descriptions);
        if (self.binding.diagnostics.len != 0) self.allocator.free(self.binding.diagnostics);
        self.finalized = true;
    }

    pub fn cloneForExecution(
        self: *const PreparedStmt,
        allocator: std.mem.Allocator,
        engine: *engine_mod.Engine,
    ) CloneError!PreparedStmt {
        if (self.finalized) return error.Finalized;

        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_ptr.deinit();

        const normalized = try frontend.normalize.cloneNormalizedStmt(arena_ptr.allocator(), self.normalized);
        const diagnostics = if (self.binding.diagnostics.len == 0)
            &.{}
        else
            try allocator.dupe(frontend.diagnostics.Diagnostic, self.binding.diagnostics);
        errdefer if (diagnostics.len != 0) allocator.free(diagnostics);

        return try prepareNormalizedStatement(
            allocator,
            engine,
            .{
                .language = self.language,
                .source_text = self.source_text,
                .statement_kind = normalized.kind(),
                .statement_span = normalized.span(),
                .diagnostics = diagnostics,
                .parameters = normalized.parameters,
                .named_parameters = normalized.named_parameters,
                .translation_fallback = self.binding.translation_fallback,
                .generated_frontend_used = self.binding.generated_frontend_used,
                .fallback_reason = self.binding.fallback_reason,
            },
            self.flags,
            normalized,
            arena_ptr,
        );
    }

    pub fn explainBytecode(self: *PreparedStmt, allocator: std.mem.Allocator) ExplainError![]bytecode.DisassemblyLine {
        if (self.finalized) return error.Finalized;
        try self.ensureCompiled();
        return try bytecode.disassemble(allocator, self.program);
    }

    pub fn describeColumns(self: *PreparedStmt) ExplainError![]const plan.ColumnInfo {
        if (self.finalized) return error.Finalized;
        try self.ensureColumnDescriptions();
        if (self.columns.len != 0) return self.columns;
        return self.described_columns;
    }

    pub fn describeParameters(self: *const PreparedStmt) error{Finalized}![]const ParameterDescription {
        if (self.finalized) return error.Finalized;
        return self.binding.parameter_descriptions;
    }

    pub fn statementKind(self: *const PreparedStmt) frontend.stmt.StatementKind {
        return self.binding.statement_kind;
    }

    pub fn capability(self: *const PreparedStmt) StatementCapability {
        return .{
            .kind = self.binding.statement_kind,
            .produces_rows = statementKindProducesRows(self.binding.statement_kind),
        };
    }

    pub fn coverageUsed(self: *const PreparedStmt) bool {
        return self.binding.generated_frontend_used;
    }

    pub fn fallbackReason(self: *const PreparedStmt) ?[]const u8 {
        return self.binding.fallback_reason;
    }

    pub fn producesRows(self: *const PreparedStmt) bool {
        return statementKindProducesRows(self.binding.statement_kind);
    }

    pub fn rowsAffected(self: *const PreparedStmt) usize {
        if (self.machine) |machine| return machine.rowsAffected();
        return 0;
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

    fn ensureCompiled(self: *PreparedStmt) PrepareError!void {
        if (!self.needs_compile and self.machine != null) return;
        var compiled = try compilePreparedExecutable(
            self.allocator,
            self.engine,
            self.normalized,
            self.bound_values,
        );
        errdefer {
            compiled.program.deinit();
            if (compiled.columns.len != 0) self.allocator.free(compiled.columns);
            compiled.compile_arena_ptr.deinit();
            self.allocator.destroy(compiled.compile_arena_ptr);
        }

        var machine = try vm.VirtualMachine.init(self.allocator, self.engine, &compiled.program);
        errdefer machine.deinit();

        self.clearCompiledState();
        self.program = compiled.program;
        self.columns = compiled.columns;
        self.typed_query = compiled.typed_query;
        self.owned_columns = true;
        self.compile_arena_ptr = compiled.compile_arena_ptr;
        self.machine = machine;
        self.needs_compile = false;
    }

    fn ensureColumnDescriptions(self: *PreparedStmt) PrepareError!void {
        if (self.columns.len != 0 or self.described_columns.len != 0) return;
        if (self.binding.maxParameterSlot() == 0) {
            try self.ensureCompiled();
            return;
        }

        const placeholder_bindings = try self.allocator.alloc(?value_mod.Value, self.bound_values.len);
        defer self.allocator.free(placeholder_bindings);
        for (placeholder_bindings) |*slot| slot.* = .null;

        var compiled = try compilePreparedExecutable(
            self.allocator,
            self.engine,
            self.normalized,
            placeholder_bindings,
        );
        errdefer {
            compiled.program.deinit();
            if (compiled.columns.len != 0) self.allocator.free(compiled.columns);
            compiled.compile_arena_ptr.deinit();
            self.allocator.destroy(compiled.compile_arena_ptr);
        }

        compiled.program.deinit();
        self.described_columns = compiled.columns;
        self.describe_compile_arena_ptr = compiled.compile_arena_ptr;
    }

    fn replaceBoundValue(self: *PreparedStmt, slot_idx: usize, value: value_mod.Value) BindError!void {
        freeBoundValueStorage(self.allocator, self.bound_values[slot_idx]);
        self.bound_values[slot_idx] = try cloneBoundValue(self.allocator, value);
    }

    fn invalidateCompiledState(self: *PreparedStmt) void {
        self.clearCompiledState();
        self.needs_compile = self.binding.parameterCount() != 0;
    }

    fn clearCompiledState(self: *PreparedStmt) void {
        if (self.machine) |*machine| machine.deinit();
        self.machine = null;
        self.program.deinit();
        self.program = emptyProgram(self.allocator);
        if (self.owned_columns and self.columns.len != 0) {
            self.allocator.free(self.columns);
        }
        self.columns = &.{};
        self.owned_columns = false;
        if (self.compile_arena_ptr) |arena_ptr| {
            arena_ptr.deinit();
            self.allocator.destroy(arena_ptr);
        }
        self.compile_arena_ptr = null;
        self.typed_query = null;
    }
};

pub const PrepareError = std.mem.Allocator.Error || lexer.LexError || parser.ParseError || compiler.CompileError || frontend.normalize.NormalizeError || error{
    InvalidCharacter,
    NotImplemented,
    InvalidTrace,
} || codegen.CodegenError;

pub const StepError = vm.VmError || PrepareError || error{
    NotImplemented,
    Finalized,
};

pub const ExplainError = PrepareError || error{
    Finalized,
};

pub const BindError = std.mem.Allocator.Error || error{
    Finalized,
    InvalidSlot,
    UnknownParameter,
};

pub const CloneError = PrepareError || error{
    Finalized,
};

pub fn freeTableUses(allocator: std.mem.Allocator, uses: []TableUse) void {
    for (uses) |use| {
        if (use.name.len != 0) allocator.free(use.name);
    }
    allocator.free(uses);
}

fn statementKindProducesRows(kind: frontend.stmt.StatementKind) bool {
    return switch (kind) {
        .select, .explain => true,
        .insert, .delete => false,
    };
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
            .generated_frontend_used = shadow.generated_stmt != null,
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
                .generated_frontend_used = skeleton.used_generated_runtime,
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
    binding_in: BindingContext,
    flags: PrepareFlags,
    normalized: NormalizedStmt,
    arena_ptr: *std.heap.ArenaAllocator,
) PrepareError!PreparedStmt {
    var binding = binding_in;
    const owned_source_text = try allocator.dupe(u8, binding_in.source_text);
    errdefer allocator.free(owned_source_text);
    binding.source_text = owned_source_text;
    binding.parameter_descriptions = try buildParameterDescriptions(allocator, normalized);
    errdefer freeParameterDescriptions(allocator, binding.parameter_descriptions);

    const max_slot = binding.maxParameterSlot();
    var bound_values: []?value_mod.Value = &.{};
    if (max_slot != 0) {
        bound_values = try allocator.alloc(?value_mod.Value, max_slot);
        for (bound_values) |*slot| slot.* = null;
    }
    errdefer if (max_slot != 0) allocator.free(bound_values);

    var stmt = PreparedStmt{
        .allocator = allocator,
        .engine = engine,
        .language = binding.language,
        .source_text = owned_source_text,
        .flags = flags,
        .binding = binding,
        .program = emptyProgram(allocator),
        .columns = &.{},
        .normalized = normalized,
        .arena_ptr = arena_ptr,
        .bound_values = bound_values,
        .needs_compile = binding.parameterCount() != 0,
    };
    if (!stmt.needs_compile) {
        try stmt.ensureCompiled();
    }
    return stmt;
}

const CompiledPreparedExecutable = struct {
    program: bytecode.Program,
    columns: []const plan.ColumnInfo,
    typed_query: ?compiler.TypedQuery = null,
    compile_arena_ptr: *std.heap.ArenaAllocator,
};

fn compilePreparedExecutable(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    normalized: NormalizedStmt,
    bindings: []const ?value_mod.Value,
) PrepareError!CompiledPreparedExecutable {
    const compile_arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(compile_arena_ptr);
    compile_arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer compile_arena_ptr.deinit();

    var statement = try frontend.normalize.toAstStatementWithBindings(compile_arena_ptr.allocator(), normalized, bindings);
    switch (statement) {
        .select => {
            const compiled = try compiler.compileSelect(compile_arena_ptr.allocator(), engine, &statement);
            var lowered = try codegen.buildProgram(allocator, compiled);
            errdefer lowered.program.deinit();
            errdefer if (lowered.columns.len != 0) allocator.free(lowered.columns);

            return .{
                .program = lowered.program,
                .columns = lowered.columns,
                .typed_query = compiled.typed_query,
                .compile_arena_ptr = compile_arena_ptr,
            };
        },
        .insert => |insert_stmt| return try buildInsertPreparedExecutable(allocator, compile_arena_ptr, insert_stmt),
        .delete => |delete_stmt| return try buildDeletePreparedExecutable(allocator, engine, compile_arena_ptr, delete_stmt),
        else => return error.NotImplemented,
    }
}

fn buildInsertPreparedExecutable(
    allocator: std.mem.Allocator,
    compile_arena_ptr: *std.heap.ArenaAllocator,
    insert_stmt: *const ast.Insert,
) PrepareError!CompiledPreparedExecutable {
    const mapped = try resolveInsertColumnExprs(insert_stmt);
    const series_id = types.seriesIdFrom(insert_stmt.series.value, "{}");

    const instructions = try allocator.dupe(bytecode.Instruction, &.{
        .{
            .opcode = .insert_point,
            .p1 = 0,
            .p2 = 1,
            .p4 = .{ .write_target = 0 },
            .comment = insert_stmt.series.value,
        },
        .{ .opcode = .halt },
    });
    errdefer allocator.free(instructions);

    const exprs = try allocator.dupe(*const ast.Expr, &.{ mapped.time_expr, mapped.value_expr });
    errdefer allocator.free(exprs);

    const write_targets = try allocator.dupe(bytecode.WriteTarget, &.{.{
        .series_id = series_id,
        .series_name = insert_stmt.series.value,
        .tags_json = "{}",
    }});
    errdefer allocator.free(write_targets);

    return .{
        .program = .{
            .allocator = allocator,
            .instructions = instructions,
            .exprs = exprs,
            .write_targets = write_targets,
            .register_count = 1,
            .source_name = "prepared_insert",
        },
        .columns = &.{},
        .typed_query = null,
        .compile_arena_ptr = compile_arena_ptr,
    };
}

fn buildDeletePreparedExecutable(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    compile_arena_ptr: *std.heap.ArenaAllocator,
    delete_stmt: *const ast.Delete,
) PrepareError!CompiledPreparedExecutable {
    if (delete_stmt.selector.tag_filter != null) return error.NotImplemented;
    if (delete_stmt.predicate) |predicate| {
        try ensureDeletePredicateSupported(predicate);
    }

    const target = try resolveDeleteWriteTarget(compile_arena_ptr.allocator(), engine, delete_stmt.selector);

    const predicate_exprs = if (delete_stmt.predicate) |predicate|
        try allocator.dupe(*const ast.Expr, &.{predicate})
    else
        &.{};
    errdefer if (predicate_exprs.len != 0) allocator.free(predicate_exprs);

    const instructions = try allocator.dupe(bytecode.Instruction, &.{
        .{
            .opcode = .delete_points,
            .p1 = if (delete_stmt.predicate != null) 0 else -1,
            .p4 = .{ .write_target = 0 },
            .comment = switch (delete_stmt.selector.series) {
                .name => |name| name.value,
                .by_id => "by_id",
            },
        },
        .{ .opcode = .halt },
    });
    errdefer allocator.free(instructions);

    const write_targets = try allocator.dupe(bytecode.WriteTarget, &.{target});
    errdefer allocator.free(write_targets);

    return .{
        .program = .{
            .allocator = allocator,
            .instructions = instructions,
            .exprs = predicate_exprs,
            .write_targets = write_targets,
            .register_count = 1,
            .source_name = "prepared_delete",
        },
        .columns = &.{},
        .typed_query = null,
        .compile_arena_ptr = compile_arena_ptr,
    };
}

const InsertExprMapping = struct {
    time_expr: *const ast.Expr,
    value_expr: *const ast.Expr,
};

fn resolveInsertColumnExprs(insert_stmt: *const ast.Insert) PrepareError!InsertExprMapping {
    if (insert_stmt.values.len != 2) return error.NotImplemented;
    if (insert_stmt.columns.len == 0) {
        return .{
            .time_expr = insert_stmt.values[0],
            .value_expr = insert_stmt.values[1],
        };
    }
    if (insert_stmt.columns.len != insert_stmt.values.len) return error.NotImplemented;

    var time_expr: ?*const ast.Expr = null;
    var value_expr: ?*const ast.Expr = null;
    for (insert_stmt.columns, insert_stmt.values) |column, expr| {
        const tail = trailingSegment(column.value);
        if (std.ascii.eqlIgnoreCase(tail, "time")) {
            time_expr = expr;
        } else if (std.ascii.eqlIgnoreCase(tail, "value")) {
            value_expr = expr;
        } else {
            return error.NotImplemented;
        }
    }
    return .{
        .time_expr = time_expr orelse return error.NotImplemented,
        .value_expr = value_expr orelse return error.NotImplemented,
    };
}

fn resolveDeleteWriteTarget(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    selector: ast.Selector,
) PrepareError!bytecode.WriteTarget {
    const resolution = switch (selector.series) {
        .name => |name| engine.resolveSelector(.{ .name = name.value }) catch return error.NotImplemented,
        .by_id => |by_id| engine.resolveSelector(.{ .by_id = @intCast(by_id.value) }) catch return error.NotImplemented,
    };
    return switch (resolution.status) {
        .resolved, .exact_match => .{
            .series_id = resolution.series_id.?,
            .series_name = try allocator.dupe(u8, resolution.series orelse switch (selector.series) {
                .name => |name| name.value,
                .by_id => "by_id",
            }),
            .tags_json = try allocator.dupe(u8, resolution.canonical_tags orelse "{}"),
        },
        .not_found, .ambiguous => error.NotImplemented,
    };
}

fn ensureDeletePredicateSupported(expr: *const ast.Expr) PrepareError!void {
    switch (expr.*) {
        .identifier => |ident| {
            const tail = trailingSegment(ident.value);
            if (!std.ascii.eqlIgnoreCase(tail, "time") and !std.ascii.eqlIgnoreCase(tail, "value")) {
                return error.NotImplemented;
            }
        },
        .literal => {},
        .unary => |unary| try ensureDeletePredicateSupported(unary.operand),
        .binary => |binary| {
            switch (binary.op) {
                .add,
                .subtract,
                .multiply,
                .divide,
                .modulo,
                .equal,
                .not_equal,
                .less,
                .less_equal,
                .greater,
                .greater_equal,
                .logical_and,
                .logical_or,
                => {},
                else => return error.NotImplemented,
            }
            try ensureDeletePredicateSupported(binary.left);
            try ensureDeletePredicateSupported(binary.right);
        },
        .call => |call| {
            if (std.ascii.eqlIgnoreCase(call.callee.value, "time_bucket")) {
                if (call.args.len != 2 and call.args.len != 3) return error.NotImplemented;
                for (call.args, 0..) |arg, idx| {
                    if (idx == 1) {
                        try ensureDeletePredicateSupported(arg);
                    } else {
                        try ensureDeleteConstantExpr(arg);
                    }
                }
                return;
            }
            if (std.ascii.eqlIgnoreCase(call.callee.value, "abs") or
                std.ascii.eqlIgnoreCase(call.callee.value, "ceil") or
                std.ascii.eqlIgnoreCase(call.callee.value, "floor") or
                std.ascii.eqlIgnoreCase(call.callee.value, "round") or
                std.ascii.eqlIgnoreCase(call.callee.value, "sqrt") or
                std.ascii.eqlIgnoreCase(call.callee.value, "ln"))
            {
                if (call.args.len != 1) return error.NotImplemented;
                try ensureDeletePredicateSupported(call.args[0]);
                return;
            }
            if (std.ascii.eqlIgnoreCase(call.callee.value, "pow")) {
                if (call.args.len != 2) return error.NotImplemented;
                try ensureDeletePredicateSupported(call.args[0]);
                try ensureDeletePredicateSupported(call.args[1]);
                return;
            }
            return error.NotImplemented;
        },
    }
}

fn ensureDeleteConstantExpr(expr: *const ast.Expr) PrepareError!void {
    switch (expr.*) {
        .literal => {},
        .unary => |unary| try ensureDeleteConstantExpr(unary.operand),
        .binary => |binary| {
            try ensureDeleteConstantExpr(binary.left);
            try ensureDeleteConstantExpr(binary.right);
        },
        else => return error.NotImplemented,
    }
}

fn emptyProgram(allocator: std.mem.Allocator) bytecode.Program {
    return .{
        .allocator = allocator,
        .instructions = &.{},
    };
}

fn cloneBoundValue(allocator: std.mem.Allocator, value: value_mod.Value) std.mem.Allocator.Error!value_mod.Value {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        else => value,
    };
}

fn freeBoundValueStorage(allocator: std.mem.Allocator, value: ?value_mod.Value) void {
    if (value) |bound| switch (bound) {
        .string => |text| allocator.free(text),
        else => {},
    };
}

fn buildParameterDescriptions(
    allocator: std.mem.Allocator,
    normalized: NormalizedStmt,
) ![]const ParameterDescription {
    const slot_count = blk: {
        var max_slot: ParameterSlot = 0;
        for (normalized.parameters) |binding| {
            if (binding.slot > max_slot) max_slot = binding.slot;
        }
        break :blk max_slot;
    };
    if (slot_count == 0) return &.{};

    const descriptions = try allocator.alloc(ParameterDescription, slot_count);
    for (descriptions, 0..) |*description, idx| {
        description.* = .{ .slot = idx + 1 };
    }
    errdefer freeParameterDescriptions(allocator, descriptions);

    for (normalized.parameters) |binding| {
        var name_copy: ?[]const u8 = null;
        errdefer if (name_copy) |owned_name| allocator.free(owned_name);

        if (binding.name) |name| {
            name_copy = try allocator.dupe(u8, name);
        }

        descriptions[binding.slot - 1] = .{
            .slot = binding.slot,
            .present = true,
            .raw = try allocator.dupe(u8, binding.raw),
            .kind = binding.kind,
            .name = name_copy,
            .explicit_index = binding.explicit_index,
            .span = binding.span,
            .occurrences = binding.occurrences,
        };
    }

    inferStatementParameterTypes(
        normalized.statement,
        normalized.parameters,
        normalized.named_parameters,
        descriptions,
    );
    return descriptions;
}

fn freeParameterDescriptions(allocator: std.mem.Allocator, descriptions: []const ParameterDescription) void {
    if (descriptions.len == 0) return;
    for (descriptions) |description| {
        if (description.raw.len != 0) allocator.free(description.raw);
        if (description.name) |name| allocator.free(name);
    }
    allocator.free(descriptions);
}

fn inferStatementParameterTypes(
    statement: frontend.normalize.Statement,
    parameters: []const ParameterBinding,
    named_parameters: []const NamedParameterBinding,
    descriptions: []ParameterDescription,
) void {
    switch (statement) {
        .select => |select| {
            for (select.projections) |projection| {
                inferExprParameterTypes(projection.expr, parameters, named_parameters, descriptions, null);
            }
            if (select.predicate) |predicate| {
                inferExprParameterTypes(predicate, parameters, named_parameters, descriptions, null);
            }
            for (select.groupings) |grouping| {
                inferExprParameterTypes(grouping.expr, parameters, named_parameters, descriptions, null);
            }
            for (select.ordering) |ordering| {
                inferExprParameterTypes(ordering.expr, parameters, named_parameters, descriptions, null);
            }
        },
        .insert => |insert| {
            for (insert.values, 0..) |value_expr, idx| {
                const expected = if (idx < insert.columns.len)
                    inferNormalizedExprType(insert.columns[idx])
                else
                    null;
                inferExprParameterTypes(value_expr, parameters, named_parameters, descriptions, expected);
            }
        },
        .delete => |delete| {
            if (delete.predicate) |predicate| {
                inferExprParameterTypes(predicate, parameters, named_parameters, descriptions, null);
            }
        },
        .explain => |explain| {
            inferStatementParameterTypes(explain.target.*, parameters, named_parameters, descriptions);
        },
    }
}

fn inferExprParameterTypes(
    expr: *const frontend.normalize.Expr,
    parameters: []const ParameterBinding,
    named_parameters: []const NamedParameterBinding,
    descriptions: []ParameterDescription,
    expected_type: ?query_functions.Type,
) void {
    switch (expr.*) {
        .identifier,
        .integer,
        .float,
        .string,
        .boolean,
        .null_value,
        .duration,
        .timestamp,
        => {},
        .parameter => |parameter| {
            const slot = resolveNormalizedParameterSlot(parameters, named_parameters, parameter) orelse return;
            applyParameterTypeHint(descriptions, slot, expected_type orelse query_functions.Type.init(.any, true));
        },
        .comparison => |comparison| {
            if (parameterSlotIfAny(comparison.left, parameters, named_parameters)) |slot| {
                applyParameterTypeHint(descriptions, slot, inferNormalizedExprType(comparison.right) orelse query_functions.Type.init(.any, true));
            }
            if (parameterSlotIfAny(comparison.right, parameters, named_parameters)) |slot| {
                applyParameterTypeHint(descriptions, slot, inferNormalizedExprType(comparison.left) orelse query_functions.Type.init(.any, true));
            }
            inferExprParameterTypes(comparison.left, parameters, named_parameters, descriptions, null);
            inferExprParameterTypes(comparison.right, parameters, named_parameters, descriptions, null);
        },
        .call => |call| {
            if (query_functions.lookup(call.callee.value)) |signature| {
                for (call.args, 0..) |arg, idx| {
                    inferExprParameterTypes(arg, parameters, named_parameters, descriptions, expectationToType(signature, idx));
                }
            } else {
                for (call.args) |arg| {
                    inferExprParameterTypes(arg, parameters, named_parameters, descriptions, null);
                }
            }
        },
    }
}

fn applyParameterTypeHint(
    descriptions: []ParameterDescription,
    slot: ParameterSlot,
    hinted_type: query_functions.Type,
) void {
    if (slot == 0 or slot > descriptions.len) return;
    descriptions[slot - 1].inferred_type = mergeParameterTypes(
        descriptions[slot - 1].inferred_type,
        hinted_type,
    );
}

fn mergeParameterTypes(current: query_functions.Type, next: query_functions.Type) query_functions.Type {
    if (next.tag == .any) return current;
    if (current.tag == .any) return next;
    if (current.tag == next.tag) {
        return .{ .tag = current.tag, .nullable = current.nullable or next.nullable };
    }

    if (isNumericLike(current.tag) and isNumericLike(next.tag)) {
        return query_functions.Type.init(.numeric, current.nullable or next.nullable);
    }
    if (isIntegerLike(current.tag) and isIntegerLike(next.tag)) {
        return query_functions.Type.init(.integer, current.nullable or next.nullable);
    }
    if (isStringLike(current.tag) and isStringLike(next.tag)) {
        return query_functions.Type.init(.string, current.nullable or next.nullable);
    }
    return query_functions.Type.init(.any, current.nullable or next.nullable);
}

fn isNumericLike(tag: query_functions.TypeTag) bool {
    return switch (tag) {
        .integer, .float, .numeric, .value => true,
        else => false,
    };
}

fn isIntegerLike(tag: query_functions.TypeTag) bool {
    return switch (tag) {
        .integer, .timestamp, .duration => true,
        else => false,
    };
}

fn isStringLike(tag: query_functions.TypeTag) bool {
    return switch (tag) {
        .string, .tags => true,
        else => false,
    };
}

fn expectationToType(signature: *const query_functions.FunctionSignature, arg_index: usize) ?query_functions.Type {
    const spec = if (arg_index < signature.params.len)
        signature.params[arg_index]
    else if (signature.params.len != 0 and signature.params[signature.params.len - 1].variadic)
        signature.params[signature.params.len - 1]
    else
        return null;

    if (spec.expectation.allowed.len == 0) return null;
    const tag = spec.expectation.allowed[0];
    return switch (tag) {
        .timestamp,
        .duration,
        .integer,
        .float,
        .boolean,
        .string,
        .tags,
        .numeric,
        .value,
        => query_functions.Type.init(tag, spec.expectation.allow_nullable),
        .null, .any => null,
    };
}

fn inferNormalizedExprType(expr: *const frontend.normalize.Expr) ?query_functions.Type {
    return switch (expr.*) {
        .identifier => |identifier| inferIdentifierType(identifier.value),
        .integer => query_functions.Type.init(.integer, false),
        .float => query_functions.Type.init(.float, false),
        .string => query_functions.Type.init(.string, false),
        .boolean => query_functions.Type.init(.boolean, false),
        .null_value => query_functions.Type.init(.null, true),
        .duration => query_functions.Type.init(.duration, false),
        .timestamp => query_functions.Type.init(.timestamp, false),
        .parameter => null,
        .comparison => query_functions.Type.init(.boolean, true),
        .call => |call| blk: {
            const signature = query_functions.lookup(call.callee.value) orelse break :blk null;
            break :blk switch (signature.return_strategy) {
                .fixed => |ty| ty,
                .same_as => |same_as| if (call.args.len == 0 or same_as.index >= call.args.len)
                    null
                else
                    inferNormalizedExprType(call.args[same_as.index]),
            };
        },
    };
}

fn inferIdentifierType(name: []const u8) query_functions.Type {
    const segment = trailingSegment(name);
    if (std.ascii.eqlIgnoreCase(segment, "time")) return query_functions.Type.init(.timestamp, false);
    if (std.ascii.eqlIgnoreCase(segment, "value")) return query_functions.Type.init(.value, true);
    if (hasTagPrefix(name)) return query_functions.Type.init(.string, true);
    return query_functions.Type.init(.any, true);
}

fn parameterSlotIfAny(
    expr: *const frontend.normalize.Expr,
    parameters: []const ParameterBinding,
    named_parameters: []const NamedParameterBinding,
) ?ParameterSlot {
    if (expr.* != .parameter) return null;
    return resolveNormalizedParameterSlot(parameters, named_parameters, expr.parameter);
}

fn resolveNormalizedParameterSlot(
    parameters: []const ParameterBinding,
    named_parameters: []const NamedParameterBinding,
    parameter: frontend.normalize.Parameter,
) ?ParameterSlot {
    if (parameter.kind == .positional) {
        if (parseExplicitParameterIndex(parameter.raw)) |explicit| return explicit;
    } else {
        const raw_name = if (parameter.raw.len > 0) parameter.raw[1..] else parameter.raw;
        for (named_parameters) |binding| {
            if (std.mem.eql(u8, binding.name, raw_name)) return binding.slot;
        }
    }

    for (parameters) |binding| {
        if (binding.kind != parameter.kind) continue;
        if (std.mem.eql(u8, binding.raw, parameter.raw)) return binding.slot;
    }
    return null;
}

fn parseExplicitParameterIndex(raw: []const u8) ?u32 {
    if (raw.len < 2) return null;
    const digits = raw[1..];
    if (digits.len == 0) return null;
    for (digits) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }
    return std.fmt.parseUnsigned(u32, digits, 10) catch null;
}

fn trailingSegment(slice: []const u8) []const u8 {
    if (slice.len == 0) return slice;
    var index = slice.len;
    while (index > 0) {
        index -= 1;
        if (slice[index] == '.') return slice[index + 1 ..];
    }
    return slice;
}

fn hasTagPrefix(slice: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, slice, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(slice[0..dot], "tag");
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

test "prepared VM supports aggregate reads and grouped time buckets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-aggregates", .{tmp.sub_path});
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

    const sid = @import("../types.zig").seriesIdFrom("stage3.agg", "{}");
    try engine.registerSeries("stage3.agg", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.5, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 70, .value = 3.5, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 3, 1_000);

    var aggregate_stmt = try prepareSydraQL(alloc, engine, "select first(value) as first_value, last(value) as last_value from stage3.agg where time >= 0", .{});
    defer aggregate_stmt.finalize();
    const aggregate_row = try aggregate_stmt.step();
    try std.testing.expect(aggregate_row == .row);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try aggregate_row.row[0].asFloat(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), try aggregate_row.row[1].asFloat(), 1e-9);
    try std.testing.expect((try aggregate_stmt.step()) == .done);

    var grouped_stmt = try prepareSydraQL(alloc, engine, "select time_bucket(60, time) as bucket, max(value) as max_value from stage3.agg where time >= 0 group by time_bucket(60, time)", .{});
    defer grouped_stmt.finalize();
    const first_group = (try grouped_stmt.step());
    try std.testing.expect(first_group == .row);
    try std.testing.expectEqual(@as(i64, 0), first_group.row[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), try first_group.row[1].asFloat(), 1e-9);
    const second_group = (try grouped_stmt.step());
    try std.testing.expect(second_group == .row);
    try std.testing.expectEqual(@as(i64, 60), second_group.row[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), try second_group.row[1].asFloat(), 1e-9);
    try std.testing.expect((try grouped_stmt.step()) == .done);
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

test "prepareSqlCore reports still-uncovered SQL instead of translating implicitly" {
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
        "SELECT value FROM weather.room1 WHERE value =~ 'hot'",
        .{},
    ));
}

test "prepareSqlCore handles logical predicates through generated frontend coverage" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-sql-logical", .{tmp.sub_path});
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

    const sid = @import("../types.zig").seriesIdFrom("weather.room1", "{}");
    try engine.registerSeries("weather.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 3.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 30, .value = 7.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 3, 1_000);

    var stmt = try prepareSqlCore(
        alloc,
        engine,
        "SELECT time, value FROM weather.room1 WHERE time >= $1 AND value <= $2 ORDER BY time ASC LIMIT 1",
        .{},
    );
    defer stmt.finalize();

    const parameters = try stmt.describeParameters();
    try std.testing.expectEqual(@as(usize, 2), parameters.len);
    try stmt.bindPositional(1, .{ .integer = 15 });
    try stmt.bindPositional(2, .{ .float = 5.0 });

    const row = try stmt.step();
    try std.testing.expect(row == .row);
    try std.testing.expectEqual(@as(i64, 20), row.row[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), try row.row[1].asFloat(), 1e-9);
    try std.testing.expect((try stmt.step()) == .done);
}

test "prepareSqlCore handles constant float boolean and null literals" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-sql-literals", .{tmp.sub_path});
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

    var stmt = try prepareSqlCore(alloc, engine, "SELECT 3.14 AS reading, true AS enabled, null AS missing", .{});
    defer stmt.finalize();

    const row = try stmt.step();
    try std.testing.expect(row == .row);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), try row.row[0].asFloat(), 1e-9);
    try std.testing.expectEqual(true, row.row[1].boolean);
    try std.testing.expect(row.row[2] == .null);
    try std.testing.expect((try stmt.step()) == .done);
}

test "prepareSqlCore handles duration and timestamp literals through direct frontend coverage" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-sql-time-literals", .{tmp.sub_path});
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

    const sid = @import("../types.zig").seriesIdFrom("time.literals", "{}");
    try engine.registerSeries("time.literals", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 1_648_339_200, .value = 7.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 1, 1_000);

    var stmt = try prepareSqlCore(
        alloc,
        engine,
        "SELECT time_bucket(5m, time, 2022-03-27T00:00:00Z) AS bucket FROM time.literals WHERE time >= 2022-03-27T00:00:00Z ORDER BY time ASC LIMIT 1",
        .{},
    );
    defer stmt.finalize();

    const row = try stmt.step();
    try std.testing.expect(row == .row);
    try std.testing.expectEqual(@as(i64, 1_648_339_200), row.row[0].integer);
    try std.testing.expect((try stmt.step()) == .done);
}

test "prepared statement executes parameterized inserts through the VM" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-insert", .{tmp.sub_path});
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

    var stmt = try prepareSqlCore(alloc, engine, "INSERT INTO writes.room1(time, value) VALUES ($1, $2)", .{});
    defer stmt.finalize();

    try std.testing.expectEqual(frontend.stmt.StatementKind.insert, stmt.statementKind());
    try std.testing.expectEqual(@as(usize, 0), (try stmt.describeColumns()).len);
    try std.testing.expectEqual(@as(usize, 2), (try stmt.describeParameters()).len);
    try std.testing.expectEqual(@as(usize, 0), stmt.rowsAffected());
    try std.testing.expectError(error.UnboundParameter, stmt.step());

    try stmt.bindPositional(1, .{ .integer = 10 });
    try stmt.bindPositional(2, .{ .float = 4.5 });
    try std.testing.expect((try stmt.step()) == .done);
    try std.testing.expectEqual(@as(usize, 1), stmt.rowsAffected());

    const sid = @import("../types.zig").seriesIdFrom("writes.room1", "{}");
    try waitForQueryablePoints(alloc, engine, sid, 1, 1_000);

    var points = std.array_list.Managed(@import("../types.zig").Point).init(alloc);
    defer points.deinit();
    try engine.queryRange(sid, std.math.minInt(i64), std.math.maxInt(i64), &points);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(i64, 10), points.items[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), points.items[0].value, 1e-9);
}

test "prepared statement executes parameterized deletes through the VM" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-delete", .{tmp.sub_path});
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

    const sid = @import("../types.zig").seriesIdFrom("writes.room1", "{}");
    try engine.registerSeries("writes.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 30, .value = 3.0, .tags_json = "{}" });

    var stmt = try prepareSqlCore(alloc, engine, "DELETE FROM writes.room1 WHERE time >= $1", .{});
    defer stmt.finalize();

    try std.testing.expectEqual(frontend.stmt.StatementKind.delete, stmt.statementKind());
    try std.testing.expect(!stmt.producesRows());
    try std.testing.expectEqual(@as(usize, 0), (try stmt.describeColumns()).len);
    try std.testing.expectEqual(@as(usize, 1), (try stmt.describeParameters()).len);
    try std.testing.expectEqual(@as(usize, 0), stmt.rowsAffected());
    try std.testing.expectError(error.UnboundParameter, stmt.step());

    try stmt.bindPositional(1, .{ .integer = 20 });
    try std.testing.expect((try stmt.step()) == .done);
    try std.testing.expectEqual(@as(usize, 2), stmt.rowsAffected());

    var points = std.array_list.Managed(@import("../types.zig").Point).init(alloc);
    defer points.deinit();
    try engine.queryRange(sid, std.math.minInt(i64), std.math.maxInt(i64), &points);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(i64, 10), points.items[0].ts);
}

test "prepared statement surfaces frontend coverage metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-coverage", .{tmp.sub_path});
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

    var stmt = try prepareSqlCore(alloc, engine, "SELECT 1", .{});
    defer stmt.finalize();

    try std.testing.expect(stmt.coverageUsed());
    try std.testing.expect(stmt.fallbackReason() == null);
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

test "prepared statement binds positional parameters before lazy compilation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-positional-bind", .{tmp.sub_path});
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

    const sid = @import("../types.zig").seriesIdFrom("bind.room1", "{}");
    try engine.registerSeries("bind.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 2, 1_000);

    var stmt = try prepareSqlCore(alloc, engine, "SELECT time, value FROM bind.room1 WHERE time >= $1 ORDER BY time ASC LIMIT 1", .{});
    defer stmt.finalize();
    try std.testing.expectEqual(@as(usize, 1), stmt.binding.parameterCount());
    try std.testing.expectError(error.UnboundParameter, stmt.step());

    try stmt.bindPositional(1, .{ .integer = 15 });
    const row = try stmt.step();
    try std.testing.expect(row == .row);
    try std.testing.expectEqual(@as(i64, 20), row.row[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), try row.row[1].asFloat(), 1e-9);
    try std.testing.expect((try stmt.step()) == .done);
}

test "prepared statement describes parameters and columns before binding" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-describe", .{tmp.sub_path});
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

    const sid = @import("../types.zig").seriesIdFrom("describe.room1", "{}");
    try engine.registerSeries("describe.room1", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 1, 1_000);

    var stmt = try prepareSqlCore(alloc, engine, "SELECT time, value FROM describe.room1 WHERE time >= $1 ORDER BY time ASC LIMIT 1", .{});
    defer stmt.finalize();

    const parameters = try stmt.describeParameters();
    try std.testing.expectEqual(@as(usize, 1), parameters.len);
    try std.testing.expect(parameters[0].present);
    try std.testing.expectEqual(@as(usize, 1), parameters[0].slot);
    try std.testing.expectEqual(@as(u32, 20), parameters[0].pgOid());

    const columns = try stmt.describeColumns();
    try std.testing.expectEqual(@as(usize, 2), columns.len);
    try std.testing.expectEqualStrings("time", columns[0].name);
    try std.testing.expectEqualStrings("value", columns[1].name);
    try std.testing.expectError(error.UnboundParameter, stmt.step());
}

test "prepared statement accepts unused positional gap slots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-gap-slot", .{tmp.sub_path});
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

    const sid = @import("../types.zig").seriesIdFrom("bind.gap", "{}");
    try engine.registerSeries("bind.gap", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 2, 1_000);

    var stmt = try prepareSqlCore(alloc, engine, "SELECT time, value FROM bind.gap WHERE time >= $2 ORDER BY time ASC LIMIT 1", .{});
    defer stmt.finalize();

    const parameters = try stmt.describeParameters();
    try std.testing.expectEqual(@as(usize, 2), parameters.len);
    try std.testing.expect(!parameters[0].present);
    try std.testing.expect(parameters[1].present);

    try stmt.bindPositional(1, .null);
    try stmt.bindPositional(2, .{ .integer = 15 });
    const row = try stmt.step();
    try std.testing.expect(row == .row);
    try std.testing.expectEqual(@as(i64, 20), row.row[0].integer);
}

test "prepared statement binds named parameters and clears bindings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/prepared-named-bind", .{tmp.sub_path});
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

    const sid = @import("../types.zig").seriesIdFrom("bind.named", "{}");
    try engine.registerSeries("bind.named", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 3.0, .tags_json = "{}" });
    try waitForQueryablePoints(alloc, engine, sid, 2, 1_000);

    var stmt = try prepareSqlCore(alloc, engine, "SELECT time, value FROM bind.named WHERE value >= :min ORDER BY time ASC LIMIT 1", .{});
    defer stmt.finalize();
    try std.testing.expectEqual(@as(?ParameterSlot, 1), stmt.binding.slotForNamed("min"));
    try stmt.bindNamed("min", .{ .float = 2.0 });

    const row = try stmt.step();
    try std.testing.expect(row == .row);
    try std.testing.expectEqual(@as(i64, 20), row.row[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), try row.row[1].asFloat(), 1e-9);
    try std.testing.expect((try stmt.step()) == .done);

    stmt.reset();
    stmt.clearBindings();
    try std.testing.expectError(error.UnboundParameter, stmt.step());
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
        .float => |float| {
            try std.testing.expect(actual.* == .float);
            try std.testing.expectApproxEqAbs(float.value, actual.float.value, 1e-9);
        },
        .string => |string| {
            try std.testing.expect(actual.* == .string);
            try std.testing.expectEqualStrings(string.value, actual.string.value);
        },
        .boolean => |boolean| {
            try std.testing.expect(actual.* == .boolean);
            try std.testing.expectEqual(boolean.value, actual.boolean.value);
        },
        .null_value => {
            try std.testing.expect(actual.* == .null_value);
        },
        .duration => |duration| {
            try std.testing.expect(actual.* == .duration);
            try std.testing.expectApproxEqAbs(duration.value, actual.duration.value, 1e-9);
        },
        .timestamp => |timestamp| {
            try std.testing.expect(actual.* == .timestamp);
            try std.testing.expectApproxEqAbs(timestamp.value, actual.timestamp.value, 1e-9);
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
