const std = @import("std");
const build_options = @import("build_options");
const sydra = @import("sydra_tooling");
const cfg = sydra.config;
const Engine = sydra.engine.Engine;
const types = sydra.types;
const ingest_service = sydra.ingest_service;
const ingest_socket = sydra.ingest_socket;

const SeriesSpec = struct {
    index: usize,
    name: []u8,
    canonical_tags: []u8,
};

const Scenario = struct {
    name: []const u8,
    description: []const u8,
    series_count: usize,
    writers: usize,
    points_per_writer: usize,
    warm_socket: bool,
};

const scenarios = [_]Scenario{
    .{
        .name = "one_hot_one_writer",
        .description = "1 series, 1 writer, warm socket cache",
        .series_count = 1,
        .writers = 1,
        .points_per_writer = 10_000,
        .warm_socket = true,
    },
    .{
        .name = "fanout_four_writers",
        .description = "100 series, 4 writers, warm socket cache",
        .series_count = 100,
        .writers = 4,
        .points_per_writer = 2_500,
        .warm_socket = true,
    },
    .{
        .name = "warm_declared_10k",
        .description = "10k declared series with steady-state socket append",
        .series_count = 10_000,
        .writers = 1,
        .points_per_writer = 10_000,
        .warm_socket = true,
    },
    .{
        .name = "cold_declare_10k",
        .description = "10k declaration burst followed by append",
        .series_count = 10_000,
        .writers = 1,
        .points_per_writer = 10_000,
        .warm_socket = false,
    },
    .{
        .name = "steady_state_100k",
        .description = "100k warm-declared points to measure sustained same-host append",
        .series_count = 1,
        .writers = 1,
        .points_per_writer = 100_000,
        .warm_socket = true,
    },
};

const TransportMetrics = struct {
    queue_pending_bytes_max: usize = 0,
    local_ingest_declare_batches_total: u64 = 0,
    local_ingest_declare_total: u64 = 0,
    local_ingest_declare_seconds_total: f64 = 0,
    local_ingest_append_batches_total: u64 = 0,
    local_ingest_append_points_total: u64 = 0,
    local_ingest_append_seconds_total: f64 = 0,
    local_ingest_append_batch_points_max: usize = 0,
    local_ingest_rejected_total: u64 = 0,
};

const BenchmarkResult = struct {
    transport: []const u8,
    points: usize,
    elapsed_ns: u64,
    metrics: TransportMetrics = .{},
};

const DirectWorkerContext = struct {
    eng: *Engine,
    series_ids: []const types.SeriesId,
    points: usize,
    writer_idx: usize,
    batch_size: usize,
};

const CliWorkerContext = struct {
    eng: *Engine,
    specs: []const SeriesSpec,
    points: usize,
    writer_idx: usize,
};

const HttpWorkerContext = struct {
    alloc: std.mem.Allocator,
    port: u16,
    body_path: []const u8,
};

const SocketWorkerState = struct {
    alloc: std.mem.Allocator,
    client: ingest_socket.Client,
    specs: []const SeriesSpec,
    points: usize,
    writer_idx: usize,
    declared: ?[]ingest_socket.ClientDeclaration = null,
    inputs: ?[]ingest_socket.ClientDeclareInput = null,

    fn deinit(self: *SocketWorkerState) void {
        if (self.declared) |declared| self.alloc.free(declared);
        if (self.inputs) |inputs| self.alloc.free(inputs);
        self.client.deinit();
        self.* = undefined;
    }
};

const ServerProcess = struct {
    alloc: std.mem.Allocator,
    repo_root: []const u8,
    workdir: []u8,
    child: std.process.Child,
    http_port: u16,
    socket_path: ?[]u8 = null,

    fn deinit(self: *ServerProcess) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        if (self.socket_path) |path| self.alloc.free(path);
        std.fs.cwd().deleteTree(self.workdir) catch {};
        self.alloc.free(self.workdir);
        self.alloc.free(self.repo_root);
    }
};

