const std = @import("std");
const sydra = @import("sydra_tooling");

const cfg = sydra.config;
const crash_injection = sydra.crash_injection;
const Engine = sydra.engine.Engine;

const metric = "market.crash.matrix";
const labels = "{\"symbol\":\"CRASH\",\"venue\":\"TEST\"}";
const columns = [_][]const u8{ "price", "size" };
const baseline_rows: usize = 4;
const timestamp_origin_ns: i64 = 1_700_000_000_000_000_000;

const Phase = enum {
    exercise,
    verify,
};

const Options = struct {
    phase: Phase,
    crash_point: crash_injection.Point,
    iteration: u32,
    case_dir: []u8,
    fsync_policy: cfg.FsyncPolicy,

    fn deinit(self: *Options, alloc: std.mem.Allocator) void {
        alloc.free(self.case_dir);
        self.* = undefined;
    }
};

const ExerciseState = struct {
    schema_version: u32 = 1,
    crash_point: []const u8,
    iteration: u32,
    fsync_policy: []const u8,
    base_ts_ns: i64,
    target_ts_ns: i64,
    acknowledged_rows: usize,
    target_acknowledged: bool,
    documented_loss_bound_rows: usize,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    var options = parseArgs(alloc) catch |err| {
        printUsage();
        return err;
    };
    defer options.deinit(alloc);

    switch (options.phase) {
        .exercise => try exercise(alloc, options),
        .verify => try verify(alloc, options),
    }
}

fn parseArgs(alloc: std.mem.Allocator) !Options {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    const phase_text = args.next() orelse return error.InvalidArgs;
    const phase: Phase = if (std.mem.eql(u8, phase_text, "exercise"))
        .exercise
    else if (std.mem.eql(u8, phase_text, "verify"))
        .verify
    else
        return error.InvalidArgs;

    var crash_point: ?crash_injection.Point = null;
    var iteration: ?u32 = null;
    var case_dir: ?[]u8 = null;
    errdefer if (case_dir) |path| alloc.free(path);
    var fsync_policy: ?cfg.FsyncPolicy = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--crash-point")) {
            if (crash_point != null) return error.InvalidArgs;
            crash_point = try crash_injection.Point.parse(args.next() orelse return error.InvalidArgs);
        } else if (std.mem.eql(u8, arg, "--iteration")) {
            if (iteration != null) return error.InvalidArgs;
            iteration = try std.fmt.parseInt(u32, args.next() orelse return error.InvalidArgs, 10);
            if (iteration.? == 0) return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--case-dir")) {
            if (case_dir != null) return error.InvalidArgs;
            case_dir = try alloc.dupe(u8, args.next() orelse return error.InvalidArgs);
        } else if (std.mem.eql(u8, arg, "--fsync")) {
            if (fsync_policy != null) return error.InvalidArgs;
            fsync_policy = try parseFsyncPolicy(args.next() orelse return error.InvalidArgs);
        } else {
            return error.InvalidArgs;
        }
    }

    return .{
        .phase = phase,
        .crash_point = crash_point orelse return error.InvalidArgs,
        .iteration = iteration orelse return error.InvalidArgs,
        .case_dir = case_dir orelse return error.InvalidArgs,
        .fsync_policy = fsync_policy orelse return error.InvalidArgs,
    };
}

fn printUsage() void {
    std.debug.print(
        \\Usage: native_market_crash_driver exercise|verify
        \\       --crash-point after_registration|after_wal_append|after_memtable_append|
        \\                     after_segment_creation|after_manifest_update|
        \\                     after_cas_object_write|after_ref_update
        \\       --iteration N --case-dir PATH --fsync always|interval|none
        \\
    , .{});
}

fn parseFsyncPolicy(value: []const u8) !cfg.FsyncPolicy {
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "interval")) return .interval;
    if (std.mem.eql(u8, value, "none")) return .none;
    return error.InvalidFsyncPolicy;
}

fn makeConfig(
    alloc: std.mem.Allocator,
    data_path: []const u8,
    fsync_policy: cfg.FsyncPolicy,
) !cfg.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = fsync_policy,
        .flush_interval_ms = std.math.maxInt(u32),
        .memtable_max_bytes = std.math.maxInt(usize),
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 128 * 1024 * 1024,
        .cas_mode = .dual_write,
        .metadata_read_mode = .legacy,
        .query_compiler_mode = .compiled,
        .market_storage_mode = .dual_write_v1,
        .market_storage_read_mode = .shadow,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

