const std = @import("std");

const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const plan = @import("plan.zig");
const value_mod = @import("value.zig");

pub const CodegenError = std.mem.Allocator.Error || error{
    UnsupportedPreparedQuery,
    UnsupportedProjection,
    UnsupportedPredicate,
    InvalidLiteral,
};

pub const CodegenResult = struct {
    program: bytecode.Program,
    columns: []const plan.ColumnInfo,
};

pub fn buildProgram(allocator: std.mem.Allocator, compiled: compiler.CompiledSelect) CodegenError!CodegenResult {
    if (compiled.typed_query.is_aggregate_query) return error.UnsupportedPreparedQuery;
    if (compiled.typed_query.ordering.len != 0) return error.UnsupportedPreparedQuery;
    if (compiled.typed_query.select.limit != null) return error.UnsupportedPreparedQuery;

    if (compiled.typed_query.bound_selector == null) {
        return try buildConstantProgram(allocator, compiled);
    }
    return try buildScanProgram(allocator, compiled);
}

fn buildConstantProgram(allocator: std.mem.Allocator, compiled: compiler.CompiledSelect) CodegenError!CodegenResult {
    const columns = try buildColumns(allocator, compiled.typed_query.projections);
    errdefer allocator.free(columns);

    const constants = try allocator.alloc(value_mod.Value, compiled.typed_query.projections.len);
    errdefer allocator.free(constants);
    const instructions = try allocator.alloc(bytecode.Instruction, compiled.typed_query.projections.len + 2);
    errdefer allocator.free(instructions);

    for (compiled.typed_query.projections, 0..) |projection, idx| {
        constants[idx] = try literalValue(projection.expr.expr);
        instructions[idx] = .{
            .opcode = .load_const,
            .p1 = @intCast(idx),
            .p4 = .{ .constant = @intCast(idx) },
            .comment = projection.name,
        };
    }
    instructions[compiled.typed_query.projections.len] = .{
        .opcode = .result_row,
        .p1 = 0,
        .p2 = @intCast(compiled.typed_query.projections.len),
        .p4 = .{ .schema = 0 },
    };
    instructions[compiled.typed_query.projections.len + 1] = .{ .opcode = .halt };

    return .{
        .program = .{
            .allocator = allocator,
            .instructions = instructions,
            .constants = constants,
            .schemas = try allocator.dupe([]const plan.ColumnInfo, &.{columns}),
            .register_count = compiled.typed_query.projections.len,
            .source_name = "prepared_constant_select",
        },
        .columns = columns,
    };
}

fn buildScanProgram(allocator: std.mem.Allocator, compiled: compiler.CompiledSelect) CodegenError!CodegenResult {
    const typed = compiled.typed_query;
    const columns = try buildColumns(allocator, typed.projections);
    errdefer allocator.free(columns);

    var instructions = std.array_list.Managed(bytecode.Instruction).init(allocator);
    errdefer instructions.deinit();

    var constants = std.array_list.Managed(value_mod.Value).init(allocator);
    errdefer constants.deinit();

    const selector = typed.bound_selector.?;
    const start_ts = if (typed.time_range.start) |bound| bound.value else std.math.minInt(i64);
    const end_ts = if (typed.time_range.end) |bound| bound.value else std.math.maxInt(i64);
    try instructions.append(.{
        .opcode = .open_series,
        .p1 = 0,
        .p2 = start_ts,
        .p3 = end_ts,
        .p4 = .{ .selector = 0 },
    });

    const loop_pc = instructions.items.len;
    try instructions.append(.{ .opcode = .next_point, .p1 = 0, .p2 = 0 });

    try emitPredicate(allocator, &instructions, &constants, typed.predicate, loop_pc);
    try emitProjectionLoads(allocator, &instructions, &constants, typed.projections);
    try instructions.append(.{
        .opcode = .result_row,
        .p1 = 0,
        .p2 = @intCast(typed.projections.len),
        .p4 = .{ .schema = 0 },
    });
    try instructions.append(.{ .opcode = .jump, .p2 = @intCast(loop_pc) });

    const done_pc = instructions.items.len;
    instructions.items[loop_pc].p2 = @intCast(done_pc);
    try instructions.append(.{ .opcode = .halt });

    return .{
        .program = .{
            .allocator = allocator,
            .instructions = try instructions.toOwnedSlice(),
            .constants = try constants.toOwnedSlice(),
            .selectors = try allocator.dupe(compiler.BoundSelector, &.{selector}),
            .schemas = try allocator.dupe([]const plan.ColumnInfo, &.{columns}),
            .cursors = try allocator.dupe(bytecode.CursorDecl, &.{.{ .id = 0, .name = "series0" }}),
            .register_count = @max(typed.projections.len, 3),
            .source_name = "prepared_series_scan",
        },
        .columns = columns,
    };
}