fn makeConfig(alloc: std.mem.Allocator, data_dir: []const u8) !cfg.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_dir),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 8 * 1024 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 512 * 1024 * 1024,
        .cas_mode = .off,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

fn buildSeriesSpecs(alloc: std.mem.Allocator, series_count: usize) ![]SeriesSpec {
    const specs = try alloc.alloc(SeriesSpec, series_count);
    errdefer {
        for (specs[0..series_count]) |spec| {
            alloc.free(spec.name);
            alloc.free(spec.canonical_tags);
        }
        alloc.free(specs);
    }
    for (specs, 0..) |*spec, idx| {
        spec.* = .{
            .index = idx,
            .name = try std.fmt.allocPrint(alloc, "bench.metric.{d}", .{idx}),
            .canonical_tags = try std.fmt.allocPrint(alloc, "{{\"slot\":\"{d}\"}}", .{idx}),
        };
    }
    return specs;
}

fn freeSeriesSpecs(alloc: std.mem.Allocator, specs: []SeriesSpec) void {
    for (specs) |spec| {
        alloc.free(spec.name);
        alloc.free(spec.canonical_tags);
    }
    alloc.free(specs);
}

fn parseArgs(alloc: std.mem.Allocator) !?[]const u8 {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    var selected: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scenario")) {
            selected = args.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: bench_ingest_transport [--scenario <name>]
                \\
                \\Scenarios:
                \\  one_hot_one_writer
                \\  fanout_four_writers
                \\  warm_declared_10k
                \\  cold_declare_10k
                \\  steady_state_100k
                \\
            , .{});
            std.process.exit(0);
        } else {
            return error.InvalidArgs;
        }
    }
    return selected;
}

fn scenarioMatches(selected: ?[]const u8, scenario: Scenario) bool {
    return selected == null or std.mem.eql(u8, selected.?, scenario.name);
}

fn partitionSeries(total: usize, writers: usize, writer_idx: usize) struct { start: usize, count: usize } {
    const base = total / writers;
    const rem = total % writers;
    const count = base + @intFromBool(writer_idx < rem);
    const start = writer_idx * base + @min(writer_idx, rem);
    return .{ .start = start, .count = @max(count, 1) };
}

fn directWorker(ctx: DirectWorkerContext) void {
    const alloc = std.heap.c_allocator;
    const frame_cap = @min(ctx.batch_size, ctx.points);
    const batch = alloc.alloc(Engine.ResolvedIngestPoint, @max(frame_cap, 1)) catch @panic("direct worker alloc failed");
    defer alloc.free(batch);

    const start_ts = @as(i64, @intCast(ctx.writer_idx)) * 1_000_000;
    var emitted: usize = 0;
    while (emitted < ctx.points) {
        const remaining = ctx.points - emitted;
        const take = @min(batch.len, remaining);
        for (0..take) |idx| {
            const global_idx = emitted + idx;
            const series_id = ctx.series_ids[global_idx % ctx.series_ids.len];
            batch[idx] = .{
                .series_id = series_id,
                .ts = start_ts + @as(i64, @intCast(global_idx)),
                .value = @as(f64, @floatFromInt(global_idx)),
            };
        }
        _ = ctx.eng.appendResolvedBatch(batch[0..take]) catch |err| {
            std.debug.panic("direct append failed: {s}", .{@errorName(err)});
        };
        emitted += take;
    }
}

