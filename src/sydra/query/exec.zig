const std = @import("std");

const parser = @import("parser.zig");
const validator = @import("validator.zig");
const plan_builder = @import("plan.zig");
const optimizer = @import("optimizer.zig");
const physical = @import("physical.zig");
const executor = @import("executor.zig");
const cfg = @import("../config.zig");
const engine_mod = @import("../engine.zig");

pub const ExecuteError = parser.ParseError || validator.AnalyzeError || plan_builder.BuildError || optimizer.OptimizeError || physical.BuildError || executor.ExecuteError || std.mem.Allocator.Error || error{ValidationFailed};

pub fn execute(allocator: std.mem.Allocator, engine: *engine_mod.Engine, query: []const u8) ExecuteError!executor.ExecutionCursor {
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

    var builder = plan_builder.Builder.init(arena_ptr.allocator());
    const logical_plan = try builder.build(&statement);
    const optimized_plan = try optimizer.optimize(arena_ptr.allocator(), logical_plan);
    const t_optimize = std.time.microTimestamp();
    const physical_plan = try physical.build(arena_ptr.allocator(), optimized_plan);
    const t_physical = std.time.microTimestamp();
    var exec = executor.Executor.init(allocator, engine, physical_plan);
    defer exec.deinit();
    const pipeline_start = std.time.microTimestamp();
    var cursor = try exec.run();
    const pipeline_end = std.time.microTimestamp();

    const trace_id = try randomTraceId(arena_ptr.allocator());

    cursor.stats = .{
        .parse_us = @as(u64, @intCast(t_parse - t_start)),
        .validate_us = @as(u64, @intCast(t_validate - t_parse)),
        .optimize_us = @as(u64, @intCast(t_optimize - t_validate)),
        .physical_us = @as(u64, @intCast(t_physical - t_optimize)),
        .pipeline_us = @as(u64, @intCast(pipeline_end - pipeline_start)),
        .trace_id = trace_id,
    };
    cursor.arena = arena_ptr;
    arena_cleanup = false;
    return cursor;
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
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try engine_mod.Engine.init(talloc, config);
    defer engine.deinit();

    var cursor = try execute(talloc, engine, "select 1");
    defer cursor.deinit();

    try std.testing.expectEqual(@as(usize, 1), cursor.columns.len);

    const first = try cursor.next();
    try std.testing.expect(first != null);
    const row = first.?;
    try std.testing.expectEqual(@as(usize, 1), row.values.len);
    try std.testing.expect(executor.Value.equals(row.values[0], executor.Value{ .integer = 1 }));

    const second = try cursor.next();
    try std.testing.expect(second == null);
}
