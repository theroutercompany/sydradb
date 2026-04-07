const std = @import("std");
const cfg = @import("../config.zig");
const Engine = @import("../engine.zig").Engine;
const types = @import("../types.zig");
const metric_catalog_mod = @import("../storage/metric_catalog.zig");
const series_catalog_mod = @import("../storage/series_catalog.zig");

const default_tags_json = "{}";

pub const ExactSeriesDeclareBatchOperation = struct {
    inputs: []const Engine.ExactSeriesCanonicalDeclarationInput,
};

pub const ExactSeriesAppendBatchOperation = struct {
    points: []const Engine.ResolvedIngestPoint,
};

pub const MarketFamilyMetadataPlaceholderOperation = struct {
    family: []const u8,
    metadata_json: []const u8 = "{}",
};

pub const IngestOperation = union(enum) {
    exact_series_declare_batch: ExactSeriesDeclareBatchOperation,
    exact_series_append_batch: ExactSeriesAppendBatchOperation,
    market_family_metadata_placeholder: MarketFamilyMetadataPlaceholderOperation,
};

pub fn executeExactSeriesDeclareBatch(
    eng: *Engine,
    inputs: []const Engine.ExactSeriesCanonicalDeclarationInput,
    results: []Engine.ExactSeriesBatchDeclarationResult,
) !void {
    return try eng.declareExactSeriesCanonicalBatch(inputs, results);
}

pub fn executeExactSeriesAppendBatch(
    eng: *Engine,
    points: []const Engine.ResolvedIngestPoint,
) !Engine.AppendBatchReceipt {
    return try eng.appendResolvedBatch(points);
}

pub fn executeOperation(eng: *Engine, operation: IngestOperation) !void {
    switch (operation) {
        .exact_series_declare_batch => |declare| {
            const results = try eng.alloc.alloc(Engine.ExactSeriesBatchDeclarationResult, declare.inputs.len);
            defer eng.alloc.free(results);
            try executeExactSeriesDeclareBatch(eng, declare.inputs, results);
        },
        .exact_series_append_batch => |append| {
            _ = try executeExactSeriesAppendBatch(eng, append.points);
        },
        .market_family_metadata_placeholder => return error.UnsupportedOperation,
    }
}

const ParsedIngestMetric = struct {
    series: []u8,
    value: f64,
    descriptor: ?metric_catalog_mod.Descriptor = null,

    fn deinit(self: *ParsedIngestMetric, alloc: std.mem.Allocator) void {
        alloc.free(self.series);
        if (self.descriptor) |*descriptor| descriptor.deinit(alloc);
        self.* = undefined;
    }
};

pub const ParsedIngestLine = struct {
    ts: i64,
    tags_json: []u8,
    writes: []ParsedIngestMetric,

    pub fn deinit(self: ParsedIngestLine, alloc: std.mem.Allocator) void {
        alloc.free(self.tags_json);
        for (self.writes) |*write| write.deinit(alloc);
        alloc.free(self.writes);
    }
};

const TagsJson = struct {
    value: []const u8,
    owned: ?[]u8 = null,
};

pub fn parseIngestLine(alloc: std.mem.Allocator, raw_line: []const u8) !ParsedIngestLine {
    const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyLine;

    const line = try alloc.dupe(u8, trimmed);
    defer alloc.free(line);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return error.InvalidRecord;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRecord;

    const obj = parsed.value.object;
    const ts_value = obj.get("ts") orelse return error.MissingTimestamp;
    if (ts_value != .integer) return error.InvalidTimestamp;

    if (obj.get("metric")) |metric_value| {
        if (metric_value != .string) return error.InvalidMetric;
        const labels = try extractTagsJson(alloc, obj.get("labels"));
        errdefer if (labels.owned) |owned| alloc.free(owned);

        var writes = std.array_list.Managed(ParsedIngestMetric).init(alloc);
        errdefer {
            for (writes.items) |*write| write.deinit(alloc);
            writes.deinit();
        }

        const kind = try parseMetricKind(obj.get("kind"));
        const unit = try dupOptionalJsonString(alloc, obj.get("unit"));
        defer if (unit) |value| alloc.free(value);
        const description = try dupOptionalJsonString(alloc, obj.get("description"));
        defer if (description) |value| alloc.free(value);

        if (obj.get("value")) |value_node| {
            try writes.append(try buildParsedIngestMetric(
                alloc,
                metric_value.string,
                try numericValue(value_node),
                .{
                    .metric = metric_value.string,
                    .kind = kind,
                    .unit = unit,
                    .description = description,
                },
            ));
        }

        if (obj.get("fields")) |fields_value| {
            if (fields_value != .object) return error.InvalidTelemetryFields;
            var it = fields_value.object.iterator();
            while (it.next()) |entry| {
                const field_value = switch (entry.value_ptr.*) {
                    .float => entry.value_ptr.float,
                    .integer => @as(f64, @floatFromInt(entry.value_ptr.integer)),
                    else => return error.TelemetryFieldsMustBeNumeric,
                };
                const derived_metric = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ metric_value.string, entry.key_ptr.* });
                defer alloc.free(derived_metric);
                try writes.append(try buildParsedIngestMetric(
                    alloc,
                    derived_metric,
                    field_value,
                    .{
                        .metric = derived_metric,
                        .kind = kind,
                        .unit = unit,
                        .description = description,
                        .source_metric = metric_value.string,
                        .source_field = entry.key_ptr.*,
                    },
                ));
            }
        }

        if (writes.items.len == 0) return error.MissingMetricValue;

        return .{
            .ts = @intCast(ts_value.integer),
            .tags_json = if (labels.owned) |owned| owned else try alloc.dupe(u8, default_tags_json),
            .writes = try writes.toOwnedSlice(),
        };
    }

    const series_value = obj.get("series") orelse return error.MissingSeries;
    if (series_value != .string) return error.InvalidSeries;

    const tags = try extractTagsJson(alloc, obj.get("tags"));
    var writes = std.array_list.Managed(ParsedIngestMetric).init(alloc);
    errdefer {
        for (writes.items) |*write| write.deinit(alloc);
        writes.deinit();
    }
    try writes.append(.{
        .series = try alloc.dupe(u8, series_value.string),
        .value = firstNumericValue(obj),
        .descriptor = null,
    });
    return .{
        .ts = @intCast(ts_value.integer),
        .tags_json = if (tags.owned) |owned| owned else try alloc.dupe(u8, default_tags_json),
        .writes = try writes.toOwnedSlice(),
    };
}

