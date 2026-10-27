const std = @import("std");
const market_identity = @import("market_identity.zig");
const market_segment = @import("market_segment.zig");

pub const manifest_path = "MARKET_MANIFEST";
pub const manifest_version: u32 = 1;

pub const MarketSeriesId = market_identity.MarketSeriesId;
pub const SchemaDigest = market_identity.SchemaDigest;
pub const ContentDigest = [32]u8;

const max_manifest_bytes: usize = 128 * 1024 * 1024;
const max_path_bytes: usize = 4096;
const hour_ns: i64 = 3600 * std.time.ns_per_s;

pub const MarketSegmentDescriptor = struct {
    path: []u8,
    market_series_id: MarketSeriesId,
    schema_digest: SchemaDigest,
    metric: []u8,
    canonical_labels: []u8,
    hour_bucket: i64,
    start_ts_ns: i64,
    end_ts_ns: i64,
    row_count: u64,
    block_count: u32,
    column_names: [][]u8,
    content_id: ContentDigest,
    file_hash: ContentDigest,
    file_size: u64,

    pub fn deinit(self: *MarketSegmentDescriptor, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.metric);
        alloc.free(self.canonical_labels);
        for (self.column_names) |name| alloc.free(name);
        alloc.free(self.column_names);
        self.* = undefined;
    }
};

pub const AddInput = struct {
    path: []const u8,
    market_series_id: MarketSeriesId,
    schema_digest: SchemaDigest,
    metric: []const u8,
    canonical_labels: []const u8,
    hour_bucket: i64,
    start_ts_ns: i64,
    end_ts_ns: i64,
    row_count: u64,
    block_count: u32,
    column_names: []const []const u8,
    content_id: ContentDigest,
    file_hash: ContentDigest,
    file_size: u64,
};

pub const ReplacementKey = struct {
    path: []const u8,
    content_id: ContentDigest,
};

pub const ReplaceBatchOutcome = enum {
    applied,
    already_applied,
};