fn cliWorker(ctx: CliWorkerContext) void {
    const alloc = std.heap.c_allocator;
    var line_buf: [256]u8 = undefined;
    const start_ts = @as(i64, @intCast(ctx.writer_idx)) * 1_000_000;
    for (0..ctx.points) |idx| {
        const spec = ctx.specs[idx % ctx.specs.len];
        const line = std.fmt.bufPrint(
            &line_buf,
            "{{\"series\":\"{s}\",\"ts\":{d},\"value\":{d},\"tags\":{{\"slot\":\"{d}\"}}}}",
            .{ spec.name, start_ts + @as(i64, @intCast(idx)), idx, spec.index },
        ) catch @panic("cli line formatting failed");
        const parsed = ingest_service.parseIngestLine(alloc, line) catch |err| {
            std.debug.panic("cli parse failed: {s}", .{@errorName(err)});
        };
        defer parsed.deinit(alloc);
        _ = ingest_service.applyParsedIngestLine(ctx.eng, parsed) catch |err| {
            std.debug.panic("cli apply failed: {s}", .{@errorName(err)});
        };
    }
}

fn httpWorker(ctx: HttpWorkerContext) void {
    const response = curlRequest(ctx.alloc, ctx.port, "/api/v1/ingest", .{
        .method = "POST",
        .content_type = "application/x-ndjson",
        .body_path = ctx.body_path,
    }) catch |err| {
        std.debug.panic("http ingest failed: {s}", .{@errorName(err)});
    };
    defer ctx.alloc.free(response.body);
    if (response.status_code != 200) {
        std.debug.panic("unexpected HTTP ingest status {d}: {s}", .{ response.status_code, response.body });
    }
}

fn socketWorker(state: *SocketWorkerState) void {
    if (state.declared == null) {
        state.declared = state.client.declareCachedBatch(state.inputs.?) catch |err| {
            std.debug.panic("socket declare failed: {s}", .{@errorName(err)});
        };
    }

    const declared = state.declared.?;
    const alloc = std.heap.c_allocator;
    const batch = alloc.alloc(ingest_socket.AppendEntry, 256) catch @panic("socket batch alloc failed");
    defer alloc.free(batch);

    const start_ts = @as(i64, @intCast(state.writer_idx)) * 1_000_000;
    var emitted: usize = 0;
    while (emitted < state.points) {
        const remaining = state.points - emitted;
        const take = @min(batch.len, remaining);
        for (0..take) |idx| {
            const global_idx = emitted + idx;
            batch[idx] = .{
                .client_decl_id = declared[global_idx % declared.len].client_decl_id,
                .ts = start_ts + @as(i64, @intCast(global_idx)),
                .value = @as(f64, @floatFromInt(global_idx)),
            };
        }
        _ = state.client.appendBatch(batch[0..take]) catch |err| {
            std.debug.panic("socket append failed: {s}", .{@errorName(err)});
        };
        emitted += take;
    }
}

fn runDirectEngineBenchmark(alloc: std.mem.Allocator, scenario: Scenario, specs: []const SeriesSpec) !BenchmarkResult {
    const bench_id = std.time.milliTimestamp();
    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/bench-transport-{d}-{s}-engine", .{ bench_id, scenario.name });
    defer alloc.free(data_path);
    defer std.fs.cwd().deleteTree(data_path) catch {};

    var eng = try Engine.init(alloc, try makeConfig(alloc, data_path));
    defer eng.deinit();

    const series_ids = try alloc.alloc(types.SeriesId, specs.len);
    defer alloc.free(series_ids);
    for (specs, 0..) |spec, idx| {
        series_ids[idx] = try eng.declareExactSeriesCanonical(spec.name, spec.canonical_tags, null);
    }

    const threads = try alloc.alloc(std.Thread, scenario.writers);
    defer alloc.free(threads);
    const contexts = try alloc.alloc(DirectWorkerContext, scenario.writers);
    defer alloc.free(contexts);

    const start_ns = std.time.nanoTimestamp();
    for (0..scenario.writers) |writer_idx| {
        const range = partitionSeries(specs.len, scenario.writers, writer_idx);
        contexts[writer_idx] = .{
            .eng = eng,
            .series_ids = series_ids[range.start .. range.start + range.count],
            .points = scenario.points_per_writer,
            .writer_idx = writer_idx,
            .batch_size = 256,
        };
        threads[writer_idx] = try std.Thread.spawn(.{}, directWorker, .{contexts[writer_idx]});
    }
    for (threads) |thread| thread.join();
    _ = try eng.flushAndDrain(60_000);
    const elapsed_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_ns));

    return .{
        .transport = "direct_engine",
        .points = scenario.points_per_writer * scenario.writers,
        .elapsed_ns = elapsed_ns,
        .metrics = .{
            .queue_pending_bytes_max = eng.metrics.queue_pending_bytes_max.load(.monotonic),
        },
    };
}

