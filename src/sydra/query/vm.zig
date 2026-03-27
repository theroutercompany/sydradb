const std = @import("std");

const bytecode = @import("bytecode.zig");
const engine_mod = @import("../engine.zig");
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
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    program: *const bytecode.Program,
    registers: []value_mod.Value,
    row_buffer: []value_mod.Value,
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

        return .{
            .allocator = allocator,
            .engine = engine,
            .program = program,
            .registers = registers,
            .row_buffer = row_buffer,
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.allocator.free(self.registers);
        self.allocator.free(self.row_buffer);
        self.* = undefined;
    }

    pub fn reset(self: *VirtualMachine) void {
        self.pc = 0;
        self.halted = false;
        for (self.registers) |*slot| slot.* = .null;
        for (self.row_buffer) |*slot| slot.* = .null;
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
                .load_const => try self.executeLoadConst(instruction),
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