pub const Manifest = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(MarketSegmentDescriptor),

    pub fn init(alloc: std.mem.Allocator) Manifest {
        return .{
            .alloc = alloc,
            .entries = .{},
        };
    }

    pub fn loadOrEmpty(alloc: std.mem.Allocator, data_dir: std.fs.Dir) !Manifest {
        var manifest = Manifest.init(alloc);
        errdefer manifest.deinit();

        const body = data_dir.readFileAlloc(alloc, manifest_path, max_manifest_bytes) catch |err| switch (err) {
            error.FileNotFound => return manifest,
            else => return err,
        };
        defer alloc.free(body);

        var line_it = std.mem.splitScalar(u8, body, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0) continue;
            const input = try parseDescriptorLine(alloc, line);
            defer input.deinit(alloc);
            try manifest.appendValidatedInput(input.view());
        }
        sortDescriptors(manifest.entries.items);
        return manifest;
    }

    pub fn deinit(self: *Manifest) void {
        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn list(self: *const Manifest) []const MarketSegmentDescriptor {
        return self.entries.items;
    }

    pub fn clone(self: *const Manifest, alloc: std.mem.Allocator) !Manifest {
        var copy = Manifest.init(alloc);
        errdefer copy.deinit();
        try copy.entries.ensureUnusedCapacity(alloc, self.entries.items.len);
        for (self.entries.items) |entry| {
            copy.entries.appendAssumeCapacity(try cloneDescriptor(alloc, entryView(entry)));
        }
        return copy;
    }

    pub fn addBatch(self: *Manifest, data_dir: std.fs.Dir, additions: []const AddInput) !void {
        if (additions.len == 0) return;

        var next = try self.clone(self.alloc);
        errdefer next.deinit();

        for (additions) |addition| {
            try next.appendValidatedInput(addition);
        }
        sortDescriptors(next.entries.items);
        try next.rewriteAtomically(data_dir);

        self.deinit();
        self.* = next;
    }

    pub fn rewriteAtomically(self: *const Manifest, data_dir: std.fs.Dir) !void {
        const temp_path = "MARKET_MANIFEST.tmp";
        var file = try data_dir.createFile(temp_path, .{ .truncate = true, .read = true });
        var file_open = true;
        var should_delete_temp = true;
        defer {
            if (file_open) file.close();
            if (should_delete_temp) data_dir.deleteFile(temp_path) catch {};
        }

        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;

        var sorted = try self.clone(self.alloc);
        defer sorted.deinit();
        sortDescriptors(sorted.entries.items);

        for (sorted.entries.items) |entry| {
            var jw = std.json.Stringify{ .writer = writer };
            try writeDescriptor(&jw, entry);
            try writer.writeByte('\n');
        }
        try writer_state.end();
        try file.sync();
        file.close();
        file_open = false;
        try data_dir.rename(temp_path, manifest_path);
        should_delete_temp = false;
        if (@hasDecl(std.fs.Dir, "sync")) {
            var durable_dir = data_dir;
            try durable_dir.sync();
        }
    }

    pub fn removeReplaced(self: *Manifest, data_dir: std.fs.Dir, replaced: []const ReplacementKey) !usize {
        if (replaced.len == 0) return 0;

        for (replaced) |key| try validateReplacementKey(key);

        var next = Manifest.init(self.alloc);
        errdefer next.deinit();
        try next.entries.ensureUnusedCapacity(self.alloc, self.entries.items.len);

        var removed: usize = 0;
        for (self.entries.items) |entry| {
            if (matchesAnyReplacement(entry, replaced)) {
                removed += 1;
                continue;
            }
            next.entries.appendAssumeCapacity(try cloneDescriptor(self.alloc, entryView(entry)));
        }

        if (removed == 0) {
            next.deinit();
            return 0;
        }

        sortDescriptors(next.entries.items);
        try next.rewriteAtomically(data_dir);

        self.deinit();
        self.* = next;
        return removed;
    }

    /// Atomically replaces a complete set of immutable segment descriptors.
    ///
    /// The referenced segment files are deliberately retained. A retry after a
    /// successful publication returns `already_applied` when every input is
    /// absent and every output descriptor is present byte-for-byte. Partial or
    /// stale input sets are rejected so a retry cannot silently publish over a
    /// manifest changed by another operation.
    pub fn replaceBatch(
        self: *Manifest,
        data_dir: std.fs.Dir,
        replaced: []const ReplacementKey,
        additions: []const AddInput,
    ) !ReplaceBatchOutcome {
        if (replaced.len == 0 or additions.len == 0) {
            return error.InvalidMarketManifestReplacement;
        }

        for (replaced, 0..) |key, key_idx| {
            try validateReplacementKey(key);
            for (replaced[0..key_idx]) |prior| {
                if (replacementKeyEqual(key, prior)) {
                    return error.InvalidMarketManifestReplacement;
                }
            }
        }
        for (additions) |addition| try validateDescriptorInput(self.alloc, addition);

        var matched_inputs: usize = 0;
        var obsolete_inputs_present: usize = 0;
        for (replaced) |key| {
            if (findReplacement(self.entries.items, key)) {
                matched_inputs += 1;
                if (!replacementKeyIsAddition(key, additions)) {
                    obsolete_inputs_present += 1;
                }
            } else if (missingReplacementHasUnrelatedConflict(
                self.entries.items,
                key,
                additions,
            )) {
                return error.MarketManifestReplacementConflict;
            }
        }

        if (allAdditionsExact(self.entries.items, additions) and
            obsolete_inputs_present == 0)
        {
            return .already_applied;
        }
        if (matched_inputs != replaced.len) {
            return error.MarketManifestReplacementConflict;
        }

        var next = Manifest.init(self.alloc);
        errdefer next.deinit();
        try next.entries.ensureUnusedCapacity(
            self.alloc,
            self.entries.items.len - matched_inputs + additions.len,
        );
        for (self.entries.items) |entry| {
            if (matchesAnyReplacement(entry, replaced)) continue;
            next.entries.appendAssumeCapacity(try cloneDescriptor(self.alloc, entryView(entry)));
        }
        for (additions) |addition| try next.appendValidatedInput(addition);

        sortDescriptors(next.entries.items);
        try next.rewriteAtomically(data_dir);

        self.deinit();
        self.* = next;
        return .applied;
    }

    pub fn selectBySeriesAndTime(
        self: *const Manifest,
        alloc: std.mem.Allocator,
        market_series_id: MarketSeriesId,
        start_ts_ns: i64,
        end_ts_ns: i64,
    ) ![]MarketSegmentDescriptor {
        if (start_ts_ns > end_ts_ns) return error.InvalidTimeRange;

        var selected = std.array_list.Managed(MarketSegmentDescriptor).init(alloc);
        errdefer {
            for (selected.items) |*entry| entry.deinit(alloc);
            selected.deinit();
        }

        for (self.entries.items) |entry| {
            if (entry.market_series_id != market_series_id) continue;
            if (entry.end_ts_ns < start_ts_ns or entry.start_ts_ns > end_ts_ns) continue;
            var cloned = try cloneDescriptor(alloc, entryView(entry));
            errdefer cloned.deinit(alloc);
            try selected.append(cloned);
        }
        return try selected.toOwnedSlice();
    }

    fn appendValidatedInput(self: *Manifest, input: AddInput) !void {
        try validateDescriptorInput(self.alloc, input);
        if (findMatchingDescriptor(self.entries.items, input)) |match| {
            if (match == .exact) return;
            return error.DuplicateMarketSegmentDescriptor;
        }
        var cloned = try cloneDescriptor(self.alloc, input);
        errdefer cloned.deinit(self.alloc);
        try self.entries.append(self.alloc, cloned);
    }
};

