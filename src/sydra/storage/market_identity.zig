const std = @import("std");
const types = @import("../types.zig");
const series_catalog = @import("series_catalog.zig");

pub const MarketSeriesId = types.SeriesId;
pub const SchemaDigest = [32]u8;
pub const max_market_columns: usize = 4096;

const schema_digest_domain = "SYDRA_MARKET_SCHEMA_V1";

pub fn seriesId(metric: []const u8, canonical_labels_json: []const u8) MarketSeriesId {
    return types.seriesIdFrom(metric, canonical_labels_json);
}

pub fn seriesIdFromLabels(
    alloc: std.mem.Allocator,
    metric: []const u8,
    labels_json: []const u8,
) !MarketSeriesId {
    const canonical_labels = try canonicalizeLabels(alloc, labels_json);
    defer alloc.free(canonical_labels);
    return seriesId(metric, canonical_labels);
}

pub fn canonicalizeLabels(alloc: std.mem.Allocator, labels_json: []const u8) ![]u8 {
    return series_catalog.canonicalizeTagsJson(alloc, labels_json);
}

pub fn validateSchemaShape(
    metric: []const u8,
    ordered_columns: []const []const u8,
    required_labels: []const []const u8,
) !void {
    if (isBlank(metric)) return error.InvalidMarketMetric;
    if (ordered_columns.len == 0 or ordered_columns.len > max_market_columns) {
        return error.InvalidMarketColumnCount;
    }
    try validateUniqueNames(ordered_columns, error.InvalidMarketColumn, error.DuplicateMarketColumn);
    try validateUniqueNames(
        required_labels,
        error.InvalidMarketRequiredLabel,
        error.DuplicateMarketRequiredLabel,
    );
}

pub fn validateValueShape(expected_columns: usize, value_count: usize) !void {
    if (expected_columns == 0 or expected_columns > max_market_columns) {
        return error.InvalidMarketColumnCount;
    }
    if (value_count != expected_columns) return error.MarketValueCountMismatch;
}

pub fn validateCanonicalLabelsObject(
    alloc: std.mem.Allocator,
    canonical_labels_json: []const u8,
) !void {
    const canonical = canonicalizeLabels(
        alloc,
        canonical_labels_json,
    ) catch return error.InvalidMarketLabels;
    defer alloc.free(canonical);
    if (!std.mem.eql(u8, canonical, canonical_labels_json)) {
        return error.NonCanonicalMarketLabels;
    }
}

pub fn validateRequiredLabels(
    alloc: std.mem.Allocator,
    canonical_labels_json: []const u8,
    required_labels: []const []const u8,
) !void {
    try validateCanonicalLabelsObject(alloc, canonical_labels_json);
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        canonical_labels_json,
        .{},
    ) catch return error.InvalidMarketLabels;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMarketLabels;
    for (required_labels) |required_label| {
        if (parsed.value.object.get(required_label) == null) {
            return error.MissingRequiredMarketLabel;
        }
    }
}

pub fn schemaDigest(
    metric: []const u8,
    ordered_columns: []const []const u8,
    required_labels: []const []const u8,
    storage_mapping: []const u8,
) SchemaDigest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    updateFramed(&hasher, schema_digest_domain);
    updateFramed(&hasher, metric);
    updateStringList(&hasher, ordered_columns);
    updateStringList(&hasher, required_labels);
    updateFramed(&hasher, storage_mapping);

    var digest: SchemaDigest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn digestToHex(digest: SchemaDigest) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn digestFromHex(encoded: []const u8) !SchemaDigest {
    if (encoded.len != 64) return error.InvalidSchemaDigest;
    var digest: SchemaDigest = undefined;
    _ = std.fmt.hexToBytes(&digest, encoded) catch return error.InvalidSchemaDigest;
    return digest;
}

fn updateStringList(hasher: *std.crypto.hash.Blake3, values: []const []const u8) void {
    updateU64(hasher, values.len);
    for (values) |value| updateFramed(hasher, value);
}

fn updateFramed(hasher: *std.crypto.hash.Blake3, value: []const u8) void {
    updateU64(hasher, value.len);
    hasher.update(value);
}

fn updateU64(hasher: *std.crypto.hash.Blake3, value: usize) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hasher.update(&encoded);
}