fn runCliDirectBenchmark(alloc: std.mem.Allocator, scenario: Scenario, specs: []const SeriesSpec) !BenchmarkResult {
    const bench_id = std.time.milliTimestamp();
    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/bench-transport-{d}-{s}-cli", .{ bench_id, scenario.name });
    defer alloc.free(data_path);
    defer std.fs.cwd().deleteTree(data_path) catch {};

    var eng = try Engine.init(alloc, try makeConfig(alloc, data_path));
    defer eng.deinit();

    const threads = try alloc.alloc(std.Thread, scenario.writers);
    defer alloc.free(threads);
    const contexts = try alloc.alloc(CliWorkerContext, scenario.writers);
    defer alloc.free(contexts);

    const start_ns = std.time.nanoTimestamp();
    for (0..scenario.writers) |writer_idx| {
        const range = partitionSeries(specs.len, scenario.writers, writer_idx);
        contexts[writer_idx] = .{
            .eng = eng,
            .specs = specs[range.start .. range.start + range.count],
            .points = scenario.points_per_writer,
            .writer_idx = writer_idx,
        };
        threads[writer_idx] = try std.Thread.spawn(.{}, cliWorker, .{contexts[writer_idx]});
    }
    for (threads) |thread| thread.join();
    _ = try eng.flushAndDrain(60_000);
    const elapsed_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_ns));

    return .{
        .transport = "cli_direct_ndjson",
        .points = scenario.points_per_writer * scenario.writers,
        .elapsed_ns = elapsed_ns,
        .metrics = .{
            .queue_pending_bytes_max = eng.metrics.queue_pending_bytes_max.load(.monotonic),
        },
    };
}

fn runHttpBenchmark(alloc: std.mem.Allocator, scenario: Scenario, specs: []const SeriesSpec) !BenchmarkResult {
    var server = try startServerProcess(alloc, scenario.name, false);
    defer server.deinit();
    try waitForServerReady(server.http_port);

    const body_paths = try alloc.alloc([]u8, scenario.writers);
    defer {
        for (body_paths) |path| alloc.free(path);
        alloc.free(body_paths);
    }
    for (0..scenario.writers) |writer_idx| {
        const range = partitionSeries(specs.len, scenario.writers, writer_idx);
        const body = try buildNdjsonBody(alloc, specs[range.start .. range.start + range.count], scenario.points_per_writer, writer_idx);
        defer alloc.free(body);
        body_paths[writer_idx] = try std.fmt.allocPrint(alloc, "{s}/http-worker-{d}.ndjson", .{ server.workdir, writer_idx });
        try std.fs.cwd().writeFile(.{ .sub_path = body_paths[writer_idx], .data = body });
    }

    const threads = try alloc.alloc(std.Thread, scenario.writers);
    defer alloc.free(threads);
    const contexts = try alloc.alloc(HttpWorkerContext, scenario.writers);
    defer alloc.free(contexts);

    const start_ns = std.time.nanoTimestamp();
    for (0..scenario.writers) |writer_idx| {
        contexts[writer_idx] = .{
            .alloc = alloc,
            .port = server.http_port,
            .body_path = body_paths[writer_idx],
        };
        threads[writer_idx] = try std.Thread.spawn(.{}, httpWorker, .{contexts[writer_idx]});
    }
    for (threads) |thread| thread.join();
    try waitForQueryableOverHttp(alloc, server.http_port, 60_000);
    const elapsed_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_ns));
    const metrics = try fetchMetrics(alloc, server.http_port);

    return .{
        .transport = "http_ndjson",
        .points = scenario.points_per_writer * scenario.writers,
        .elapsed_ns = elapsed_ns,
        .metrics = metrics,
    };
}