pub fn deinitDescriptorList(alloc: std.mem.Allocator, descriptors: []MarketSegmentDescriptor) void {
    for (descriptors) |*descriptor| descriptor.deinit(alloc);
    alloc.free(descriptors);
}

pub fn contentDigest(bytes: []const u8) ContentDigest {
    var digest: ContentDigest = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return digest;
}

pub fn validateDescriptorInput(alloc: std.mem.Allocator, input: AddInput) !void {
    try validateRelativeSegmentPath(input.path);
    if (input.metric.len == 0) return error.InvalidMarketManifestDescriptor;
    try market_identity.validateCanonicalLabelsObject(alloc, input.canonical_labels);
    if (input.market_series_id != market_identity.seriesId(input.metric, input.canonical_labels)) {
        return error.MarketSeriesIdMismatch;
    }
    if (isZeroDigest(input.schema_digest)) return error.InvalidMarketManifestDescriptor;
    if (isZeroDigest(input.content_id) or isZeroDigest(input.file_hash)) {
        return error.InvalidMarketManifestDescriptor;
    }
    market_identity.validateSchemaShape(
        input.metric,
        input.column_names,
        &.{},
    ) catch return error.InvalidMarketManifestDescriptor;

    if (input.start_ts_ns > input.end_ts_ns) return error.InvalidTimeRange;
    if (hourBucket(input.start_ts_ns) != input.hour_bucket or
        hourBucket(input.end_ts_ns) != input.hour_bucket)
    {
        return error.MarketSegmentHourMismatch;
    }
    if (input.row_count == 0 or input.block_count == 0 or input.file_size == 0) {
        return error.InvalidMarketManifestDescriptor;
    }
    const max_rows = @as(u64, input.block_count) * @as(u64, market_segment.market_segment_block_rows);
    if (input.row_count > max_rows) return error.InvalidMarketManifestDescriptor;
}

fn validateReplacementKey(key: ReplacementKey) !void {
    try validateRelativeSegmentPath(key.path);
    if (isZeroDigest(key.content_id)) return error.InvalidMarketManifestDescriptor;
}

fn validateRelativeSegmentPath(path: []const u8) !void {
    if (path.len == 0 or path.len > max_path_bytes) return error.InvalidMarketSegmentPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidMarketSegmentPath;
    if (!std.mem.startsWith(u8, path, "market_segments/")) return error.InvalidMarketSegmentPath;
    if (!std.mem.endsWith(u8, path, ".mseg")) return error.InvalidMarketSegmentPath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidMarketSegmentPath;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return error.InvalidMarketSegmentPath;
        }
        for (part) |ch| {
            if (ch < 0x20 or ch == 0x7f) return error.InvalidMarketSegmentPath;
        }
    }
}

fn hourBucket(ts_ns: i64) i64 {
    return @divFloor(ts_ns, hour_ns);
}

fn isZeroDigest(digest: ContentDigest) bool {
    for (digest) |byte| if (byte != 0) return false;
    return true;
}

const MatchKind = enum { exact, conflict };

fn findMatchingDescriptor(entries: []const MarketSegmentDescriptor, input: AddInput) ?MatchKind {
    for (entries) |entry| {
        if (descriptorEqualsInput(entry, input)) return .exact;
        if (std.mem.eql(u8, entry.path, input.path) or
            std.mem.eql(u8, &entry.content_id, &input.content_id))
        {
            return .conflict;
        }
    }
    return null;
}

fn matchesAnyReplacement(entry: MarketSegmentDescriptor, replaced: []const ReplacementKey) bool {
    for (replaced) |key| {
        if (std.mem.eql(u8, entry.path, key.path) and
            std.mem.eql(u8, &entry.content_id, &key.content_id))
        {
            return true;
        }
    }
    return false;
}

