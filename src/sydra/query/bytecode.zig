const std = @import("std");

const ast = @import("ast.zig");
const ir = @import("compiler/ir.zig");
const plan = @import("plan.zig");
const value_mod = @import("value.zig");

pub const RegisterId = u16;
pub const CursorId = u8;
pub const ConstantId = u16;
pub const TempStoreId = u8;
pub const LabelId = u16;
pub const ExprId = u16;
pub const SelectorId = u8;
pub const SchemaId = u8;
pub const OrderingId = u8;
pub const AggregateId = u8;

pub const CompareKind = enum(u8) {
    eq = 1,
    ne = 2,
    lt = 3,
    le = 4,
    gt = 5,
    ge = 6,
};

pub const Opcode = enum {
    open_series,
    open_rollup,
    seek_time_ge,
    next_point,
    load_const,
    column,
    function,
    compare,
    jump,
    jump_if_false,
    agg_step,
    agg_final,
    sorter_open,
    sorter_insert,
    sorter_next,
    result_row,
    halt,
};

pub const OperandRef = union(enum) {
    none,
    constant: ConstantId,
    expr: ExprId,
    selector: SelectorId,
    schema: SchemaId,
    ordering: OrderingId,
    aggregate: AggregateId,
    text: []const u8,
};

pub const Instruction = struct {
    opcode: Opcode,
    p1: i64 = 0,
    p2: i64 = 0,
    p3: i64 = 0,
    p4: OperandRef = .none,
    p5: u8 = 0,
    comment: ?[]const u8 = null,
};

pub const CursorDecl = struct {
    id: CursorId,
    name: []const u8,
};

pub const TempStoreDecl = struct {
    id: TempStoreId,
    name: []const u8,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    instructions: []Instruction,
    constants: []value_mod.Value = &.{},
    exprs: []const *const ast.Expr = &.{},
    selectors: []const ir.BoundSelector = &.{},
    schemas: []const []const plan.ColumnInfo = &.{},
    orderings: []const []const ast.OrderExpr = &.{},
    aggregates: []const ir.AggregateSpec = &.{},
    cursors: []const CursorDecl = &.{},
    temp_stores: []const TempStoreDecl = &.{},
    register_count: usize = 0,
    source_name: []const u8 = "anonymous",
    version: u16 = 1,

    pub fn deinit(self: *Program) void {
        if (self.instructions.len != 0) self.allocator.free(self.instructions);
        if (self.constants.len != 0) self.allocator.free(self.constants);
        if (self.exprs.len != 0) self.allocator.free(self.exprs);
        if (self.selectors.len != 0) self.allocator.free(self.selectors);
        if (self.schemas.len != 0) self.allocator.free(self.schemas);
        if (self.orderings.len != 0) self.allocator.free(self.orderings);
        if (self.aggregates.len != 0) self.allocator.free(self.aggregates);
        if (self.cursors.len != 0) self.allocator.free(self.cursors);
        if (self.temp_stores.len != 0) self.allocator.free(self.temp_stores);
        self.* = undefined;
    }
};

pub const DisassemblyLine = struct {
    pc: usize,
    opcode: []const u8,
    p1: i64,
    p2: i64,
    p3: i64,
    p4: []const u8,
    p5: u8,
    comment: []const u8,
};

pub fn disassemble(allocator: std.mem.Allocator, program: Program) ![]DisassemblyLine {
    const lines = try allocator.alloc(DisassemblyLine, program.instructions.len);
    for (program.instructions, 0..) |instruction, idx| {
        lines[idx] = .{
            .pc = idx,
            .opcode = @tagName(instruction.opcode),
            .p1 = instruction.p1,
            .p2 = instruction.p2,
            .p3 = instruction.p3,
            .p4 = try formatOperandRef(allocator, instruction.p4),
            .p5 = instruction.p5,
            .comment = instruction.comment orelse "",
        };
    }
    return lines;
}

pub fn freeDisassembly(allocator: std.mem.Allocator, lines: []DisassemblyLine) void {
    for (lines) |line| {
        if (line.p4.len != 0) allocator.free(line.p4);
    }
    allocator.free(lines);
}

fn formatOperandRef(allocator: std.mem.Allocator, operand: OperandRef) ![]const u8 {
    return switch (operand) {
        .none => "",
        .constant => |id| try std.fmt.allocPrint(allocator, "const[{d}]", .{id}),
        .expr => |id| try std.fmt.allocPrint(allocator, "expr[{d}]", .{id}),
        .selector => |id| try std.fmt.allocPrint(allocator, "selector[{d}]", .{id}),
        .schema => |id| try std.fmt.allocPrint(allocator, "schema[{d}]", .{id}),
        .ordering => |id| try std.fmt.allocPrint(allocator, "ordering[{d}]", .{id}),
        .aggregate => |id| try std.fmt.allocPrint(allocator, "aggregate[{d}]", .{id}),
        .text => |text| try allocator.dupe(u8, text),
    };
}

test "bytecode disassembler formats sqlite-style rows" {
    const alloc = std.testing.allocator;
    const instructions = try alloc.dupe(Instruction, &.{
        .{ .opcode = .load_const, .p1 = 0, .p4 = .{ .constant = 0 }, .comment = "seed r0" },
        .{ .opcode = .result_row, .p1 = 0, .p2 = 1, .p4 = .{ .schema = 0 } },
        .{ .opcode = .halt },
    });
    var program = Program{
        .allocator = alloc,
        .instructions = instructions,
        .constants = try alloc.dupe(value_mod.Value, &.{value_mod.Value{ .integer = 1 }}),
        .schemas = try alloc.dupe([]const plan.ColumnInfo, &.{&.{}}),
        .source_name = "unit",
        .register_count = 1,
    };
    defer program.deinit();

    const lines = try disassemble(alloc, program);
    defer freeDisassembly(alloc, lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("load_const", lines[0].opcode);
    try std.testing.expectEqualStrings("const[0]", lines[0].p4);
    try std.testing.expectEqualStrings("schema[0]", lines[1].p4);
    try std.testing.expectEqualStrings("", lines[2].comment);
}