pub fn canonicalizeTagsJson(alloc: std.mem.Allocator, tags_json: []const u8) ![]u8 {
    return try series_catalog_mod.canonicalizeTagsJson(alloc, tags_json);
}

pub fn applyParsedIngestLine(eng: *Engine, parsed: ParsedIngestLine) !types.SeriesId {
    const canonical_tags = try canonicalizeTagsJson(eng.alloc, parsed.tags_json);
    defer eng.alloc.free(canonical_tags);

    var declarations = try eng.alloc.alloc(Engine.ExactSeriesCanonicalDeclarationInput, parsed.writes.len);
    defer eng.alloc.free(declarations);
    const declaration_results = try eng.alloc.alloc(Engine.ExactSeriesBatchDeclarationResult, parsed.writes.len);
    defer eng.alloc.free(declaration_results);
    var points = try eng.alloc.alloc(Engine.ResolvedIngestPoint, parsed.writes.len);
    defer eng.alloc.free(points);

    for (parsed.writes, 0..) |write, idx| {
        declarations[idx] = .{
            .name = write.series,
            .canonical_tags = canonical_tags,
            .descriptor = descriptorInput(&write),
        };
    }
    try executeExactSeriesDeclareBatch(eng, declarations, declaration_results);

    var first_sid: ?types.SeriesId = null;
    for (parsed.writes, 0..) |write, idx| {
        const sid = switch (declaration_results[idx].status) {
            .ok => declaration_results[idx].series_id.?,
            .metric_descriptor_conflict => return error.MetricDescriptorConflict,
            .series_conflict => return error.SeriesIdConflict,
        };
        points[idx] = .{
            .series_id = sid,
            .ts = parsed.ts,
            .value = write.value,
        };
        if (first_sid == null) first_sid = sid;
    }
    _ = try executeExactSeriesAppendBatch(eng, points);
    return first_sid orelse 0;
}

pub fn descriptorInput(write: *const ParsedIngestMetric) ?metric_catalog_mod.DescriptorInput {
    if (write.descriptor) |descriptor| {
        return .{
            .metric = descriptor.metric,
            .kind = descriptor.kind,
            .unit = descriptor.unit,
            .description = descriptor.description,
            .source_metric = descriptor.source_metric,
            .source_field = descriptor.source_field,
        };
    }
    return null;
}

fn buildParsedIngestMetric(
    alloc: std.mem.Allocator,
    metric: []const u8,
    value: f64,
    descriptor_input: metric_catalog_mod.DescriptorInput,
) !ParsedIngestMetric {
    return .{
        .series = try alloc.dupe(u8, metric),
        .value = value,
        .descriptor = .{
            .metric = try alloc.dupe(u8, descriptor_input.metric),
            .kind = descriptor_input.kind,
            .unit = try dupOptionalBytes(alloc, descriptor_input.unit),
            .description = try dupOptionalBytes(alloc, descriptor_input.description),
            .source_metric = try dupOptionalBytes(alloc, descriptor_input.source_metric),
            .source_field = try dupOptionalBytes(alloc, descriptor_input.source_field),
        },
    };
}

fn parseMetricKind(maybe_value: ?std.json.Value) !?metric_catalog_mod.MetricKind {
    if (maybe_value) |value| {
        if (value != .string) return error.InvalidMetricKind;
        return metric_catalog_mod.MetricKind.parse(value.string) orelse return error.InvalidMetricKind;
    }
    return null;
}

fn dupOptionalJsonString(alloc: std.mem.Allocator, maybe_value: ?std.json.Value) !?[]const u8 {
    if (maybe_value) |value| {
        if (value != .string) return error.InvalidMetricMetadata;
        if (value.string.len == 0) return null;
        return try alloc.dupe(u8, value.string);
    }
    return null;
}