fn replacementKeyEqual(lhs: ReplacementKey, rhs: ReplacementKey) bool {
    return std.mem.eql(u8, lhs.path, rhs.path) and
        std.mem.eql(u8, &lhs.content_id, &rhs.content_id);
}

fn findReplacement(entries: []const MarketSegmentDescriptor, key: ReplacementKey) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, key.path) and
            std.mem.eql(u8, &entry.content_id, &key.content_id))
        {
            return true;
        }
    }
    return false;
}

fn replacementKeyIsAddition(key: ReplacementKey, additions: []const AddInput) bool {
    for (additions) |addition| {
        if (std.mem.eql(u8, key.path, addition.path) and
            std.mem.eql(u8, &key.content_id, &addition.content_id))
        {
            return true;
        }
    }
    return false;
}

fn missingReplacementHasUnrelatedConflict(
    entries: []const MarketSegmentDescriptor,
    key: ReplacementKey,
    additions: []const AddInput,
) bool {
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.path, key.path) and
            !std.mem.eql(u8, &entry.content_id, &key.content_id))
        {
            continue;
        }
        var is_published_output = false;
        for (additions) |addition| {
            if (descriptorEqualsInput(entry, addition)) {
                is_published_output = true;
                break;
            }
        }
        if (!is_published_output) return true;
    }
    return false;
}

