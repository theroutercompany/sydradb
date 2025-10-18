const std = @import("std");

const physical = @import("physical.zig");
const engine_mod = @import("../engine.zig");
const plan = @import("plan.zig");
const operator = @import("operator.zig");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;

pub const ExecuteError = operator.ExecuteError;

pub const ExecutionStats = struct {
    parse_us: u64 = 0,
    validate_us: u64 = 0,
    optimize_us: u64 = 0,
    physical_us: u64 = 0,
    pipeline_us: u64 = 0,
    trace_id: []const u8 = "",
};

pub const ExecutionCursor = struct {
    allocator: std.mem.Allocator,
    operator: *operator.Operator,
    columns: []const plan.ColumnInfo,
    arena: ?*std.heap.ArenaAllocator = null,
    stats: ExecutionStats = .{},

    pub fn next(self: *ExecutionCursor) ExecuteError!?operator.Row {
        return self.operator.next();
    }

    pub fn deinit(self: *ExecutionCursor) void {
        self.operator.destroy();
        if (self.arena) |arena_ptr| {
            arena_ptr.deinit();
            self.allocator.destroy(arena_ptr);
            self.arena = null;
        }
    }
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    plan: physical.PhysicalPlan,

    pub fn init(allocator: std.mem.Allocator, engine: *engine_mod.Engine, physical_plan: physical.PhysicalPlan) Executor {
        return .{ .allocator = allocator, .engine = engine, .plan = physical_plan };
    }

    pub fn deinit(self: *Executor) void {
        _ = self;
    }

    pub fn run(self: *Executor) ExecuteError!ExecutionCursor {
        const op = try operator.buildPipeline(self.allocator, self.engine, self.plan.root);
        const columns = physical.nodeOutput(self.plan.root);
        return ExecutionCursor{
            .allocator = self.allocator,
            .operator = op,
            .columns = columns,
            .arena = null,
            .stats = .{},
        };
    }
};