fn exercise(alloc: std.mem.Allocator, options: Options) !void {
    const data_path = try std.fmt.allocPrint(alloc, "{s}/repository", .{options.case_dir});
    defer alloc.free(data_path);
    const state_path = try std.fmt.allocPrint(alloc, "{s}/exercise-state.json", .{options.case_dir});
    defer alloc.free(state_path);

    try ensureStateAbsent(state_path);
    try std.fs.cwd().makePath(data_path);

    const config = try makeConfig(alloc, data_path, options.fsync_policy);
    var engine = try Engine.init(alloc, config);
    defer engine.deinit();

    var schema = try engine.registerMarketSchemaWithStorageMappingOverride(.{
        .metric = metric,
        .ordered_columns = columns[0..],
        .required_labels = &.{"symbol"},
        .storage_mapping = .native_v1,
    }, .native_v1);
    defer schema.deinit(alloc);

    const base_ts_ns = caseBaseTimestamp(options.iteration);
    var baseline_values: [baseline_rows][columns.len]f64 = undefined;
    var baseline_inputs: [baseline_rows]Engine.MarketIngestInput = undefined;
    for (0..baseline_rows) |idx| {
        baseline_values[idx] = expectedValues(idx);
        baseline_inputs[idx] = .{
            .metric = metric,
            .labels_json = labels,
            .ts_ns = base_ts_ns + @as(i64, @intCast(idx)),
            .values = baseline_values[idx][0..],
        };
    }
    const baseline_receipt = try engine.ingestMarketBatch(baseline_inputs[0..]);
    if (baseline_receipt.accepted_rows != baseline_rows) return error.BaselineIngestMismatch;
    _ = try engine.flushNow();
    try engine.verifyCasState();

    const target_ts_ns = base_ts_ns + @as(i64, @intCast(baseline_rows));
    const target_values = expectedValues(baseline_rows);
    const target_input = [_]Engine.MarketIngestInput{.{
        .metric = metric,
        .labels_json = labels,
        .ts_ns = target_ts_ns,
        .values = target_values[0..],
    }};
    const target_acknowledged = crashAfterAcknowledgement(options.crash_point);

    if (target_acknowledged) {
        const receipt = try engine.ingestMarketBatch(target_input[0..]);
        if (receipt.accepted_rows != 1) return error.TargetIngestMismatch;
    }

    const acknowledged_rows = baseline_rows + @intFromBool(target_acknowledged);
    const loss_bound = documentedLossBound(
        options.fsync_policy,
        target_acknowledged,
        acknowledged_rows,
    );
    try writeExerciseState(state_path, .{
        .crash_point = @tagName(options.crash_point),
        .iteration = options.iteration,
        .fsync_policy = @tagName(options.fsync_policy),
        .base_ts_ns = base_ts_ns,
        .target_ts_ns = target_ts_ns,
        .acknowledged_rows = acknowledged_rows,
        .target_acknowledged = target_acknowledged,
        .documented_loss_bound_rows = loss_bound,
    });

    crash_injection.arm(options.crash_point);
    if (target_acknowledged) {
        _ = try engine.flushNow();
    } else {
        _ = try engine.ingestMarketBatch(target_input[0..]);
    }
    crash_injection.disarm();
    return error.CrashPointNotReached;
}

fn verify(alloc: std.mem.Allocator, options: Options) !void {
    const data_path = try std.fmt.allocPrint(alloc, "{s}/repository", .{options.case_dir});
    defer alloc.free(data_path);
    const state_path = try std.fmt.allocPrint(alloc, "{s}/exercise-state.json", .{options.case_dir});
    defer alloc.free(state_path);
    const evidence_path = try std.fmt.allocPrint(alloc, "{s}/verify-evidence.json", .{options.case_dir});
    defer alloc.free(evidence_path);

    const state_bytes = try std.fs.cwd().readFileAlloc(alloc, state_path, 64 * 1024);
    defer alloc.free(state_bytes);
    var parsed = try std.json.parseFromSlice(ExerciseState, alloc, state_bytes, .{});
    defer parsed.deinit();
    const state = parsed.value;
    try validateState(state, options);

    const config = try makeConfig(alloc, data_path, options.fsync_policy);
    var engine = try Engine.init(alloc, config);
    defer engine.deinit();

    var integrity_errors: usize = 0;
    engine.verifyCasState() catch {
        integrity_errors += 1;
    };

    var result = try engine.queryMarket(.{
        .metric = metric,
        .label_filter_json = labels,
        .start_ts_ns = state.base_ts_ns,
        .end_ts_ns = state.target_ts_ns,
    });
    defer result.deinit();

    var recovered_acknowledged_rows: usize = 0;
    for (0..state.acknowledged_rows) |idx| {
        const expected_ts = state.base_ts_ns + @as(i64, @intCast(idx));
        const values = expectedValues(idx);
        if (findExactRow(result.rows, expected_ts, values)) {
            recovered_acknowledged_rows += 1;
        } else {
            integrity_errors += 1;
        }
    }
    const target_values = expectedValues(baseline_rows);
    const unacknowledged_target_recovered =
        !state.target_acknowledged and
        findExactRow(result.rows, state.target_ts_ns, target_values);
    const acknowledged_row_loss =
        state.acknowledged_rows - recovered_acknowledged_rows;

    try writeVerifyEvidence(evidence_path, .{
        .crash_point = state.crash_point,
        .iteration = state.iteration,
        .fsync_policy = state.fsync_policy,
        .acknowledged_rows = state.acknowledged_rows,
        .recovered_acknowledged_rows = recovered_acknowledged_rows,
        .acknowledged_row_loss = acknowledged_row_loss,
        .documented_loss_bound_rows = state.documented_loss_bound_rows,
        .integrity_errors = integrity_errors,
        .shadow_mismatches = result.stats.shadow_mismatches,
        .recovered_total_rows = result.rows.len,
        .unacknowledged_target_recovered = unacknowledged_target_recovered,
    });
}