fn allAdditionsExact(
    entries: []const MarketSegmentDescriptor,
    additions: []const AddInput,
) bool {
    for (additions) |addition| {
        var found = false;
        for (entries) |entry| {
            if (descriptorEqualsInput(entry, addition)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn cloneDescriptor(alloc: std.mem.Allocator, input: AddInput) !MarketSegmentDescriptor {
    const path = try alloc.dupe(u8, input.path);
    errdefer alloc.free(path);
    const metric = try alloc.dupe(u8, input.metric);
    errdefer alloc.free(metric);
    const canonical_labels = try alloc.dupe(u8, input.canonical_labels);
    errdefer alloc.free(canonical_labels);

    var column_names = try alloc.alloc([]u8, input.column_names.len);
    errdefer alloc.free(column_names);
    var initialized: usize = 0;
    errdefer {
        for (column_names[0..initialized]) |name| alloc.free(name);
    }
    for (input.column_names, 0..) |name, idx| {
        column_names[idx] = try alloc.dupe(u8, name);
        initialized += 1;
    }

    return .{
        .path = path,
        .market_series_id = input.market_series_id,
        .schema_digest = input.schema_digest,
        .metric = metric,
        .canonical_labels = canonical_labels,
        .hour_bucket = input.hour_bucket,
        .start_ts_ns = input.start_ts_ns,
        .end_ts_ns = input.end_ts_ns,
        .row_count = input.row_count,
        .block_count = input.block_count,
        .column_names = column_names,
        .content_id = input.content_id,
        .file_hash = input.file_hash,
        .file_size = input.file_size,
    };
}

fn entryView(entry: MarketSegmentDescriptor) AddInput {
    return .{
        .path = entry.path,
        .market_series_id = entry.market_series_id,
        .schema_digest = entry.schema_digest,
        .metric = entry.metric,
        .canonical_labels = entry.canonical_labels,
        .hour_bucket = entry.hour_bucket,
        .start_ts_ns = entry.start_ts_ns,
        .end_ts_ns = entry.end_ts_ns,
        .row_count = entry.row_count,
        .block_count = entry.block_count,
        .column_names = entry.column_names,
        .content_id = entry.content_id,
        .file_hash = entry.file_hash,
        .file_size = entry.file_size,
    };
}

fn descriptorEqualsInput(entry: MarketSegmentDescriptor, input: AddInput) bool {
    if (!std.mem.eql(u8, entry.path, input.path) or
        entry.market_series_id != input.market_series_id or
        !std.mem.eql(u8, &entry.schema_digest, &input.schema_digest) or
        !std.mem.eql(u8, entry.metric, input.metric) or
        !std.mem.eql(u8, entry.canonical_labels, input.canonical_labels) or
        entry.hour_bucket != input.hour_bucket or
        entry.start_ts_ns != input.start_ts_ns or
        entry.end_ts_ns != input.end_ts_ns or
        entry.row_count != input.row_count or
        entry.block_count != input.block_count or
        !std.mem.eql(u8, &entry.content_id, &input.content_id) or
        !std.mem.eql(u8, &entry.file_hash, &input.file_hash) or
        entry.file_size != input.file_size or
        entry.column_names.len != input.column_names.len)
    {
        return false;
    }
    for (entry.column_names, input.column_names) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn sortDescriptors(entries: []MarketSegmentDescriptor) void {
    std.sort.block(MarketSegmentDescriptor, entries, {}, struct {
        fn lessThan(_: void, lhs: MarketSegmentDescriptor, rhs: MarketSegmentDescriptor) bool {
            if (lhs.market_series_id != rhs.market_series_id) return lhs.market_series_id < rhs.market_series_id;
            if (lhs.hour_bucket != rhs.hour_bucket) return lhs.hour_bucket < rhs.hour_bucket;
            if (lhs.start_ts_ns != rhs.start_ts_ns) return lhs.start_ts_ns < rhs.start_ts_ns;
            if (lhs.end_ts_ns != rhs.end_ts_ns) return lhs.end_ts_ns < rhs.end_ts_ns;
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
}

fn writeDescriptor(jw: *std.json.Stringify, entry: MarketSegmentDescriptor) !void {
    const schema_hex = std.fmt.bytesToHex(entry.schema_digest, .lower);
    const content_hex = std.fmt.bytesToHex(entry.content_id, .lower);
    const file_hash_hex = std.fmt.bytesToHex(entry.file_hash, .lower);

    try jw.beginObject();
    try jw.objectField("version");
    try jw.write(manifest_version);
    try jw.objectField("path");
    try jw.write(entry.path);
    try jw.objectField("market_series_id");
    try writeU64String(jw, entry.market_series_id);
    try jw.objectField("schema_digest");
    try jw.write(&schema_hex);
    try jw.objectField("metric");
    try jw.write(entry.metric);
    try jw.objectField("canonical_labels");
    try jw.write(entry.canonical_labels);
    try jw.objectField("hour_bucket");
    try jw.write(entry.hour_bucket);
    try jw.objectField("start_ts_ns");
    try jw.write(entry.start_ts_ns);
    try jw.objectField("end_ts_ns");
    try jw.write(entry.end_ts_ns);
    try jw.objectField("row_count");
    try writeU64String(jw, entry.row_count);
    try jw.objectField("block_count");
    try jw.write(entry.block_count);
    try jw.objectField("column_names");
    try jw.beginArray();
    for (entry.column_names) |name| try jw.write(name);
    try jw.endArray();
    try jw.objectField("content_id");
    try jw.write(&content_hex);
    try jw.objectField("file_hash");
    try jw.write(&file_hash_hex);
    try jw.objectField("file_size");
    try writeU64String(jw, entry.file_size);
    try jw.endObject();
}

fn writeU64String(jw: *std.json.Stringify, value: u64) !void {
    var buffer: [20]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try jw.write(text);
}

const ParsedInput = struct {
    path: []u8,
    metric: []u8,
    canonical_labels: []u8,
    column_names: [][]u8,
    value: AddInput,

    fn view(self: ParsedInput) AddInput {
        return .{
            .path = self.path,
            .market_series_id = self.value.market_series_id,
            .schema_digest = self.value.schema_digest,
            .metric = self.metric,
            .canonical_labels = self.canonical_labels,
            .hour_bucket = self.value.hour_bucket,
            .start_ts_ns = self.value.start_ts_ns,
            .end_ts_ns = self.value.end_ts_ns,
            .row_count = self.value.row_count,
            .block_count = self.value.block_count,
            .column_names = self.column_names,
            .content_id = self.value.content_id,
            .file_hash = self.value.file_hash,
            .file_size = self.value.file_size,
        };
    }

    fn deinit(self: *const ParsedInput, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.metric);
        alloc.free(self.canonical_labels);
        for (self.column_names) |name| alloc.free(name);
        alloc.free(self.column_names);
    }
};

fn parseDescriptorLine(alloc: std.mem.Allocator, line: []const u8) !ParsedInput {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMarketManifestDescriptor;

    const obj = parsed.value.object;
    const version = try jsonU64(obj.get("version") orelse return error.InvalidMarketManifestDescriptor);
    if (version != manifest_version) return error.UnsupportedMarketManifestVersion;

    const path = try jsonOwnedString(alloc, obj.get("path") orelse return error.InvalidMarketManifestDescriptor);
    errdefer alloc.free(path);
    const metric = try jsonOwnedString(alloc, obj.get("metric") orelse return error.InvalidMarketManifestDescriptor);
    errdefer alloc.free(metric);
    const labels = try jsonOwnedString(alloc, obj.get("canonical_labels") orelse return error.InvalidMarketManifestDescriptor);
    errdefer alloc.free(labels);
    const column_names = try jsonOwnedStringArray(alloc, obj.get("column_names") orelse return error.InvalidMarketManifestDescriptor);
    errdefer {
        for (column_names) |name| alloc.free(name);
        alloc.free(column_names);
    }

    const value = AddInput{
        .path = path,
        .market_series_id = @intCast(try jsonU64(obj.get("market_series_id") orelse return error.InvalidMarketManifestDescriptor)),
        .schema_digest = try jsonDigest(obj.get("schema_digest") orelse return error.InvalidMarketManifestDescriptor),
        .metric = metric,
        .canonical_labels = labels,
        .hour_bucket = try jsonI64(obj.get("hour_bucket") orelse return error.InvalidMarketManifestDescriptor),
        .start_ts_ns = try jsonI64(obj.get("start_ts_ns") orelse return error.InvalidMarketManifestDescriptor),
        .end_ts_ns = try jsonI64(obj.get("end_ts_ns") orelse return error.InvalidMarketManifestDescriptor),
        .row_count = try jsonU64(obj.get("row_count") orelse return error.InvalidMarketManifestDescriptor),
        .block_count = @intCast(try jsonU64(obj.get("block_count") orelse return error.InvalidMarketManifestDescriptor)),
        .column_names = column_names,
        .content_id = try jsonDigest(obj.get("content_id") orelse return error.InvalidMarketManifestDescriptor),
        .file_hash = try jsonDigest(obj.get("file_hash") orelse return error.InvalidMarketManifestDescriptor),
        .file_size = try jsonU64(obj.get("file_size") orelse return error.InvalidMarketManifestDescriptor),
    };

    return .{
        .path = path,
        .metric = metric,
        .canonical_labels = labels,
        .column_names = column_names,
        .value = value,
    };
}

fn jsonOwnedString(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |text| try alloc.dupe(u8, text),
        else => error.InvalidMarketManifestDescriptor,
    };
}

fn jsonOwnedStringArray(alloc: std.mem.Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.InvalidMarketManifestDescriptor;
    var result = try alloc.alloc([]u8, value.array.items.len);
    errdefer alloc.free(result);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |text| alloc.free(text);
    }
    for (value.array.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidMarketManifestDescriptor;
        result[idx] = try alloc.dupe(u8, item.string);
        initialized += 1;
    }
    return result;
}

fn jsonDigest(value: std.json.Value) !ContentDigest {
    const text = switch (value) {
        .string => |string| string,
        else => return error.InvalidMarketManifestDescriptor,
    };
    if (text.len != 64) return error.InvalidMarketManifestDescriptor;
    var digest: ContentDigest = undefined;
    _ = std.fmt.hexToBytes(&digest, text) catch return error.InvalidMarketManifestDescriptor;
    return digest;
}

fn jsonI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        .number_string => |digits| try std.fmt.parseInt(i64, digits, 10),
        .string => |digits| try std.fmt.parseInt(i64, digits, 10),
        else => error.InvalidMarketManifestDescriptor,
    };
}

fn jsonU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidMarketManifestDescriptor,
        .number_string => |digits| try std.fmt.parseInt(u64, digits, 10),
        .string => |digits| try std.fmt.parseInt(u64, digits, 10),
        else => error.InvalidMarketManifestDescriptor,
    };
}

fn sampleDigest(byte: u8) ContentDigest {
    return [_]u8{byte} ** 32;
}

fn sampleInput(path: []const u8, start: i64, end: i64, digest_byte: u8) AddInput {
    const metric = "market.quote";
    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const columns = &[_][]const u8{ "bid", "ask" };
    return .{
        .path = path,
        .market_series_id = market_identity.seriesId(metric, labels),
        .schema_digest = sampleDigest(0x44),
        .metric = metric,
        .canonical_labels = labels,
        .hour_bucket = hourBucket(start),
        .start_ts_ns = start,
        .end_ts_ns = end,
        .row_count = 2,
        .block_count = 1,
        .column_names = columns,
        .content_id = sampleDigest(digest_byte),
        .file_hash = sampleDigest(digest_byte +% 1),
        .file_size = 4096,
    };
}

test "market manifest load-or-empty restart round trip is deterministic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    var manifest = Manifest.init(alloc);
    defer manifest.deinit();
    const second = sampleInput("market_segments/0/b.mseg", 20, 30, 0x22);
    const first = sampleInput("market_segments/0/a.mseg", 1, 10, 0x11);
    try manifest.addBatch(tmp.dir, &.{ second, first });

    var reloaded = try Manifest.loadOrEmpty(alloc, tmp.dir);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), reloaded.list().len);
    try std.testing.expectEqualStrings("market_segments/0/a.mseg", reloaded.list()[0].path);
    try std.testing.expectEqualStrings("market_segments/0/b.mseg", reloaded.list()[1].path);

    const before = try tmp.dir.readFileAlloc(alloc, manifest_path, max_manifest_bytes);
    defer alloc.free(before);
    try reloaded.rewriteAtomically(tmp.dir);
    const after = try tmp.dir.readFileAlloc(alloc, manifest_path, max_manifest_bytes);
    defer alloc.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "market manifest rejects malformed data and preserves old manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    var manifest = Manifest.init(alloc);
    defer manifest.deinit();
    const valid = sampleInput("market_segments/0/a.mseg", 1, 10, 0x11);
    try manifest.addBatch(tmp.dir, &.{valid});
    const old_body = try tmp.dir.readFileAlloc(alloc, manifest_path, max_manifest_bytes);
    defer alloc.free(old_body);

    var invalid = sampleInput("market_segments/0/b.mseg", 20, 30, 0x22);
    invalid.canonical_labels = "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}";
    try std.testing.expectError(error.NonCanonicalMarketLabels, manifest.addBatch(tmp.dir, &.{invalid}));
    try std.testing.expectEqual(@as(usize, 1), manifest.list().len);
    const new_body = try tmp.dir.readFileAlloc(alloc, manifest_path, max_manifest_bytes);
    defer alloc.free(new_body);
    try std.testing.expectEqualSlices(u8, old_body, new_body);

    {
        var file = try tmp.dir.createFile(manifest_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("{\"version\":1,\"path\":\"/absolute.mseg\"}\n");
    }
    try std.testing.expectError(
        error.InvalidMarketManifestDescriptor,
        Manifest.loadOrEmpty(alloc, tmp.dir),
    );
}

