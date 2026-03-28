const std = @import("std");

const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const engine_mod = @import("../engine.zig");
const expression = @import("expression.zig");
const plan = @import("plan.zig");
const types = @import("../types.zig");
const value_mod = @import("value.zig");

const QueryRangeError = @typeInfo(@typeInfo(@TypeOf(engine_mod.Engine.queryRange)).@"fn".return_type.?).error_union.error_set;

pub const VmError = value_mod.ConvertError || QueryRangeError || error{
    InvalidOpcode,
    InvalidRegister,
    InvalidConstant,
    InvalidJumpTarget,
};

pub const VmStep = union(enum) {
    row: []const value_mod.Value,
    done,
};

pub const VirtualMachine = struct {
    const SeriesCursorState = struct {
        points: std.array_list.Managed(types.Point),
        index: usize = 0,
        current: ?types.Point = null,

        fn init(allocator: std.mem.Allocator) SeriesCursorState {
            return .{ .points = std.array_list.Managed(types.Point).init(allocator) };
        }

        fn deinit(self: *SeriesCursorState) void {
            self.points.deinit();
            self.* = undefined;
        }

        fn reset(self: *SeriesCursorState) void {
            self.points.clearRetainingCapacity();
            self.index = 0;
            self.current = null;
        }
    };

    const SorterRow = struct {
        values: []value_mod.Value,
        keys: []value_mod.Value,
        sequence: usize,
    };

    const SorterState = struct {
        rows: std.array_list.Managed(SorterRow),
        index: usize = 0,
        next_sequence: usize = 0,
        offset: usize = 0,
        take: ?usize = null,
        ordering_id: ?usize = null,
        sorted: bool = false,

        fn init(allocator: std.mem.Allocator) SorterState {
            return .{ .rows = std.array_list.Managed(SorterRow).init(allocator) };
        }

        fn deinit(self: *SorterState, allocator: std.mem.Allocator) void {
            self.clear(allocator);
            self.rows.deinit();
            self.* = undefined;
        }

        fn clear(self: *SorterState, allocator: std.mem.Allocator) void {
            for (self.rows.items) |row| {
                allocator.free(row.values);
                allocator.free(row.keys);
            }
            self.rows.clearRetainingCapacity();
            self.index = 0;
            self.next_sequence = 0;
            self.offset = 0;
            self.take = null;
            self.ordering_id = null;
            self.sorted = false;
        }
    };

    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    program: bytecode.Program,
    registers: []value_mod.Value,
    row_buffer: []value_mod.Value,
    series_cursors: []SeriesCursorState,
    sorters: []SorterState,
    pc: usize = 0,
    halted: bool = false,

    pub fn init(allocator: std.mem.Allocator, engine: *engine_mod.Engine, program: *const bytecode.Program) !VirtualMachine {
        const register_count = @max(program.register_count, 1);
        const registers = try allocator.alloc(value_mod.Value, register_count);
        errdefer allocator.free(registers);
        for (registers) |*slot| slot.* = .null;

        const row_buffer = try allocator.alloc(value_mod.Value, register_count);
        errdefer allocator.free(row_buffer);
        for (row_buffer) |*slot| slot.* = .null;

        const cursor_count = @max(program.cursors.len, 1);
        const series_cursors = try allocator.alloc(SeriesCursorState, cursor_count);
        errdefer allocator.free(series_cursors);
        for (series_cursors) |*cursor| cursor.* = SeriesCursorState.init(allocator);

        const sorter_count = @max(program.temp_stores.len, 1);
        const sorters = try allocator.alloc(SorterState, sorter_count);
        errdefer allocator.free(sorters);
        for (sorters) |*sorter| sorter.* = SorterState.init(allocator);

        return .{
            .allocator = allocator,
            .engine = engine,
            .program = program.*,
            .registers = registers,
            .row_buffer = row_buffer,
            .series_cursors = series_cursors,
            .sorters = sorters,
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        for (self.series_cursors) |*cursor| cursor.deinit();
        for (self.sorters) |*sorter| sorter.deinit(self.allocator);
        self.allocator.free(self.sorters);
        self.allocator.free(self.series_cursors);
        self.allocator.free(self.registers);
        self.allocator.free(self.row_buffer);
        self.* = undefined;
    }

    pub fn reset(self: *VirtualMachine) void {
        self.pc = 0;
        self.halted = false;
        for (self.registers) |*slot| slot.* = .null;
        for (self.row_buffer) |*slot| slot.* = .null;
        for (self.series_cursors) |*cursor| cursor.reset();
        for (self.sorters) |*sorter| sorter.clear(self.allocator);
    }

    pub fn step(self: *VirtualMachine) VmError!VmStep {
        _ = self.engine;
        while (!self.halted) {
            if (self.pc >= self.program.instructions.len) {
                self.halted = true;
                return .done;
            }

            const instruction = self.program.instructions[self.pc];
            self.pc += 1;
            switch (instruction.opcode) {
                .open_series => try self.executeOpenSeries(instruction),
                .next_point => try self.executeNextPoint(instruction),
                .load_const => try self.executeLoadConst(instruction),
                .column => try self.executeColumn(instruction),
                .function => try self.executeFunction(instruction),
                .compare => try self.executeCompare(instruction),
                .jump => try self.executeJump(instruction.p2),
                .jump_if_false => try self.executeJumpIfFalse(instruction),
                .sorter_open => try self.executeSorterOpen(instruction),
                .sorter_insert => try self.executeSorterInsert(instruction),
                .sorter_next => try self.executeSorterNext(instruction),
                .result_row => return .{ .row = try self.executeResultRow(instruction) },
                .halt => {
                    self.halted = true;
                    return .done;
                },
                else => return error.InvalidOpcode,
            }
        }
        return .done;
    }

    fn executeLoadConst(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const dst = try self.registerPtr(@intCast(instruction.p1));
        const constant_id = switch (instruction.p4) {
            .constant => |id| id,
            else => return error.InvalidConstant,
        };
        if (constant_id >= self.program.constants.len) return error.InvalidConstant;
        dst.* = self.program.constants[constant_id];
    }

    fn executeOpenSeries(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const cursor_id: usize = @intCast(instruction.p1);
        if (cursor_id >= self.series_cursors.len) return error.InvalidRegister;
        const selector_id = switch (instruction.p4) {
            .selector => |id| id,
            else => return error.InvalidConstant,
        };
        if (selector_id >= self.program.selectors.len) return error.InvalidConstant;
        const selector = self.program.selectors[selector_id];
        var cursor = &self.series_cursors[cursor_id];
        cursor.reset();
        try self.engine.queryRange(selector.series_id, instruction.p2, instruction.p3, &cursor.points);
    }

    fn executeNextPoint(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const cursor_id: usize = @intCast(instruction.p1);
        if (cursor_id >= self.series_cursors.len) return error.InvalidRegister;
        var cursor = &self.series_cursors[cursor_id];
        if (cursor.index >= cursor.points.items.len) {
            cursor.current = null;
            try self.executeJump(instruction.p2);
            return;
        }
        cursor.current = cursor.points.items[cursor.index];
        cursor.index += 1;
    }

    fn executeColumn(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const cursor_id: usize = @intCast(instruction.p1);
        if (cursor_id >= self.series_cursors.len) return error.InvalidRegister;
        const point = self.series_cursors[cursor_id].current orelse return error.InvalidOpcode;
        const dst = try self.registerPtr(@intCast(instruction.p3));
        dst.* = switch (instruction.p2) {
            0 => .{ .integer = point.ts },
            1 => .{ .float = point.value },
            else => return error.InvalidOpcode,
        };
    }

    fn executeFunction(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const dst = try self.registerPtr(@intCast(instruction.p1));
        const expr_id = switch (instruction.p4) {
            .expr => |id| id,
            else => return error.InvalidConstant,
        };
        if (expr_id >= self.program.exprs.len) return error.InvalidConstant;
        dst.* = try self.evaluateCurrentExpr(self.program.exprs[expr_id]);
    }

    fn executeCompare(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const lhs = try self.registerValue(@intCast(instruction.p1));
        const rhs = try self.registerValue(@intCast(instruction.p2));
        const dst = try self.registerPtr(@intCast(instruction.p3));
        const kind: bytecode.CompareKind = @enumFromInt(instruction.p5);
        const order = try value_mod.Value.compareNumeric(lhs, rhs);
        dst.* = .{ .boolean = switch (kind) {
            .eq => value_mod.Value.equals(lhs, rhs),
            .ne => !value_mod.Value.equals(lhs, rhs),
            .lt => order == .lt,
            .le => order == .lt or order == .eq,
            .gt => order == .gt,
            .ge => order == .gt or order == .eq,
        } };
    }

    fn executeJump(self: *VirtualMachine, target_raw: i64) VmError!void {
        const target: usize = @intCast(target_raw);
        if (target > self.program.instructions.len) return error.InvalidJumpTarget;
        self.pc = target;
    }

    fn executeJumpIfFalse(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const reg = try self.registerValue(@intCast(instruction.p1));
        const condition = switch (reg) {
            .boolean => |flag| flag,
            .null => false,
            else => return error.InvalidOpcode,
        };
        if (!condition) try self.executeJump(instruction.p2);
    }

    fn executeSorterOpen(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const sorter_id: usize = @intCast(instruction.p1);
        if (sorter_id >= self.sorters.len) return error.InvalidRegister;
        var sorter = &self.sorters[sorter_id];
        sorter.clear(self.allocator);
        sorter.offset = @intCast(@max(instruction.p2, 0));
        sorter.take = if (instruction.p3 < 0) null else @intCast(instruction.p3);
        sorter.ordering_id = switch (instruction.p4) {
            .ordering => |id| id,
            .none => null,
            else => return error.InvalidConstant,
        };
    }

    fn executeSorterInsert(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const sorter_id: usize = @intCast(instruction.p1);
        if (sorter_id >= self.sorters.len) return error.InvalidRegister;
        const start: usize = @intCast(instruction.p2);
        const count: usize = @intCast(instruction.p3);
        if (start + count > self.registers.len) return error.InvalidRegister;

        var sorter = &self.sorters[sorter_id];
        const values = try value_mod.Value.copySlice(self.allocator, self.registers[start .. start + count]);
        errdefer self.allocator.free(values);
        const keys = try self.computeSorterKeys(sorter.ordering_id, values);
        errdefer self.allocator.free(keys);
        try sorter.rows.append(.{
            .values = values,
            .keys = keys,
            .sequence = sorter.next_sequence,
        });
        sorter.next_sequence += 1;
        sorter.sorted = false;
    }

    fn executeSorterNext(self: *VirtualMachine, instruction: bytecode.Instruction) VmError!void {
        const sorter_id: usize = @intCast(instruction.p1);
        if (sorter_id >= self.sorters.len) return error.InvalidRegister;
        var sorter = &self.sorters[sorter_id];
        try self.ensureSorterReady(sorter);
        if (sorter.index < sorter.offset) sorter.index = sorter.offset;
        if (sorter.index >= sorter.rows.items.len) {
            try self.executeJump(instruction.p2);
            return;
        }
        if (sorter.take) |take| {
            if (sorter.index - sorter.offset >= take) {
                try self.executeJump(instruction.p2);
                return;
            }
        }

        const start: usize = @intCast(instruction.p3);
        const row = sorter.rows.items[sorter.index];
        if (start + row.values.len > self.registers.len) return error.InvalidRegister;
        for (row.values, 0..) |value, idx| {
            self.registers[start + idx] = value;
        }
        sorter.index += 1;
    }

    fn executeResultRow(self: *VirtualMachine, instruction: bytecode.Instruction) VmError![]const value_mod.Value {
        const start: usize = @intCast(instruction.p1);
        const count: usize = @intCast(instruction.p2);
        if (start + count > self.registers.len or count > self.row_buffer.len) return error.InvalidRegister;
        for (0..count) |idx| {
            self.row_buffer[idx] = self.registers[start + idx];
        }
        return self.row_buffer[0..count];
    }

    fn registerPtr(self: *VirtualMachine, id: bytecode.RegisterId) VmError!*value_mod.Value {
        if (id >= self.registers.len) return error.InvalidRegister;
        return &self.registers[id];
    }

    fn registerValue(self: *VirtualMachine, id: bytecode.RegisterId) VmError!value_mod.Value {
        if (id >= self.registers.len) return error.InvalidRegister;
        return self.registers[id];
    }

    fn evaluateCurrentExpr(self: *VirtualMachine, expr: *const ast.Expr) VmError!value_mod.Value {
        const point = self.series_cursors[0].current orelse return error.InvalidOpcode;
        const time_expr = ast.Expr{ .identifier = .{ .value = "time", .quoted = false, .span = .{ .start = 0, .end = 0 } } };
        const value_expr = ast.Expr{ .identifier = .{ .value = "value", .quoted = false, .span = .{ .start = 0, .end = 0 } } };
        const schema = [_]plan.ColumnInfo{
            .{ .name = "time", .expr = &time_expr },
            .{ .name = "value", .expr = &value_expr },
        };
        const values = [_]value_mod.Value{
            .{ .integer = point.ts },
            .{ .float = point.value },
        };
        var ctx = expression.RowContext{ .schema = &schema, .values = &values };
        return try expression.evaluateRow(expr, &ctx);
    }

    fn computeSorterKeys(self: *VirtualMachine, ordering_id: ?usize, values: []const value_mod.Value) VmError![]value_mod.Value {
        const resolved_id = ordering_id orelse return self.allocator.alloc(value_mod.Value, 0);
        if (resolved_id >= self.program.orderings.len) return error.InvalidConstant;
        if (self.program.schemas.len == 0) return error.InvalidConstant;
        const ordering = self.program.orderings[resolved_id];
        const keys = try self.allocator.alloc(value_mod.Value, ordering.len);
        errdefer self.allocator.free(keys);
        var ctx = expression.RowContext{
            .schema = self.program.schemas[0],
            .values = values,
        };
        for (ordering, 0..) |order_expr, idx| {
            keys[idx] = try expression.evaluateRow(order_expr.expr, &ctx);
        }
        return keys;
    }

    fn ensureSorterReady(self: *VirtualMachine, sorter: *SorterState) VmError!void {
        if (sorter.sorted) return;
        const SortContext = struct {
            ordering: []const ast.OrderExpr,

            fn lessThan(ctx: @This(), a: SorterRow, b: SorterRow) bool {
                return compareSorterRows(ctx.ordering, a, b) == .lt;
            }
        };

        const ordering = if (sorter.ordering_id) |ordering_id|
            if (ordering_id < self.program.orderings.len) self.program.orderings[ordering_id] else return error.InvalidConstant
        else
            &.{};
        std.sort.pdq(SorterRow, sorter.rows.items, SortContext{ .ordering = ordering }, SortContext.lessThan);
        sorter.sorted = true;
    }
};

fn compareSorterRows(ordering: []const ast.OrderExpr, a: VirtualMachine.SorterRow, b: VirtualMachine.SorterRow) std.math.Order {
    if (ordering.len != 0) {
        for (ordering, 0..) |order_expr, idx| {
            const order = compareValuesForSort(a.keys[idx], b.keys[idx]);
            if (order == .eq) continue;
            return if (order_expr.direction == .desc) invertOrder(order) else order;
        }
    }
    if (a.sequence < b.sequence) return .lt;
    if (a.sequence > b.sequence) return .gt;
    return .eq;
}

fn compareValuesForSort(a: value_mod.Value, b: value_mod.Value) std.math.Order {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);

    if (tag_a == .null and tag_b == .null) return .eq;
    if (tag_a == .null) return .lt;
    if (tag_b == .null) return .gt;

    if ((tag_a == .integer or tag_a == .float or tag_a == .boolean) and
        (tag_b == .integer or tag_b == .float or tag_b == .boolean))
    {
        const left = valueToFloat(a);
        const right = valueToFloat(b);
        if (left < right) return .lt;
        if (left > right) return .gt;
        return .eq;
    }

    if (tag_a == .string and tag_b == .string) {
        return if (std.mem.lessThan(u8, a.string, b.string))
            .lt
        else if (std.mem.lessThan(u8, b.string, a.string))
            .gt
        else
            .eq;
    }

    if (tag_a == .boolean and tag_b == .boolean) {
        if (a.boolean == b.boolean) return .eq;
        return if (!a.boolean and b.boolean) .lt else .gt;
    }

    return .eq;
}

fn valueToFloat(value: value_mod.Value) f64 {
    return switch (value) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .boolean => |b| if (b) 1.0 else 0.0,
        else => 0,
    };
}

fn invertOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

test "virtual machine yields a row and halts" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vm-core", .{tmp.sub_path});
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
    var program = bytecode.Program{
        .allocator = alloc,
        .instructions = instructions,
        .constants = try alloc.dupe(value_mod.Value, &.{value_mod.Value{ .integer = 7 }}),
        .register_count = 1,
    };
    defer program.deinit();

    var machine = try VirtualMachine.init(alloc, engine, &program);
    defer machine.deinit();

    const first = try machine.step();
    try std.testing.expect(first == .row);
    try std.testing.expectEqual(@as(i64, 7), first.row[0].integer);
    try std.testing.expect((try machine.step()) == .done);
}