fn runSocketBenchmark(alloc: std.mem.Allocator, scenario: Scenario, specs: []const SeriesSpec) !BenchmarkResult {
    var server = try startServerProcess(alloc, scenario.name, true);
    defer server.deinit();
    try waitForServerReady(server.http_port);

    const states = try alloc.alloc(SocketWorkerState, scenario.writers);
    defer alloc.free(states);
    for (0..scenario.writers) |writer_idx| {
        const range = partitionSeries(specs.len, scenario.writers, writer_idx);
        states[writer_idx] = .{
            .alloc = alloc,
            .client = try ingest_socket.Client.connectWithRetry(alloc, server.socket_path.?, 40, 10),
            .specs = specs[range.start .. range.start + range.count],
            .points = scenario.points_per_writer,
            .writer_idx = writer_idx,
        };
        states[writer_idx].inputs = try buildSocketInputs(alloc, states[writer_idx].specs);
        if (scenario.warm_socket) {
            states[writer_idx].declared = try states[writer_idx].client.declareCachedBatch(states[writer_idx].inputs.?);
        }
    }
    defer for (states) |*state| state.deinit();

    const threads = try alloc.alloc(std.Thread, scenario.writers);
    defer alloc.free(threads);

    const start_ns = std.time.nanoTimestamp();
    for (0..scenario.writers) |writer_idx| {
        threads[writer_idx] = try std.Thread.spawn(.{}, socketWorker, .{&states[writer_idx]});
    }
    for (threads) |thread| thread.join();
    var flush_client = try ingest_socket.Client.connectWithRetry(alloc, server.socket_path.?, 40, 10);
    defer flush_client.deinit();
    _ = try flush_client.flushAndDrain(60_000);
    const elapsed_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_ns));
    const metrics = try fetchMetrics(alloc, server.http_port);

    return .{
        .transport = if (scenario.warm_socket) "uds_binary_warm" else "uds_binary_cold",
        .points = scenario.points_per_writer * scenario.writers,
        .elapsed_ns = elapsed_ns,
        .metrics = metrics,
    };
}

fn buildNdjsonBody(alloc: std.mem.Allocator, specs: []const SeriesSpec, points: usize, writer_idx: usize) ![]u8 {
    var body = std.array_list.Managed(u8).init(alloc);
    errdefer body.deinit();
    const start_ts = @as(i64, @intCast(writer_idx)) * 1_000_000;
    for (0..points) |idx| {
        const spec = specs[idx % specs.len];
        try body.writer().print(
            "{{\"series\":\"{s}\",\"ts\":{d},\"value\":{d},\"tags\":{{\"slot\":\"{d}\"}}}}\n",
            .{ spec.name, start_ts + @as(i64, @intCast(idx)), idx, spec.index },
        );
    }
    return try body.toOwnedSlice();
}

fn buildNdjsonChunk(alloc: std.mem.Allocator, specs: []const SeriesSpec, start_offset: usize, points: usize, writer_idx: usize) ![]u8 {
    var body = std.array_list.Managed(u8).init(alloc);
    errdefer body.deinit();
    const start_ts = @as(i64, @intCast(writer_idx)) * 1_000_000;
    for (0..points) |idx| {
        const global_idx = start_offset + idx;
        const spec = specs[global_idx % specs.len];
        try body.writer().print(
            "{{\"series\":\"{s}\",\"ts\":{d},\"value\":{d},\"tags\":{{\"slot\":\"{d}\"}}}}\n",
            .{ spec.name, start_ts + @as(i64, @intCast(global_idx)), global_idx, spec.index },
        );
    }
    return try body.toOwnedSlice();
}