test "market manifest add batch is idempotent and detects descriptor conflicts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    var manifest = Manifest.init(alloc);
    defer manifest.deinit();
    const first = sampleInput("market_segments/0/a.mseg", 1, 10, 0x11);
    try manifest.addBatch(tmp.dir, &.{ first, first });
    try std.testing.expectEqual(@as(usize, 1), manifest.list().len);
    try manifest.addBatch(tmp.dir, &.{first});
    try std.testing.expectEqual(@as(usize, 1), manifest.list().len);

    var conflict = first;
    conflict.file_size += 1;
    try std.testing.expectError(
        error.DuplicateMarketSegmentDescriptor,
        manifest.addBatch(tmp.dir, &.{conflict}),
    );

    var content_conflict = sampleInput("market_segments/0/b.mseg", 20, 30, 0x11);
    content_conflict.content_id = first.content_id;
    try std.testing.expectError(
        error.DuplicateMarketSegmentDescriptor,
        manifest.addBatch(tmp.dir, &.{content_conflict}),
    );
}

test "market manifest selection prunes by series and time and returns owned descriptors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    var manifest = Manifest.init(alloc);
    defer manifest.deinit();

    const first = sampleInput("market_segments/0/a.mseg", 1, 10, 0x11);
    const second = sampleInput("market_segments/0/b.mseg", 20, 30, 0x22);
    var other_series = sampleInput("market_segments/0/c.mseg", 5, 15, 0x33);
    other_series.metric = "market.trade";
    other_series.market_series_id = market_identity.seriesId(other_series.metric, other_series.canonical_labels);
    try manifest.addBatch(tmp.dir, &.{ first, second, other_series });

    const selected = try manifest.selectBySeriesAndTime(alloc, first.market_series_id, 8, 21);
    defer deinitDescriptorList(alloc, selected);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    for (selected) |*descriptor| descriptor.path[0] = 'X';

    var found_original = false;
    for (manifest.list()) |descriptor| {
        if (std.mem.eql(u8, descriptor.path, first.path)) {
            found_original = true;
            break;
        }
    }
    try std.testing.expect(found_original);
}