fn emitPredicate(
    allocator: std.mem.Allocator,
    instructions: *std.array_list.Managed(bytecode.Instruction),
    constants: *std.array_list.Managed(value_mod.Value),
    predicate: ?compiler.TypedExpr,
    loop_pc: usize,
) CodegenError!void {
    _ = allocator;
    if (predicate == null) return;
    try emitPredicateExpr(instructions, constants, predicate.?.expr, loop_pc);
}

fn emitPredicateExpr(
    instructions: *std.array_list.Managed(bytecode.Instruction),
    constants: *std.array_list.Managed(value_mod.Value),
    expr: *const ast.Expr,
    loop_pc: usize,
) CodegenError!void {
    if (expr.* != .binary) return error.UnsupportedPredicate;
    const binary = expr.binary;
    if (binary.op == .logical_and) {
        try emitPredicateExpr(instructions, constants, binary.left, loop_pc);
        try emitPredicateExpr(instructions, constants, binary.right, loop_pc);
        return;
    }

    const identifier_expr = if (binary.left.* == .identifier) binary.left else if (binary.right.* == .identifier) binary.right else return error.UnsupportedPredicate;
    const literal_expr = if (identifier_expr == binary.left) binary.right else binary.left;
    const column_code = columnCode(identifier_expr.identifier.value) orelse return error.UnsupportedPredicate;
    const left_reg: i64 = 0;
    const right_reg: i64 = 1;
    const bool_reg: i64 = 2;
    try instructions.append(.{ .opcode = .column, .p1 = 0, .p2 = column_code, .p3 = left_reg });

    const const_id: u16 = @intCast(constants.items.len);
    try constants.append(try literalValue(literal_expr));
    try instructions.append(.{ .opcode = .load_const, .p1 = right_reg, .p4 = .{ .constant = const_id } });

    const compare_kind = compareKind(binary.op, identifier_expr == binary.left) orelse return error.UnsupportedPredicate;
    try instructions.append(.{
        .opcode = .compare,
        .p1 = left_reg,
        .p2 = right_reg,
        .p3 = bool_reg,
        .p5 = @intFromEnum(compare_kind),
    });
    try instructions.append(.{ .opcode = .jump_if_false, .p1 = bool_reg, .p2 = @intCast(loop_pc) });
}

fn emitProjectionLoads(
    allocator: std.mem.Allocator,
    instructions: *std.array_list.Managed(bytecode.Instruction),
    constants: *std.array_list.Managed(value_mod.Value),
    projections: []const compiler.TypedProjection,
) CodegenError!void {
    _ = allocator;
    for (projections, 0..) |projection, idx| {
        switch (projection.expr.expr.*) {
            .identifier => |ident| {
                const code = columnCode(ident.value) orelse return error.UnsupportedProjection;
                try instructions.append(.{ .opcode = .column, .p1 = 0, .p2 = code, .p3 = @intCast(idx) });
            },
            .literal => {
                const const_id: u16 = @intCast(constants.items.len);
                try constants.append(try literalValue(projection.expr.expr));
                try instructions.append(.{ .opcode = .load_const, .p1 = @intCast(idx), .p4 = .{ .constant = const_id } });
            },
            else => return error.UnsupportedProjection,
        }
    }
}

fn buildColumns(allocator: std.mem.Allocator, projections: []const compiler.TypedProjection) ![]plan.ColumnInfo {
    const columns = try allocator.alloc(plan.ColumnInfo, projections.len);
    for (projections, 0..) |projection, idx| {
        columns[idx] = .{ .name = projection.name, .expr = projection.expr.expr };
    }
    return columns;
}

fn literalValue(expr: *const ast.Expr) CodegenError!value_mod.Value {
    if (expr.* != .literal) return error.InvalidLiteral;
    return switch (expr.literal.value) {
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .boolean => |value| .{ .boolean = value },
        .string => |value| .{ .string = value },
        .null => .null,
    };
}

fn columnCode(name: []const u8) ?i64 {
    const tail = trailingSegment(name);
    if (std.ascii.eqlIgnoreCase(tail, "time")) return 0;
    if (std.ascii.eqlIgnoreCase(tail, "value")) return 1;
    return null;
}

fn compareKind(op: ast.BinaryOp, identifier_on_left: bool) ?bytecode.CompareKind {
    return if (identifier_on_left) switch (op) {
        .equal => .eq,
        .not_equal => .ne,
        .less => .lt,
        .less_equal => .le,
        .greater => .gt,
        .greater_equal => .ge,
        else => null,
    } else switch (op) {
        .equal => .eq,
        .not_equal => .ne,
        .less => .gt,
        .less_equal => .ge,
        .greater => .lt,
        .greater_equal => .le,
        else => null,
    };
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