fn buildSocketInputs(alloc: std.mem.Allocator, specs: []const SeriesSpec) ![]ingest_socket.ClientDeclareInput {
    const inputs = try alloc.alloc(ingest_socket.ClientDeclareInput, specs.len);
    for (specs, 0..) |spec, idx| {
        inputs[idx] = .{
            .decl_kind = .series,
            .name = spec.name,
            .tags_json = spec.canonical_tags,
        };
    }
    return inputs;
}

fn startServerProcess(alloc: std.mem.Allocator, scenario_name: []const u8, enable_socket: bool) !ServerProcess {
    const repo_root = try std.fs.cwd().realpathAlloc(alloc, ".");
    errdefer alloc.free(repo_root);

    const bench_id = std.time.milliTimestamp();
    const workdir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/bench-server-{d}-{s}-{s}", .{
        bench_id,
        scenario_name,
        if (enable_socket) "socket" else "http",
    });
    errdefer alloc.free(workdir);
    try std.fs.cwd().makePath(workdir);

    const absolute_workdir = try std.fs.cwd().realpathAlloc(alloc, workdir);
    alloc.free(workdir);
    errdefer alloc.free(absolute_workdir);

    const data_dir = try std.fmt.allocPrint(alloc, "{s}/data", .{absolute_workdir});
    defer alloc.free(data_dir);
    const socket_path = if (enable_socket) try std.fmt.allocPrint(alloc, "{s}/ingest.sock", .{absolute_workdir}) else null;
    errdefer if (socket_path) |path| alloc.free(path);
    const port = try pickHttpPort();
    const config_body = try std.fmt.allocPrint(
        alloc,
        "data_dir = \"{s}\"\nhttp_port = {d}\ningest_socket_path = \"{s}\"\ningest_socket_max_frame_bytes = 8388608\nfsync = \"none\"\nflush_interval_ms = 5\nmemtable_max_bytes = 8388608\nmem_limit_bytes = 536870912\nauth_token = \"\"\nenable_influx = false\nenable_prom = true\nretention_days = 0\n",
        .{
            data_dir,
            port,
            if (socket_path) |path| path else "",
        },
    );
    defer alloc.free(config_body);
    const config_path = try std.fmt.allocPrint(alloc, "{s}/sydradb.toml", .{absolute_workdir});
    defer alloc.free(config_path);
    try std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = config_body });

    const binary_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/sydradb", .{repo_root});
    defer alloc.free(binary_path);
    var argv = std.array_list.Managed([]const u8).init(alloc);
    defer argv.deinit();
    try argv.append(binary_path);
    try argv.append("serve");

    var child = std.process.Child.init(argv.items, alloc);
    child.cwd = absolute_workdir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    return .{
        .alloc = alloc,
        .repo_root = repo_root,
        .workdir = absolute_workdir,
        .child = child,
        .http_port = port,
        .socket_path = socket_path,
    };
}

fn pickHttpPort() !u16 {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();
    return listener.listen_address.getPort();
}

fn waitForServerReady(port: u16) !void {
    const deadline = std.time.milliTimestamp() + 10_000;
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    while (std.time.milliTimestamp() < deadline) {
        var stream = std.net.tcpConnectToAddress(address) catch {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            continue;
        };
        stream.close();
        return;
    }
    return error.ServerStartTimeout;
}

