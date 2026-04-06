const std = @import("std");

const ScenarioMetrics = struct {
    name: []const u8,
    class: ?[]const u8 = null,
    direct_engine_pps: ?f64 = null,
    http_ndjson_pps: ?f64 = null,
    uds_binary_warm_pps: ?f64 = null,
    uds_binary_cold_pps: ?f64 = null,
};

const known_scenarios = [_][]const u8{
    "one_hot_one_writer",
    "fanout_four_writers",
    "warm_declared_10k",
    "cold_declare_10k",
    "steady_state_100k",
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const input_path = try parseArgs(alloc);
    defer if (input_path) |path| alloc.free(path);

    const input = if (input_path) |path|
        try std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024)
    else
        try readAllStdin(alloc);
    defer alloc.free(input);

    var scenarios: [known_scenarios.len]ScenarioMetrics = undefined;
    for (known_scenarios, 0..) |name, idx| scenarios[idx] = .{ .name = name };

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "scenario=")) continue;
        try parseScenarioLine(line, scenarios[0..]);
    }

    var failed = false;
    failed = !(try evaluateTransportScenario("one_hot_one_writer", &scenarios, 0.75, 1.5)) or failed;
    failed = !(try evaluateTransportScenario("fanout_four_writers", &scenarios, 0.75, 1.5)) or failed;
    failed = !(try evaluateTransportScenario("steady_state_100k", &scenarios, 0.75, 1.5)) or failed;
    failed = !(try evaluateStorageScenario("warm_declared_10k", "uds_binary_warm", &scenarios, 0.90)) or failed;
    failed = !(try evaluateStorageScenario("cold_declare_10k", "uds_binary_cold", &scenarios, 0.90)) or failed;

    if (failed) return error.PreviewGatesFailed;
}

fn parseArgs(alloc: std.mem.Allocator) !?[]u8 {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    var input_path: ?[]u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input")) {
            const value = args.next() orelse return error.InvalidArgs;
            input_path = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: check_local_ingest_preview [--input <path>]\n", .{});
            std.process.exit(0);
        } else {
            return error.InvalidArgs;
        }
    }
    return input_path;
}

fn readAllStdin(alloc: std.mem.Allocator) ![]u8 {
    var stdin = std.fs.File.stdin();
    var buf: [8192]u8 = undefined;
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();

    while (true) {
        const read_len = try stdin.read(buf[0..]);
        if (read_len == 0) break;
        try out.appendSlice(buf[0..read_len]);
    }
    return try out.toOwnedSlice();
}

fn parseScenarioLine(line: []const u8, scenarios: []ScenarioMetrics) !void {
    var scenario_name: ?[]const u8 = null;
    var class_name: ?[]const u8 = null;
    var transport_name: ?[]const u8 = null;
    var points_per_sec: ?f64 = null;

    var tokens = std.mem.splitScalar(u8, line, ' ');
    while (tokens.next()) |token| {
        if (std.mem.indexOfScalar(u8, token, '=')) |eq_idx| {
            const key = token[0..eq_idx];
            const value = token[eq_idx + 1 ..];
            if (std.mem.eql(u8, key, "scenario")) {
                scenario_name = value;
            } else if (std.mem.eql(u8, key, "class")) {
                class_name = value;
            } else if (std.mem.eql(u8, key, "transport")) {
                transport_name = value;
            } else if (std.mem.eql(u8, key, "points_per_sec")) {
                points_per_sec = try std.fmt.parseFloat(f64, value);
            }
        }
    }

    const name = scenario_name orelse return error.InvalidBenchmarkLine;
    const transport = transport_name orelse return error.InvalidBenchmarkLine;
    const pps = points_per_sec orelse return error.InvalidBenchmarkLine;

    for (scenarios) |*scenario| {
        if (!std.mem.eql(u8, scenario.name, name)) continue;
        scenario.class = class_name;
        if (std.mem.eql(u8, transport, "direct_engine")) {
            scenario.direct_engine_pps = pps;
        } else if (std.mem.eql(u8, transport, "http_ndjson")) {
            scenario.http_ndjson_pps = pps;
        } else if (std.mem.eql(u8, transport, "uds_binary_warm")) {
            scenario.uds_binary_warm_pps = pps;
        } else if (std.mem.eql(u8, transport, "uds_binary_cold")) {
            scenario.uds_binary_cold_pps = pps;
        }
        return;
    }
}

fn evaluateTransportScenario(
    scenario_name: []const u8,
    scenarios: []const ScenarioMetrics,
    direct_floor_ratio: f64,
    http_multiplier: f64,
) !bool {
    const scenario = findScenario(scenarios, scenario_name) orelse return error.MissingScenario;
    const direct = scenario.direct_engine_pps orelse return error.MissingTransport;
    const http = scenario.http_ndjson_pps orelse return error.MissingTransport;
    const uds = scenario.uds_binary_warm_pps orelse return error.MissingTransport;

    const direct_ratio = uds / direct;
    const http_ratio = uds / http;
    const pass = direct_ratio >= direct_floor_ratio and http_ratio >= http_multiplier;
    std.debug.print(
        "gate scenario={s} class=transport_bound uds_vs_direct={d:.3} threshold={d:.3} uds_vs_http={d:.3} threshold={d:.3} result={s}\n",
        .{
            scenario_name,
            direct_ratio,
            direct_floor_ratio,
            http_ratio,
            http_multiplier,
            if (pass) "pass" else "fail",
        },
    );
    return pass;
}

fn evaluateStorageScenario(
    scenario_name: []const u8,
    uds_transport: []const u8,
    scenarios: []const ScenarioMetrics,
    direct_floor_ratio: f64,
) !bool {
    const scenario = findScenario(scenarios, scenario_name) orelse return error.MissingScenario;
    const direct = scenario.direct_engine_pps orelse return error.MissingTransport;
    const uds = if (std.mem.eql(u8, uds_transport, "uds_binary_warm"))
        scenario.uds_binary_warm_pps orelse return error.MissingTransport
    else if (std.mem.eql(u8, uds_transport, "uds_binary_cold"))
        scenario.uds_binary_cold_pps orelse return error.MissingTransport
    else
        return error.InvalidArgs;

    const direct_ratio = uds / direct;
    const pass = direct_ratio >= direct_floor_ratio;
    std.debug.print(
        "gate scenario={s} class=storage_bound transport={s} uds_vs_direct={d:.3} threshold={d:.3} result={s}\n",
        .{
            scenario_name,
            uds_transport,
            direct_ratio,
            direct_floor_ratio,
            if (pass) "pass" else "fail",
        },
    );
    return pass;
}

fn findScenario(scenarios: []const ScenarioMetrics, scenario_name: []const u8) ?*const ScenarioMetrics {
    for (scenarios) |*scenario| {
        if (std.mem.eql(u8, scenario.name, scenario_name)) return scenario;
    }
    return null;
}