fn dupOptionalBytes(alloc: std.mem.Allocator, maybe_value: ?[]const u8) !?[]const u8 {
    if (maybe_value) |value| return try alloc.dupe(u8, value);
    return null;
}

fn numericValue(value: std.json.Value) !f64 {
    return switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => error.InvalidMetricValue,
    };
}

fn extractTagsJson(alloc: std.mem.Allocator, maybe_value: ?std.json.Value) !TagsJson {
    if (maybe_value) |val| {
        if (val == .object) {
            var list = std.array_list.Managed(u8).init(alloc);
            errdefer list.deinit();
            var writer = list.writer();
            var tmp: [128]u8 = undefined;
            var adapter = writer.adaptToNewApi(&tmp);
            var iface = &adapter.new_interface;
            var stream = std.json.Stringify{ .writer = iface };
            try stream.write(val);
            try iface.flush();
            if (adapter.err) |write_err| return write_err;
            const owned = try list.toOwnedSlice();
            return .{ .value = owned, .owned = owned };
        }
    }
    return .{ .value = default_tags_json };
}

fn firstNumericValue(obj: std.json.ObjectMap) f64 {
    if (obj.get("value")) |value| {
        return switch (value) {
            .float => value.float,
            .integer => @floatFromInt(value.integer),
            else => 0,
        };
    }

    if (obj.get("fields")) |fields_value| {
        if (fields_value == .object) {
            var it = fields_value.object.iterator();
            while (it.next()) |entry| {
                switch (entry.value_ptr.*) {
                    .float => return entry.value_ptr.float,
                    .integer => return @floatFromInt(entry.value_ptr.integer),
                    else => {},
                }
            }
        }
    }

    return 0;
}

fn testConfig(alloc: std.mem.Allocator, data_path: []const u8) !cfg.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 25,
        .memtable_max_bytes = 32 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 256 * 1024 * 1024,
        .cas_mode = .off,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

test "canonicalizeTagsJson sorts object keys deterministically" {
    const alloc = std.testing.allocator;
    const canonical = try canonicalizeTagsJson(alloc, "{\"b\":\"two\",\"a\":\"one\"}");
    defer alloc.free(canonical);

    try std.testing.expectEqualStrings("{\"a\":\"one\",\"b\":\"two\"}", canonical);
}

test "parseIngestLine carries descriptor metadata through telemetry fanout" {
    const alloc = std.testing.allocator;
    const parsed = try parseIngestLine(alloc, "{\"metric\":\"system.cpu\",\"ts\":30,\"value\":0.5,\"fields\":{\"user\":0.3},\"labels\":{\"host\":\"web-1\"},\"kind\":\"counter\",\"unit\":\"ratio\",\"description\":\"cpu usage\"}");
    defer parsed.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), parsed.writes.len);
    try std.testing.expect(parsed.writes[0].descriptor != null);
    try std.testing.expect(parsed.writes[1].descriptor != null);
    try std.testing.expectEqual(metric_catalog_mod.MetricKind.counter, parsed.writes[0].descriptor.?.kind.?);
    try std.testing.expectEqualStrings("ratio", parsed.writes[0].descriptor.?.unit.?);
    try std.testing.expectEqualStrings("cpu usage", parsed.writes[0].descriptor.?.description.?);
    try std.testing.expectEqualStrings("system.cpu", parsed.writes[1].descriptor.?.source_metric.?);
    try std.testing.expectEqualStrings("user", parsed.writes[1].descriptor.?.source_field.?);
}

test "applyParsedIngestLine declares canonical exact series and writes queryable points" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/ingest-service", .{tmp.sub_path});
    defer alloc.free(data_path);

    var engine = try Engine.init(alloc, try testConfig(alloc, data_path));
    defer engine.deinit();

    const parsed = try parseIngestLine(alloc, "{\"metric\":\"service.req\",\"ts\":42,\"value\":3,\"labels\":{\"b\":\"2\",\"a\":\"1\"},\"kind\":\"counter\",\"unit\":\"requests\",\"description\":\"requests\"}");
    defer parsed.deinit(alloc);

    const sid = try applyParsedIngestLine(engine, parsed);
    _ = try engine.flushAndDrain(1_000);

    const canonical_tags = "{\"a\":\"1\",\"b\":\"2\"}";
    try std.testing.expectEqual(types.seriesIdFrom("service.req", canonical_tags), sid);

    var points = std.array_list.Managed(types.Point).init(alloc);
    defer points.deinit();
    try engine.queryRange(sid, 0, 100, &points);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(i64, 42), points.items[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), points.items[0].value, 1e-9);

    const descriptor = engine.metricDescriptor("service.req").?;
    try std.testing.expectEqual(metric_catalog_mod.MetricKind.counter, descriptor.kind.?);
    try std.testing.expectEqualStrings("requests", descriptor.unit.?);
    try std.testing.expectEqualStrings("requests", descriptor.description.?);

    const matches = engine.metadata.tags.get("a=1");
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(sid, matches[0]);
}