fn waitForQueryableOverHttp(alloc: std.mem.Allocator, port: u16, timeout_ms: u64) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        const response = try curlRequest(alloc, port, "/status", .{});
        defer alloc.free(response.body);
        if (response.status_code != 200) {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            continue;
        }
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response.body, .{});
        defer parsed.deinit();
        const runtime = parsed.value.object.get("runtime").?.object;
        // Points are queryable once the ingest queue drains into the memtable/segments.
        if (runtime.get("queue_depth").?.integer == 0) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn fetchMetrics(alloc: std.mem.Allocator, port: u16) !TransportMetrics {
    const response = try curlRequest(alloc, port, "/metrics", .{});
    defer alloc.free(response.body);
    if (response.status_code != 200) return error.InvalidHttpStatus;
    return .{
        .queue_pending_bytes_max = parseMetricUsize(response.body, "sydradb_queue_pending_bytes_max"),
        .local_ingest_declare_batches_total = parseMetricU64(response.body, "sydradb_local_ingest_declare_batches_total"),
        .local_ingest_declare_total = parseMetricU64(response.body, "sydradb_local_ingest_declare_total"),
        .local_ingest_declare_seconds_total = parseMetricF64(response.body, "sydradb_local_ingest_declare_seconds_total"),
        .local_ingest_append_batches_total = parseMetricU64(response.body, "sydradb_local_ingest_append_batches_total"),
        .local_ingest_append_points_total = parseMetricU64(response.body, "sydradb_local_ingest_append_points_total"),
        .local_ingest_append_seconds_total = parseMetricF64(response.body, "sydradb_local_ingest_append_seconds_total"),
        .local_ingest_append_batch_points_max = parseMetricUsize(response.body, "sydradb_local_ingest_append_batch_points_max"),
        .local_ingest_rejected_total = parseMetricU64(response.body, "sydradb_local_ingest_rejected_total"),
    };
}

const HttpResponse = struct {
    status_code: u16,
    body: []u8,
};

const CurlRequestOptions = struct {
    method: []const u8 = "GET",
    content_type: ?[]const u8 = null,
    body_path: ?[]const u8 = null,
};

fn curlRequest(
    alloc: std.mem.Allocator,
    port: u16,
    path: []const u8,
    options: CurlRequestOptions,
) !HttpResponse {
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer alloc.free(url);

    var argv = std.array_list.Managed([]const u8).init(alloc);
    defer argv.deinit();
    var body_arg: ?[]u8 = null;
    defer if (body_arg) |arg| alloc.free(arg);
    var header_arg_storage: ?[]u8 = null;
    defer if (header_arg_storage) |arg| alloc.free(arg);

    try argv.append("curl");
    try argv.append("-sS");
    try argv.append("-i");
    if (!std.mem.eql(u8, options.method, "GET")) {
        try argv.append("-X");
        try argv.append(options.method);
    }
    if (options.content_type) |value| {
        const header_arg = try std.fmt.allocPrint(alloc, "Content-Type: {s}", .{value});
        header_arg_storage = header_arg;
        try argv.append("-H");
        try argv.append(header_arg);
    }
    if (options.body_path) |path_value| {
        try argv.append("-H");
        try argv.append("Expect:");
        try argv.append("--data-binary");
        body_arg = try std.fmt.allocPrint(alloc, "@{s}", .{path_value});
        try argv.append(body_arg.?);
    }
    try argv.append(url);

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv.items,
        .max_output_bytes = 32 * 1024 * 1024,
    });
    errdefer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("curl failed ({d}): {s}\n", .{ code, result.stderr });
            alloc.free(result.stdout);
            return error.CurlFailed;
        },
        else => return error.CurlFailed,
    }

    const header_end = std.mem.indexOf(u8, result.stdout, "\r\n\r\n") orelse {
        alloc.free(result.stdout);
        return error.InvalidHttpResponse;
    };
    const header_bytes = result.stdout[0..header_end];
    const status_end = std.mem.indexOf(u8, header_bytes, "\r\n") orelse return error.InvalidHttpResponse;
    const status_line = header_bytes[0..status_end];
    const status_prefix_len = if (std.mem.startsWith(u8, status_line, "HTTP/1.1 "))
        "HTTP/1.1 ".len
    else if (std.mem.startsWith(u8, status_line, "HTTP/1.0 "))
        "HTTP/1.0 ".len
    else
        return error.InvalidHttpResponse;
    const status_code = try std.fmt.parseInt(u16, status_line[status_prefix_len .. status_prefix_len + 3], 10);
    const body = try alloc.dupe(u8, result.stdout[header_end + 4 ..]);
    alloc.free(result.stdout);
    return .{
        .status_code = status_code,
        .body = body,
    };
}