fn caseBaseTimestamp(iteration: u32) i64 {
    return timestamp_origin_ns +
        @as(i64, @intCast(iteration)) * std.time.ns_per_ms;
}

fn expectedValues(row_index: usize) [columns.len]f64 {
    return .{
        100.0 + @as(f64, @floatFromInt(row_index)),
        10.0 + @as(f64, @floatFromInt(row_index)),
    };
}

fn crashAfterAcknowledgement(point: crash_injection.Point) bool {
    return switch (point) {
        .after_registration,
        .after_wal_append,
        .after_memtable_append,
        => false,
        .after_segment_creation,
        .after_manifest_update,
        .after_cas_object_write,
        .after_ref_update,
        => true,
    };
}

fn documentedLossBound(
    fsync_policy: cfg.FsyncPolicy,
    target_acknowledged: bool,
    acknowledged_rows: usize,
) usize {
    return switch (fsync_policy) {
        .always => 0,
        .interval => @intFromBool(target_acknowledged),
        .none => acknowledged_rows,
    };
}

fn findExactRow(
    rows: []const Engine.MarketQueryRow,
    expected_ts_ns: i64,
    expected_values: [columns.len]f64,
) bool {
    for (rows) |row| {
        if (row.ts_ns != expected_ts_ns or row.values.len != columns.len) continue;
        var matches = true;
        for (row.values, expected_values) |actual, expected| {
            if (@as(u64, @bitCast(actual)) != @as(u64, @bitCast(expected))) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn validateState(state: ExerciseState, options: Options) !void {
    if (state.schema_version != 1 or
        !std.mem.eql(u8, state.crash_point, @tagName(options.crash_point)) or
        state.iteration != options.iteration or
        !std.mem.eql(u8, state.fsync_policy, @tagName(options.fsync_policy)) or
        state.acknowledged_rows < baseline_rows or
        state.acknowledged_rows > baseline_rows + 1 or
        state.target_acknowledged != crashAfterAcknowledgement(options.crash_point))
    {
        return error.InvalidExerciseState;
    }
}

fn ensureStateAbsent(path: []const u8) !void {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    file.close();
    return error.CaseAlreadyExercised;
}

fn writeExerciseState(path: []const u8, state: ExerciseState) !void {
    var output = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer output.deinit();
    var writer = output.writer();
    var scratch: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&scratch);
    const iface = &adapter.new_interface;
    var stringify = std.json.Stringify{ .writer = iface };
    try stringify.write(state);
    try iface.flush();
    if (adapter.err) |err| return err;
    try writer.writeByte('\n');
    try writeSyncedFile(path, output.items);
}

const VerifyEvidence = struct {
    schema_version: u32 = 1,
    crash_point: []const u8,
    iteration: u32,
    fsync_policy: []const u8,
    recovery_completed: bool = true,
    acknowledged_rows: usize,
    recovered_acknowledged_rows: usize,
    acknowledged_row_loss: usize,
    documented_loss_bound_rows: usize,
    integrity_errors: usize,
    shadow_mismatches: usize,
    recovered_total_rows: usize,
    unacknowledged_target_recovered: bool,
};

fn writeVerifyEvidence(path: []const u8, evidence: VerifyEvidence) !void {
    var output = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer output.deinit();
    var writer = output.writer();
    var scratch: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&scratch);
    const iface = &adapter.new_interface;
    var stringify = std.json.Stringify{ .writer = iface };
    try stringify.write(evidence);
    try iface.flush();
    if (adapter.err) |err| return err;
    try writer.writeByte('\n');
    try writeSyncedFile(path, output.items);
}

fn writeSyncedFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

test "crash acknowledgement boundary is explicit" {
    try std.testing.expect(!crashAfterAcknowledgement(.after_registration));
    try std.testing.expect(!crashAfterAcknowledgement(.after_wal_append));
    try std.testing.expect(!crashAfterAcknowledgement(.after_memtable_append));
    try std.testing.expect(crashAfterAcknowledgement(.after_segment_creation));
    try std.testing.expect(crashAfterAcknowledgement(.after_manifest_update));
    try std.testing.expect(crashAfterAcknowledgement(.after_cas_object_write));
    try std.testing.expect(crashAfterAcknowledgement(.after_ref_update));
}

test "documented crash windows respect fsync policy" {
    try std.testing.expectEqual(@as(usize, 0), documentedLossBound(.always, true, 5));
    try std.testing.expectEqual(@as(usize, 0), documentedLossBound(.interval, false, 4));
    try std.testing.expectEqual(@as(usize, 1), documentedLossBound(.interval, true, 5));
    try std.testing.expectEqual(@as(usize, 5), documentedLossBound(.none, true, 5));
}