fn validateUniqueNames(
    values: []const []const u8,
    invalid_name: anyerror,
    duplicate_name: anyerror,
) !void {
    for (values, 0..) |value, idx| {
        if (isBlank(value)) return invalid_name;
        for (values[0..idx]) |previous| {
            if (std.mem.eql(u8, value, previous)) return duplicate_name;
        }
    }
}

fn isBlank(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len == 0;
}

test "market identity canonicalizes labels before hashing" {
    const alloc = std.testing.allocator;
    const canonical = try canonicalizeLabels(alloc, "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}");
    defer alloc.free(canonical);

    try std.testing.expectEqualStrings("{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}", canonical);
    try std.testing.expectEqual(
        seriesId("market.trade", canonical),
        try seriesIdFromLabels(alloc, "market.trade", "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}"),
    );
    try std.testing.expectEqual(
        @as(MarketSeriesId, 453802258572543033),
        seriesId("market.trade", canonical),
    );
}

test "schema digest is sensitive to ordered fields and storage mapping" {
    const fanout = schemaDigest(
        "market.trade",
        &.{ "price", "size" },
        &.{ "symbol", "venue" },
        "fanout_v1",
    );
    const reordered = schemaDigest(
        "market.trade",
        &.{ "size", "price" },
        &.{ "symbol", "venue" },
        "fanout_v1",
    );
    const native = schemaDigest(
        "market.trade",
        &.{ "price", "size" },
        &.{ "symbol", "venue" },
        "native_v1",
    );
    const fanout_hex = digestToHex(fanout);

    try std.testing.expect(!std.mem.eql(u8, &fanout, &reordered));
    try std.testing.expect(!std.mem.eql(u8, &fanout, &native));
    try std.testing.expectEqualStrings(
        "ddb64a81bcb6933b2c0b36aaf4dc75ccdfbe992771c4a900d1bc07fc3ecfd334",
        &fanout_hex,
    );
}

test "market schema shape rejects empty oversized and duplicate names" {
    try std.testing.expectError(
        error.InvalidMarketMetric,
        validateSchemaShape(" ", &.{"price"}, &.{"symbol"}),
    );
    try std.testing.expectError(
        error.InvalidMarketColumnCount,
        validateSchemaShape("market.trade", &.{}, &.{"symbol"}),
    );
    try std.testing.expectError(
        error.InvalidMarketColumn,
        validateSchemaShape("market.trade", &.{""}, &.{"symbol"}),
    );
    try std.testing.expectError(
        error.DuplicateMarketColumn,
        validateSchemaShape("market.trade", &.{ "price", "price" }, &.{"symbol"}),
    );
    try std.testing.expectError(
        error.InvalidMarketRequiredLabel,
        validateSchemaShape("market.trade", &.{"price"}, &.{"\t"}),
    );
    try std.testing.expectError(
        error.DuplicateMarketRequiredLabel,
        validateSchemaShape("market.trade", &.{"price"}, &.{ "symbol", "symbol" }),
    );

    var too_many: [max_market_columns + 1][]const u8 = undefined;
    @memset(&too_many, "column");
    try std.testing.expectError(
        error.InvalidMarketColumnCount,
        validateSchemaShape("market.trade", &too_many, &.{"symbol"}),
    );
}

test "market value shape enforces schema width" {
    try validateValueShape(2, 2);
    try std.testing.expectError(error.InvalidMarketColumnCount, validateValueShape(0, 0));
    try std.testing.expectError(
        error.InvalidMarketColumnCount,
        validateValueShape(max_market_columns + 1, max_market_columns + 1),
    );
    try std.testing.expectError(error.MarketValueCountMismatch, validateValueShape(2, 1));
}

test "required labels require a JSON object with every key" {
    const alloc = std.testing.allocator;
    try validateRequiredLabels(
        alloc,
        "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
        &.{ "symbol", "venue" },
    );
    try std.testing.expectError(
        error.InvalidMarketLabels,
        validateRequiredLabels(alloc, "[]", &.{"symbol"}),
    );
    try std.testing.expectError(
        error.NonCanonicalMarketLabels,
        validateRequiredLabels(
            alloc,
            "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}",
            &.{ "symbol", "venue" },
        ),
    );
    try std.testing.expectError(
        error.MissingRequiredMarketLabel,
        validateRequiredLabels(alloc, "{\"symbol\":\"AAPL\"}", &.{ "symbol", "venue" }),
    );
}