fn parseMetricLine(metrics_text: []const u8, metric_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, metrics_text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, metric_name) and line.len > metric_name.len and line[metric_name.len] == ' ') {
            return std.mem.trim(u8, line[metric_name.len + 1 ..], " \t\r");
        }
    }
    return null;
}

fn parseMetricU64(metrics_text: []const u8, metric_name: []const u8) u64 {
    const value = parseMetricLine(metrics_text, metric_name) orelse return 0;
    return std.fmt.parseInt(u64, value, 10) catch 0;
}

fn parseMetricUsize(metrics_text: []const u8, metric_name: []const u8) usize {
    return @intCast(parseMetricU64(metrics_text, metric_name));
}

fn parseMetricF64(metrics_text: []const u8, metric_name: []const u8) f64 {
    const value = parseMetricLine(metrics_text, metric_name) orelse return 0;
    return std.fmt.parseFloat(f64, value) catch 0;
}

fn printResult(scenario: Scenario, result: BenchmarkResult) void {
    const seconds = @as(f64, @floatFromInt(result.elapsed_ns)) / 1_000_000_000.0;
    const points_per_second = if (seconds == 0) 0 else @as(f64, @floatFromInt(result.points)) / seconds;
    std.debug.print(
        "scenario={s} transport={s} points={d} elapsed_ms={d:.2} points_per_sec={d:.0} queue_pending_bytes_max={d} local_declare_batches={d} local_declare_total={d} local_declare_s={d:.6} local_append_batches={d} local_append_points={d} local_append_s={d:.6} local_append_batch_points_max={d} local_rejected={d}\n",
        .{
            scenario.name,
            result.transport,
            result.points,
            seconds * 1000.0,
            points_per_second,
            result.metrics.queue_pending_bytes_max,
            result.metrics.local_ingest_declare_batches_total,
            result.metrics.local_ingest_declare_total,
            result.metrics.local_ingest_declare_seconds_total,
            result.metrics.local_ingest_append_batches_total,
            result.metrics.local_ingest_append_points_total,
            result.metrics.local_ingest_append_seconds_total,
            result.metrics.local_ingest_append_batch_points_max,
            result.metrics.local_ingest_rejected_total,
        },
    );
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const selected = try parseArgs(alloc);

    std.debug.print("bench_ingest_transport allocator={s}\n", .{build_options.allocator_mode});
    for (scenarios) |scenario| {
        if (!scenarioMatches(selected, scenario)) continue;
        const specs = try buildSeriesSpecs(alloc, scenario.series_count);
        defer freeSeriesSpecs(alloc, specs);

        std.debug.print("scenario {s}: {s}\n", .{ scenario.name, scenario.description });
        std.debug.print("starting transport=direct_engine\n", .{});
        printResult(scenario, try runDirectEngineBenchmark(alloc, scenario, specs));
        std.debug.print("starting transport=cli_direct_ndjson\n", .{});
        printResult(scenario, try runCliDirectBenchmark(alloc, scenario, specs));
        std.debug.print("starting transport=http_ndjson\n", .{});
        printResult(scenario, try runHttpBenchmark(alloc, scenario, specs));
        std.debug.print("starting transport={s}\n", .{if (scenario.warm_socket) "uds_binary_warm" else "uds_binary_cold"});
        printResult(scenario, try runSocketBenchmark(alloc, scenario, specs));
    }
}
