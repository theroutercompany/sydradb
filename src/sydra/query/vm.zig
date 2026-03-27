const std = @import("std");

const bytecode = @import("bytecode.zig");
const engine_mod = @import("../engine.zig");
const types = @import("../types.zig");
const value_mod = @import("value.zig");

pub const VmError = value_mod.ConvertError || error{
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

    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    program: *const bytecode.Program,
    registers: []value_mod.Value,
    row_buffer: []value_mod.Value,
    series_cursors: []SeriesCursorState,
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

        return .{
            .allocator = allocator,
            .engine = engine,
            .program = program,
            .registers = registers,
            .row_buffer = row_buffer,
            .series_cursors = series_cursors,
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        for (self.series_cursors) |*cursor| cursor.deinit();
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
                .compare => try self.executeCompare(instruction),
                .jump => try self.executeJump(instruction.p2),
                .jump_if_false => try self.executeJumpIfFalse(instruction),
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
};

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

    var machine = try VirtualMachine.init(alloc, &engine, &program);
    defer machine.deinit();

    const first = try machine.step();
    try std.testing.expect(first == .row);
    try std.testing.expectEqual(@as(i64, 7), first.row[0].integer);
    try std.testing.expect((try machine.step()) == .done);
}