test "market manifest remove-replaced is atomic and idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    var manifest = Manifest.init(alloc);
    defer manifest.deinit();
    const first = sampleInput("market_segments/0/a.mseg", 1, 10, 0x11);
    const second = sampleInput("market_segments/0/b.mseg", 20, 30, 0x22);
    try manifest.addBatch(tmp.dir, &.{ first, second });

    const removed = try manifest.removeReplaced(tmp.dir, &.{.{
        .path = first.path,
        .content_id = first.content_id,
    }});
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), manifest.list().len);
    try std.testing.expectEqualStrings(second.path, manifest.list()[0].path);

    const removed_again = try manifest.removeReplaced(tmp.dir, &.{.{
        .path = first.path,
        .content_id = first.content_id,
    }});
    try std.testing.expectEqual(@as(usize, 0), removed_again);
}

test "market manifest replace batch is atomic resumable and rejects stale inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    var manifest = Manifest.init(alloc);
    defer manifest.deinit();
    const first = sampleInput("market_segments/0/a.mseg", 1, 10, 0x11);
    const second = sampleInput("market_segments/0/b.mseg", 8, 20, 0x22);
    try manifest.addBatch(tmp.dir, &.{ first, second });
    const before = try tmp.dir.readFileAlloc(alloc, manifest_path, max_manifest_bytes);
    defer alloc.free(before);

    var invalid_output = sampleInput("market_segments/0/compact.mseg", 1, 20, 0x33);
    invalid_output.row_count = 3;
    invalid_output.canonical_labels = "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}";
    try std.testing.expectError(
        error.NonCanonicalMarketLabels,
        manifest.replaceBatch(
            tmp.dir,
            &.{
                .{ .path = first.path, .content_id = first.content_id },
                .{ .path = second.path, .content_id = second.content_id },
            },
            &.{invalid_output},
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), manifest.list().len);
    const after_failure = try tmp.dir.readFileAlloc(alloc, manifest_path, max_manifest_bytes);
    defer alloc.free(after_failure);
    try std.testing.expectEqualSlices(u8, before, after_failure);

    var output = invalid_output;
    output.canonical_labels = first.canonical_labels;
    const keys = [_]ReplacementKey{
        .{ .path = first.path, .content_id = first.content_id },
        .{ .path = second.path, .content_id = second.content_id },
    };
    try std.testing.expectEqual(
        ReplaceBatchOutcome.applied,
        try manifest.replaceBatch(tmp.dir, &keys, &.{output}),
    );
    try std.testing.expectEqual(@as(usize, 1), manifest.list().len);
    try std.testing.expectEqualStrings(output.path, manifest.list()[0].path);

    try std.testing.expectEqual(
        ReplaceBatchOutcome.already_applied,
        try manifest.replaceBatch(tmp.dir, &keys, &.{output}),
    );

    var stale_key = keys[0];
    stale_key.content_id = sampleDigest(0x99);
    const published = try tmp.dir.readFileAlloc(alloc, manifest_path, max_manifest_bytes);
    defer alloc.free(published);
    try std.testing.expectError(
        error.MarketManifestReplacementConflict,
        manifest.replaceBatch(tmp.dir, &.{stale_key}, &.{first}),
    );
    const after_stale = try tmp.dir.readFileAlloc(alloc, manifest_path, max_manifest_bytes);
    defer alloc.free(after_stale);
    try std.testing.expectEqualSlices(u8, published, after_stale);
}

test "market manifest replacement retry recognizes an output identical to one input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    var manifest = Manifest.init(alloc);
    defer manifest.deinit();
    const retained_output = sampleInput("market_segments/0/a.mseg", 1, 10, 0x11);
    const obsolete = sampleInput("market_segments/0/b.mseg", 8, 10, 0x22);
    try manifest.addBatch(tmp.dir, &.{ retained_output, obsolete });
    const keys = [_]ReplacementKey{
        .{ .path = retained_output.path, .content_id = retained_output.content_id },
        .{ .path = obsolete.path, .content_id = obsolete.content_id },
    };

    try std.testing.expectEqual(
        ReplaceBatchOutcome.applied,
        try manifest.replaceBatch(tmp.dir, &keys, &.{retained_output}),
    );
    try std.testing.expectEqual(@as(usize, 1), manifest.list().len);
    try std.testing.expectEqualStrings(retained_output.path, manifest.list()[0].path);
    try std.testing.expectEqual(
        ReplaceBatchOutcome.already_applied,
        try manifest.replaceBatch(tmp.dir, &keys, &.{retained_output}),
    );
}
