const std = @import("std");
const cfg = @import("../config.zig");
const types = @import("../types.zig");
const manifest_mod = @import("manifest.zig");
const compact_mod = @import("compact.zig");
const object_store = @import("object_store.zig");
const extents = @import("extents.zig");
const segment_mod = @import("segment.zig");
const series_catalog_mod = @import("series_catalog.zig");
const tags_mod = @import("tags.zig");
const retention_mod = @import("retention.zig");
const wal_mod = @import("wal.zig");

pub const current_format_version: u16 = 1;
pub const main_ref = "heads/main";
pub const current_repository_format_version: u16 = 1;
pub const default_extent_chunk_bytes: u32 = 64 * 1024;
const store_format_path = "objects/info/store-format";
const store_format_magic = "SYDSTORE1";

pub const RefBackend = enum(u8) {
    loose = 1,
    reftable = 2,
};

pub const RepositoryFormat = struct {
    version: u16 = current_repository_format_version,
    ref_backend: RefBackend = .loose,
    extent_chunk_bytes: u32 = default_extent_chunk_bytes,
};

pub const ExtentTreeRef = struct {
    root_id: object_store.ObjectId,
    size_bytes: u64,
    chunk_bytes: u32,

    pub fn eql(self: ExtentTreeRef, other: ExtentTreeRef) bool {
        return self.root_id.eql(other.root_id) and
            self.size_bytes == other.size_bytes and
            self.chunk_bytes == other.chunk_bytes;
    }
};

pub const ContentRef = union(enum) {
    blob: object_store.ObjectId,
    extent_tree: ExtentTreeRef,

    pub fn eql(self: ContentRef, other: ContentRef) bool {
        return switch (self) {
            .blob => |lhs| switch (other) {
                .blob => |rhs| lhs.eql(rhs),
                .extent_tree => false,
            },
            .extent_tree => |lhs| switch (other) {
                .blob => false,
                .extent_tree => |rhs| lhs.eql(rhs),
            },
        };
    }

    pub fn rootObjectId(self: ContentRef) object_store.ObjectId {
        return switch (self) {
            .blob => |id| id,
            .extent_tree => |tree| tree.root_id,
        };
    }
};

pub const SegmentDescriptor = struct {
    path: []u8,
    mirror_path: []u8 = &[_]u8{},
    content_id: ?object_store.ObjectId = null,
    content: ?ContentRef = null,
    file_hash: [32]u8,
    file_size: u64,
    series_id: types.SeriesId,
    hour_bucket: i64,
    start_ts: i64,
    end_ts: i64,
    count: u32,
    ts_codec: u8,
    val_codec: u8,

    pub fn deinit(self: *SegmentDescriptor, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }

    pub fn contentRef(self: SegmentDescriptor) ?ContentRef {
        if (self.content) |content| return content;
        if (self.content_id) |content_id| return .{ .blob = content_id };
        return null;
    }

    pub fn mirrorPath(self: SegmentDescriptor) []const u8 {
        return if (self.mirror_path.len != 0) self.mirror_path else self.path;
    }

    pub fn eql(self: SegmentDescriptor, other: SegmentDescriptor) bool {
        return std.mem.eql(u8, self.mirrorPath(), other.mirrorPath()) and
            optionalContentRefEql(self.contentRef(), other.contentRef()) and
            std.mem.eql(u8, self.file_hash[0..], other.file_hash[0..]) and
            self.file_size == other.file_size and
            self.series_id == other.series_id and
            self.hour_bucket == other.hour_bucket and
            self.start_ts == other.start_ts and
            self.end_ts == other.end_ts and
            self.count == other.count and
            self.ts_codec == other.ts_codec and
            self.val_codec == other.val_codec;
    }
};

pub const TagSnapshotEntry = struct {
    key: []u8,
    series_ids: []types.SeriesId,

    pub fn deinit(self: *TagSnapshotEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.series_ids);
    }

    pub fn eql(self: TagSnapshotEntry, other: TagSnapshotEntry) bool {
        return std.mem.eql(u8, self.key, other.key) and std.mem.eql(types.SeriesId, self.series_ids, other.series_ids);
    }
};

pub const TagSnapshot = struct {
    entries: []TagSnapshotEntry,

    pub fn empty(alloc: std.mem.Allocator) !TagSnapshot {
        return .{ .entries = try alloc.alloc(TagSnapshotEntry, 0) };
    }

    pub fn deinit(self: *TagSnapshot, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
    }
};

pub const SeriesCatalogSnapshotEntry = struct {
    series: []u8,
    canonical_tags: []u8,
    series_id: types.SeriesId,

    pub fn deinit(self: *SeriesCatalogSnapshotEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.series);
        alloc.free(self.canonical_tags);
    }

    pub fn eql(self: SeriesCatalogSnapshotEntry, other: SeriesCatalogSnapshotEntry) bool {
        return std.mem.eql(u8, self.series, other.series) and
            std.mem.eql(u8, self.canonical_tags, other.canonical_tags) and
            self.series_id == other.series_id;
    }
};

pub const SeriesCatalogSnapshot = struct {
    entries: []SeriesCatalogSnapshotEntry,

    pub fn empty(alloc: std.mem.Allocator) !SeriesCatalogSnapshot {
        return .{ .entries = try alloc.alloc(SeriesCatalogSnapshotEntry, 0) };
    }

    pub fn deinit(self: *SeriesCatalogSnapshot, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
    }
};

pub const WalChunkDescriptor = struct {
    name: []u8,
    mirror_name: []u8 = &[_]u8{},
    content_id: ?object_store.ObjectId = null,
    content: ?ContentRef = null,
    file_size: u64,
    file_hash: [32]u8,
    mutable: bool,
    captured_bytes: u64 = 0,

    pub fn deinit(self: *WalChunkDescriptor, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }

    pub fn contentRef(self: WalChunkDescriptor) ?ContentRef {
        if (self.content) |content| return content;
        if (self.content_id) |content_id| return .{ .blob = content_id };
        return null;
    }

    pub fn mirrorName(self: WalChunkDescriptor) []const u8 {
        return if (self.mirror_name.len != 0) self.mirror_name else self.name;
    }

    pub fn eql(self: WalChunkDescriptor, other: WalChunkDescriptor) bool {
        return std.mem.eql(u8, self.mirrorName(), other.mirrorName()) and
            optionalContentRefEql(self.contentRef(), other.contentRef()) and
            self.file_size == other.file_size and
            std.mem.eql(u8, self.file_hash[0..], other.file_hash[0..]) and
            self.mutable == other.mutable and
            self.captured_bytes == other.captured_bytes;
    }
};

pub const WalIndex = struct {
    entries: []WalChunkDescriptor,

    pub fn empty(alloc: std.mem.Allocator) !WalIndex {
        return .{ .entries = try alloc.alloc(WalChunkDescriptor, 0) };
    }

    pub fn deinit(self: *WalIndex, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
    }
};

pub const TreeEntry = struct {
    name: []u8,
    object_type: object_store.ObjectType,
    object_id: object_store.ObjectId,

    pub fn deinit(self: *TreeEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub const Tree = struct {
    entries: []TreeEntry,

    pub fn deinit(self: *Tree, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
    }
};

pub const Commit = struct {
    format_version: u16,
    root: object_store.ObjectId,
    parents: []object_store.ObjectId,
    created_at_ms: i64,
    reason: []u8,

    pub fn deinit(self: *Commit, alloc: std.mem.Allocator) void {
        alloc.free(self.parents);
        alloc.free(self.reason);
    }
};

pub const LegacySnapshot = struct {
    segment_descriptors: []SegmentDescriptor,
    tag_snapshot: TagSnapshot,
    series_catalog_snapshot: SeriesCatalogSnapshot,
    wal_index: WalIndex,

    pub fn deinit(self: *LegacySnapshot, alloc: std.mem.Allocator) void {
        for (self.segment_descriptors) |*descriptor| descriptor.deinit(alloc);
        alloc.free(self.segment_descriptors);
        self.tag_snapshot.deinit(alloc);
        self.series_catalog_snapshot.deinit(alloc);
        self.wal_index.deinit(alloc);
    }
};

pub const Snapshot = struct {
    commit_id: object_store.ObjectId,
    root_id: object_store.ObjectId,
    commit: Commit,
    segment_descriptors: []SegmentDescriptor,
    tag_snapshot: TagSnapshot,
    series_catalog_snapshot: SeriesCatalogSnapshot,
    wal_index: WalIndex,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        self.commit.deinit(alloc);
        for (self.segment_descriptors) |*descriptor| descriptor.deinit(alloc);
        alloc.free(self.segment_descriptors);
        self.tag_snapshot.deinit(alloc);
        self.series_catalog_snapshot.deinit(alloc);
        self.wal_index.deinit(alloc);
    }
};

pub const SnapshotIndex = struct {
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    snapshot: Snapshot,

    pub fn init(alloc: std.mem.Allocator, store: *object_store.ObjectStore, snapshot: Snapshot) SnapshotIndex {
        return .{
            .alloc = alloc,
            .store = store,
            .snapshot = snapshot,
        };
    }

    pub fn deinit(self: *SnapshotIndex) void {
        self.snapshot.deinit(self.alloc);
    }

    pub fn queryRange(self: *const SnapshotIndex, alloc: std.mem.Allocator, data_dir: std.fs.Dir, series_id: types.SeriesId, start_ts: i64, end_ts: i64, out: *std.array_list.Managed(types.Point)) !void {
        try segment_mod.queryRangeDescriptorEntries(alloc, data_dir, self.store, self.snapshot.segment_descriptors, series_id, start_ts, end_ts, out);
    }

    pub fn tagMatches(self: *const SnapshotIndex, key: []const u8) []const types.SeriesId {
        const idx = binarySearchTagEntry(self.snapshot.tag_snapshot.entries, key) orelse return &[_]types.SeriesId{};
        return self.snapshot.tag_snapshot.entries[idx].series_ids;
    }

    pub fn resolveUniqueSeriesName(self: *const SnapshotIndex, series: []const u8) series_catalog_mod.Match {
        return self.resolveUniqueSeriesNameDetailed(series).toMatch();
    }

    pub fn resolveUniqueSeriesNameDetailed(self: *const SnapshotIndex, series: []const u8) series_catalog_mod.Resolution {
        var resolved: ?SeriesCatalogSnapshotEntry = null;
        for (self.snapshot.series_catalog_snapshot.entries) |entry| {
            if (!std.mem.eql(u8, entry.series, series)) continue;
            if (resolved) |existing| {
                if (existing.series_id != entry.series_id) return .{ .status = .ambiguous };
            } else {
                resolved = entry;
            }
        }
        if (resolved) |entry| {
            return .{
                .status = .resolved,
                .series_id = entry.series_id,
                .series = entry.series,
                .canonical_tags = entry.canonical_tags,
            };
        }
        return .{ .status = .not_found };
    }

    pub fn resolveExactSeries(self: *const SnapshotIndex, series: []const u8, tags_json: []const u8) !series_catalog_mod.Match {
        return (try self.resolveExactSeriesDetailed(series, tags_json)).toMatch();
    }

    pub fn resolveExactSeriesDetailed(self: *const SnapshotIndex, series: []const u8, tags_json: []const u8) !series_catalog_mod.Resolution {
        const canonical_tags = try series_catalog_mod.canonicalizeTagsJson(self.alloc, tags_json);
        defer self.alloc.free(canonical_tags);

        var resolved: ?SeriesCatalogSnapshotEntry = null;
        for (self.snapshot.series_catalog_snapshot.entries) |entry| {
            if (!std.mem.eql(u8, entry.series, series)) continue;
            if (!std.mem.eql(u8, entry.canonical_tags, canonical_tags)) continue;
            if (resolved) |existing| {
                if (existing.series_id != entry.series_id) return .{ .status = .ambiguous };
            } else {
                resolved = entry;
            }
        }
        if (resolved) |entry| {
            return .{
                .status = .exact_match,
                .series_id = entry.series_id,
                .series = entry.series,
                .canonical_tags = entry.canonical_tags,
            };
        }
        return .{ .status = .not_found };
    }

    pub fn resolveBySeriesId(self: *const SnapshotIndex, series_id: types.SeriesId) series_catalog_mod.Resolution {
        for (self.snapshot.series_catalog_snapshot.entries) |entry| {
            if (entry.series_id != series_id) continue;
            return .{
                .status = .resolved,
                .series_id = entry.series_id,
                .series = entry.series,
                .canonical_tags = entry.canonical_tags,
            };
        }
        return .{ .status = .not_found };
    }
};

pub const RefEntry = struct {
    name: []u8,
    id: object_store.ObjectId,

    pub fn deinit(self: *RefEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub const RefTxnUpdate = struct {
    ref_name: []const u8,
    expected_old: ?object_store.ObjectId = null,
    new_id: object_store.ObjectId,
};

pub const ReflogEntry = struct {
    ref_name: []u8,
    old_id: ?object_store.ObjectId,
    new_id: object_store.ObjectId,
    timestamp_ms: i64,
    reason: []u8,

    pub fn deinit(self: *ReflogEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.ref_name);
        alloc.free(self.reason);
    }
};

pub const RefStore = struct {
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    fsync: cfg.FsyncPolicy,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, fsync: cfg.FsyncPolicy) !RefStore {
        var cwd = std.fs.cwd();
        try cwd.makePath(path);
        const root = try cwd.openDir(path, .{ .iterate = true });
        try root.makePath("refs");
        try root.makePath("refs/heads");
        try root.makePath("logs/refs");
        try root.makePath("logs/refs/heads");
        try root.makePath("refs/txn");
        return .{ .alloc = alloc, .root = root, .fsync = fsync };
    }

    pub fn deinit(self: *RefStore) void {
        self.root.close();
    }

    pub fn readHead(self: *RefStore, ref_name: []const u8) !?object_store.ObjectId {
        return self.readRef(ref_name);
    }

    pub fn readRef(self: *RefStore, ref_name: []const u8) !?object_store.ObjectId {
        const full_path = try std.fmt.allocPrint(self.alloc, "refs/{s}", .{ref_name});
        defer self.alloc.free(full_path);

        var file = self.root.openFile(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const body = try file.readToEndAlloc(self.alloc, 256);
        defer self.alloc.free(body);
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try object_store.ObjectId.fromHex(trimmed);
    }

    pub fn updateHeadAtomic(self: *RefStore, ref_name: []const u8, id: object_store.ObjectId) !void {
        try self.updateRefTxn(&[_]RefTxnUpdate{.{
            .ref_name = ref_name,
            .new_id = id,
        }}, "update-head");
    }

    pub fn updateRefAtomic(self: *RefStore, ref_name: []const u8, id: object_store.ObjectId) !void {
        try self.updateRefTxn(&[_]RefTxnUpdate{.{
            .ref_name = ref_name,
            .new_id = id,
        }}, "update-ref");
    }

    pub fn compareAndSwapRef(self: *RefStore, ref_name: []const u8, expected_old: ?object_store.ObjectId, id: object_store.ObjectId, reason: []const u8) !void {
        try self.updateRefTxn(&[_]RefTxnUpdate{.{
            .ref_name = ref_name,
            .expected_old = expected_old,
            .new_id = id,
        }}, reason);
    }

    pub fn updateRefTxn(self: *RefStore, updates: []const RefTxnUpdate, reason: []const u8) !void {
        if (updates.len == 0) return;

        const intent_path = try self.writeIntent(updates, reason);
        defer {
            self.root.deleteFile(intent_path) catch {};
            self.alloc.free(intent_path);
        }

        var old_ids = try self.alloc.alloc(?object_store.ObjectId, updates.len);
        defer self.alloc.free(old_ids);

        for (updates, 0..) |update, idx| {
            const current = try self.readRef(update.ref_name);
            old_ids[idx] = current;
            if (!optionalObjectIdEql(update.expected_old, current)) {
                if (update.expected_old != null) return error.RefConflict;
            }
        }

        for (updates, 0..) |update, idx| {
            try self.writeRefFileAtomic(update.ref_name, update.new_id);
            try self.appendReflog(update.ref_name, old_ids[idx], update.new_id, reason);
        }
    }

    fn writeRefFileAtomic(self: *RefStore, ref_name: []const u8, id: object_store.ObjectId) !void {
        const full_path = try std.fmt.allocPrint(self.alloc, "refs/{s}", .{ref_name});
        defer self.alloc.free(full_path);
        if (std.fs.path.dirname(full_path)) |dirname| {
            try self.root.makePath(dirname);
        }

        const tmp_path = try std.fmt.allocPrint(self.alloc, "refs/{s}.tmp-{d}", .{ ref_name, std.time.nanoTimestamp() });
        defer self.alloc.free(tmp_path);

        var file = try self.root.createFile(tmp_path, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer self.root.deleteFile(tmp_path) catch {};

        const hex = id.toHex();
        try file.writeAll(hex[0..]);
        try file.writeAll("\n");
        if (self.fsync != .none) {
            try file.sync();
        }

        self.root.rename(tmp_path, full_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                self.root.deleteFile(full_path) catch {};
                try self.root.rename(tmp_path, full_path);
            },
            else => return err,
        };
        if (self.fsync != .none) {
            try syncDir(&self.root);
        }
    }

    fn writeIntent(self: *RefStore, updates: []const RefTxnUpdate, reason: []const u8) ![]u8 {
        const intent_path = try std.fmt.allocPrint(self.alloc, "refs/txn/{d}.intent", .{std.time.nanoTimestamp()});
        errdefer self.alloc.free(intent_path);

        var file = try self.root.createFile(intent_path, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer self.root.deleteFile(intent_path) catch {};

        var write_buf: [1024]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;
        try writer.print("reason={s}\n", .{reason});
        for (updates) |update| {
            const expected = if (update.expected_old) |id| id.toHex() else [_]u8{'-'} ** 64;
            const next = update.new_id.toHex();
            try writer.print("{s} {s} {s}\n", .{ update.ref_name, expected, next });
        }
        try writer_state.end();
        if (self.fsync != .none) {
            try file.sync();
            try syncDir(&self.root);
        }
        return intent_path;
    }

    fn appendReflog(self: *RefStore, ref_name: []const u8, old_id: ?object_store.ObjectId, new_id: object_store.ObjectId, reason: []const u8) !void {
        const log_path = try std.fmt.allocPrint(self.alloc, "logs/refs/{s}", .{ref_name});
        defer self.alloc.free(log_path);
        if (std.fs.path.dirname(log_path)) |dirname| {
            try self.root.makePath(dirname);
        }

        var file = self.root.openFile(log_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try self.root.createFile(log_path, .{ .read = true }),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);

        const old_hex = if (old_id) |id| id.toHex() else [_]u8{'0'} ** 64;
        const new_hex = new_id.toHex();
        var write_buf: [256]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;
        try writer.print("{d} {s} {s} {s}\n", .{
            std.time.milliTimestamp(),
            old_hex,
            new_hex,
            reason,
        });
        try writer_state.end();
        if (self.fsync != .none) {
            try file.sync();
        }
    }

    pub fn listRefs(self: *RefStore, alloc: std.mem.Allocator) ![]RefEntry {
        var refs_dir = self.root.openDir("refs", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return try alloc.alloc(RefEntry, 0),
            else => return err,
        };
        defer refs_dir.close();

        var refs = std.array_list.Managed(RefEntry).init(alloc);
        errdefer {
            for (refs.items) |*entry| entry.deinit(alloc);
            refs.deinit();
        }

        try listRefsRecursive(self, alloc, &refs, refs_dir, "");
        std.sort.block(RefEntry, refs.items, {}, struct {
            fn lessThan(_: void, lhs: RefEntry, rhs: RefEntry) bool {
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
        }.lessThan);
        return try refs.toOwnedSlice();
    }
};

pub const CommitWriter = struct {
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    extent_chunk_bytes: u32 = default_extent_chunk_bytes,

    pub fn writeSnapshot(
        self: *CommitWriter,
        data_dir: std.fs.Dir,
        manifest: *const manifest_mod.Manifest,
        tags: *const tags_mod.TagIndex,
        series_catalog: *const series_catalog_mod.SeriesCatalog,
        parent: ?object_store.ObjectId,
        reason: []const u8,
    ) !object_store.ObjectId {
        var snapshot = try buildLegacySnapshot(self.alloc, data_dir, manifest, tags, series_catalog, self.store, self.extent_chunk_bytes);
        defer snapshot.deinit(self.alloc);
        return try self.writePreparedSnapshot(&snapshot, parent, reason);
    }

    fn writePreparedSnapshot(
        self: *CommitWriter,
        snapshot: *const LegacySnapshot,
        parent: ?object_store.ObjectId,
        reason: []const u8,
    ) !object_store.ObjectId {
        const tag_payload = try encodeTagSnapshot(self.alloc, snapshot.tag_snapshot);
        defer self.alloc.free(tag_payload);
        const tag_blob_id = try self.store.put(.blob, tag_payload);

        const series_payload = try encodeSeriesCatalogSnapshot(self.alloc, snapshot.series_catalog_snapshot);
        defer self.alloc.free(series_payload);
        const series_blob_id = try self.store.put(.blob, series_payload);

        const wal_payload = try encodeWalIndex(self.alloc, snapshot.wal_index);
        defer self.alloc.free(wal_payload);
        const wal_blob_id = try self.store.put(.blob, wal_payload);

        const segments_tree_id = try self.writeSegmentTree(snapshot.segment_descriptors);

        var metadata_entries = std.array_list.Managed(TreeEntry).init(self.alloc);
        defer {
            for (metadata_entries.items) |*entry| entry.deinit(self.alloc);
            metadata_entries.deinit();
        }
        try metadata_entries.append(.{
            .name = try self.alloc.dupe(u8, "segments"),
            .object_type = .tree,
            .object_id = segments_tree_id,
        });
        try metadata_entries.append(.{
            .name = try self.alloc.dupe(u8, "series_catalog"),
            .object_type = .blob,
            .object_id = series_blob_id,
        });
        try metadata_entries.append(.{
            .name = try self.alloc.dupe(u8, "tags"),
            .object_type = .blob,
            .object_id = tag_blob_id,
        });
        const metadata_tree_id = try self.putTree(metadata_entries.items);

        var wal_entries = std.array_list.Managed(TreeEntry).init(self.alloc);
        defer {
            for (wal_entries.items) |*entry| entry.deinit(self.alloc);
            wal_entries.deinit();
        }
        var wal_chunk_ids = std.AutoHashMap(object_store.ObjectId, void).init(self.alloc);
        defer wal_chunk_ids.deinit();
        try wal_entries.append(.{
            .name = try self.alloc.dupe(u8, "index"),
            .object_type = .blob,
            .object_id = wal_blob_id,
        });
        for (snapshot.wal_index.entries) |entry| {
            const content = entry.contentRef() orelse continue;
            const content_root_id = content.rootObjectId();
            const gop = try wal_chunk_ids.getOrPut(content_root_id);
            if (gop.found_existing) continue;

            const chunk_hex = content_root_id.toHex();
            try wal_entries.append(.{
                .name = try std.fmt.allocPrint(self.alloc, "chunk-{s}", .{chunk_hex[0..]}),
                .object_type = switch (content) {
                    .blob => .blob,
                    .extent_tree => .tree,
                },
                .object_id = content_root_id,
            });
        }
        const wal_tree_id = try self.putTree(wal_entries.items);

        var root_entries = std.array_list.Managed(TreeEntry).init(self.alloc);
        defer {
            for (root_entries.items) |*entry| entry.deinit(self.alloc);
            root_entries.deinit();
        }
        try root_entries.append(.{
            .name = try self.alloc.dupe(u8, "metadata"),
            .object_type = .tree,
            .object_id = metadata_tree_id,
        });
        try root_entries.append(.{
            .name = try self.alloc.dupe(u8, "wal"),
            .object_type = .tree,
            .object_id = wal_tree_id,
        });
        const root_id = try self.putTree(root_entries.items);

        const parent_ids = try buildParentSlice(self.alloc, parent);
        defer self.alloc.free(parent_ids);
        const reason_copy = try self.alloc.dupe(u8, reason);
        defer self.alloc.free(reason_copy);
        const commit = Commit{
            .format_version = current_format_version,
            .root = root_id,
            .parents = parent_ids,
            .created_at_ms = std.time.milliTimestamp(),
            .reason = reason_copy,
        };
        const commit_payload = try encodeCommit(self.alloc, commit);
        defer self.alloc.free(commit_payload);
        return try self.store.put(.commit, commit_payload);
    }

    fn putTree(self: *CommitWriter, entries: []const TreeEntry) !object_store.ObjectId {
        var copy_entries = try self.alloc.alloc(TreeEntry, entries.len);
        defer {
            for (copy_entries) |*entry| entry.deinit(self.alloc);
            self.alloc.free(copy_entries);
        }
        for (entries, 0..) |entry, idx| {
            copy_entries[idx] = .{
                .name = try self.alloc.dupe(u8, entry.name),
                .object_type = entry.object_type,
                .object_id = entry.object_id,
            };
        }
        std.sort.block(TreeEntry, copy_entries, {}, struct {
            fn lessThan(_: void, lhs: TreeEntry, rhs: TreeEntry) bool {
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
        }.lessThan);
        const payload = try encodeTree(self.alloc, .{ .entries = copy_entries });
        defer self.alloc.free(payload);
        return try self.store.put(.tree, payload);
    }

    fn writeSegmentTree(self: *CommitWriter, descriptors: []const SegmentDescriptor) !object_store.ObjectId {
        const HourGroup = struct {
            hour_bucket: i64,
            entries: std.array_list.Managed(TreeEntry),
        };

        const SeriesGroup = struct {
            series_id: types.SeriesId,
            hours: std.array_list.Managed(HourGroup),
        };

        var series_groups = std.array_list.Managed(SeriesGroup).init(self.alloc);
        defer {
            for (series_groups.items) |*series_group| {
                for (series_group.hours.items) |*hour_group| {
                    for (hour_group.entries.items) |*entry| entry.deinit(self.alloc);
                    hour_group.entries.deinit();
                }
                series_group.hours.deinit();
            }
            series_groups.deinit();
        }

        for (descriptors) |descriptor| {
            const descriptor_payload = try encodeSegmentDescriptor(self.alloc, descriptor);
            defer self.alloc.free(descriptor_payload);
            const descriptor_id = try self.store.put(.blob, descriptor_payload);

            var series_group: ?*SeriesGroup = null;
            for (series_groups.items) |*existing| {
                if (existing.series_id == descriptor.series_id) {
                    series_group = existing;
                    break;
                }
            }
            if (series_group == null) {
                try series_groups.append(.{
                    .series_id = descriptor.series_id,
                    .hours = std.array_list.Managed(HourGroup).init(self.alloc),
                });
                series_group = &series_groups.items[series_groups.items.len - 1];
            }

            var hour_group: ?*HourGroup = null;
            for (series_group.?.hours.items) |*existing| {
                if (existing.hour_bucket == descriptor.hour_bucket) {
                    hour_group = existing;
                    break;
                }
            }
            if (hour_group == null) {
                try series_group.?.hours.append(.{
                    .hour_bucket = descriptor.hour_bucket,
                    .entries = std.array_list.Managed(TreeEntry).init(self.alloc),
                });
                hour_group = &series_group.?.hours.items[series_group.?.hours.items.len - 1];
            }

            try hour_group.?.entries.append(.{
                .name = try self.alloc.dupe(u8, std.fs.path.basename(descriptor.mirrorPath())),
                .object_type = .blob,
                .object_id = descriptor_id,
            });
        }

        var segment_entries = std.array_list.Managed(TreeEntry).init(self.alloc);
        defer {
            for (segment_entries.items) |*entry| entry.deinit(self.alloc);
            segment_entries.deinit();
        }

        std.sort.block(SeriesGroup, series_groups.items, {}, struct {
            fn lessThan(_: void, lhs: SeriesGroup, rhs: SeriesGroup) bool {
                return lhs.series_id < rhs.series_id;
            }
        }.lessThan);

        for (series_groups.items) |*series_group| {
            std.sort.block(HourGroup, series_group.hours.items, {}, struct {
                fn lessThan(_: void, lhs: HourGroup, rhs: HourGroup) bool {
                    return lhs.hour_bucket < rhs.hour_bucket;
                }
            }.lessThan);

            var series_entries = std.array_list.Managed(TreeEntry).init(self.alloc);
            defer {
                for (series_entries.items) |*entry| entry.deinit(self.alloc);
                series_entries.deinit();
            }

            for (series_group.hours.items) |*hour_group| {
                std.sort.block(TreeEntry, hour_group.entries.items, {}, struct {
                    fn lessThan(_: void, lhs: TreeEntry, rhs: TreeEntry) bool {
                        return std.mem.lessThan(u8, lhs.name, rhs.name);
                    }
                }.lessThan);
                const hour_tree_id = try self.putTree(hour_group.entries.items);
                try series_entries.append(.{
                    .name = try std.fmt.allocPrint(self.alloc, "{d}", .{hour_group.hour_bucket}),
                    .object_type = .tree,
                    .object_id = hour_tree_id,
                });
            }

            const series_tree_id = try self.putTree(series_entries.items);
            try segment_entries.append(.{
                .name = try std.fmt.allocPrint(self.alloc, "{x}", .{series_group.series_id}),
                .object_type = .tree,
                .object_id = series_tree_id,
            });
        }

        return try self.putTree(segment_entries.items);
    }
};

pub const CommitReader = struct {
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    refs: *RefStore,

    pub fn loadHeadSnapshot(self: *CommitReader) !Snapshot {
        const head = try self.refs.readHead(main_ref) orelse return error.CasHeadMissing;
        return try self.loadSnapshot(head);
    }

    pub fn loadSnapshot(self: *CommitReader, commit_id: object_store.ObjectId) !Snapshot {
        const commit_loaded = try self.store.get(self.alloc, commit_id);
        defer self.alloc.free(commit_loaded.payload);
        if (commit_loaded.obj_type != .commit) return error.InvalidCommitObject;

        var commit = try decodeCommit(self.alloc, commit_loaded.payload);
        errdefer commit.deinit(self.alloc);

        var root_tree = try self.loadTreeObject(commit.root);
        defer root_tree.deinit(self.alloc);

        const metadata_tree_id = findTreeEntry(root_tree.entries, "metadata") orelse return error.MissingMetadataTree;
        const wal_tree_id = findTreeEntry(root_tree.entries, "wal") orelse return error.MissingWalTree;

        var tag_snapshot = try TagSnapshot.empty(self.alloc);
        errdefer tag_snapshot.deinit(self.alloc);
        var series_catalog_snapshot = try SeriesCatalogSnapshot.empty(self.alloc);
        errdefer series_catalog_snapshot.deinit(self.alloc);
        var wal_index = try WalIndex.empty(self.alloc);
        errdefer wal_index.deinit(self.alloc);

        var descriptors = std.array_list.Managed(SegmentDescriptor).init(self.alloc);
        errdefer {
            for (descriptors.items) |*descriptor| descriptor.deinit(self.alloc);
            descriptors.deinit();
        }

        {
            var metadata_tree = try self.loadTreeObject(metadata_tree_id);
            defer metadata_tree.deinit(self.alloc);

            if (findBlobEntry(metadata_tree.entries, "tags")) |tag_blob_id| {
                const loaded = try self.store.get(self.alloc, tag_blob_id);
                defer self.alloc.free(loaded.payload);
                if (loaded.obj_type != .blob) return error.InvalidTagSnapshotObject;
                tag_snapshot.deinit(self.alloc);
                tag_snapshot = try decodeTagSnapshot(self.alloc, loaded.payload);
            }

            if (findBlobEntry(metadata_tree.entries, "series_catalog")) |series_blob_id| {
                const loaded = try self.store.get(self.alloc, series_blob_id);
                defer self.alloc.free(loaded.payload);
                if (loaded.obj_type != .blob) return error.InvalidSeriesCatalogSnapshotObject;
                series_catalog_snapshot.deinit(self.alloc);
                series_catalog_snapshot = try decodeSeriesCatalogSnapshot(self.alloc, loaded.payload);
            }

            if (findTreeEntry(metadata_tree.entries, "segments")) |segments_tree_id| {
                try self.loadSegmentDescriptorsRecursive(segments_tree_id, &descriptors);
            }
        }

        {
            var wal_tree = try self.loadTreeObject(wal_tree_id);
            defer wal_tree.deinit(self.alloc);

            if (findBlobEntry(wal_tree.entries, "index")) |wal_blob_id| {
                const loaded = try self.store.get(self.alloc, wal_blob_id);
                defer self.alloc.free(loaded.payload);
                if (loaded.obj_type != .blob) return error.InvalidWalIndexObject;
                wal_index.deinit(self.alloc);
                wal_index = try decodeWalIndex(self.alloc, loaded.payload);
            }
        }

        sortDescriptors(descriptors.items);
        sortSeriesCatalogEntries(series_catalog_snapshot.entries);

        return .{
            .commit_id = commit_id,
            .root_id = commit.root,
            .commit = commit,
            .segment_descriptors = try descriptors.toOwnedSlice(),
            .tag_snapshot = tag_snapshot,
            .series_catalog_snapshot = series_catalog_snapshot,
            .wal_index = wal_index,
        };
    }

    pub fn verifyHeadMatchesLegacy(
        self: *CommitReader,
        data_dir: std.fs.Dir,
        manifest: *const manifest_mod.Manifest,
        tags: *const tags_mod.TagIndex,
        series_catalog: *const series_catalog_mod.SeriesCatalog,
    ) !void {
        var live = try buildLegacySnapshot(self.alloc, data_dir, manifest, tags, series_catalog, self.store, default_extent_chunk_bytes);
        defer live.deinit(self.alloc);

        var stored = try self.loadHeadSnapshot();
        defer stored.deinit(self.alloc);

        try verifyLegacySnapshot(live, stored);
        try verifyWalFiles(self.alloc, stored.wal_index, data_dir, self.store);
    }

    fn loadTreeObject(self: *CommitReader, id: object_store.ObjectId) !Tree {
        const loaded = try self.store.get(self.alloc, id);
        defer self.alloc.free(loaded.payload);
        if (loaded.obj_type != .tree) return error.InvalidTreeObject;
        return try decodeTree(self.alloc, loaded.payload);
    }

    fn loadSegmentDescriptorsRecursive(self: *CommitReader, tree_id: object_store.ObjectId, descriptors: *std.array_list.Managed(SegmentDescriptor)) !void {
        var tree = try self.loadTreeObject(tree_id);
        defer tree.deinit(self.alloc);

        for (tree.entries) |entry| {
            switch (entry.object_type) {
                .tree => try self.loadSegmentDescriptorsRecursive(entry.object_id, descriptors),
                .blob => {
                    const loaded = try self.store.get(self.alloc, entry.object_id);
                    defer self.alloc.free(loaded.payload);
                    if (loaded.obj_type != .blob) return error.InvalidSegmentDescriptorObject;
                    try descriptors.append(try decodeSegmentDescriptor(self.alloc, loaded.payload));
                },
                else => return error.InvalidSegmentTreeEntry,
            }
        }
    }
};

pub const LogEntry = struct {
    commit_id: object_store.ObjectId,
    created_at_ms: i64,
    reason: []u8,
    parent_count: usize,

    pub fn deinit(self: *LogEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.reason);
    }
};

pub const SnapshotDiff = struct {
    segments_added: usize,
    segments_removed: usize,
    tags_changed: usize,
    series_entries_changed: usize,
    wal_chunks_added: usize,
    wal_chunks_removed: usize,
};

pub const GcResult = struct {
    reachable: usize,
    unreachable_count: usize,
    unreachable_bytes: u64,
    reflog_protected: usize,
    quarantined_count: usize,
    quarantined_bytes: u64,
    pruned_count: usize,
    pruned_bytes: u64,
    deleted: usize,
    stale_segment_files: usize,
    stale_segment_bytes: u64,
    stale_wal_files: usize,
    stale_wal_bytes: u64,
    mirror_deleted: usize,
};

pub const FsckMode = enum {
    connectivity_only,
    full,
};

pub const GcOptions = struct {
    dry_run: bool = true,
    include_reflogs: bool = true,
    grace_period_ms: i64 = 24 * 60 * 60 * 1000,
};

pub const FsckOptions = struct {
    mode: FsckMode = .full,
    include_reflogs: bool = true,
    write_lost_found: bool = false,
};

pub const FsckReport = struct {
    refs: usize,
    reachable_objects: usize,
    reflog_heads: usize,
    reflog_protected_objects: usize,
    commit_objects: usize,
    tree_objects: usize,
    blob_objects: usize,
    commit_graph_entries_checked: usize,
    segment_contents_checked: usize,
    wal_contents_checked: usize,
    missing_segment_mirrors: usize,
    missing_wal_mirrors: usize,
    reflog_files_checked: usize,
    stale_reflog_files: usize,
    dangling_objects: usize,
    lost_found_objects: usize,
};

pub const PackResult = struct {
    reachable_objects: usize,
    rewritten_objects: usize,
};

const commit_graph_path = "objects/info/commit-graph";
const commit_graph_magic = "SYDCGR1\x00";

const CommitGraph = struct {
    object_ids: []object_store.ObjectId,
    roots: []object_store.ObjectId,
    created_at_ms: []i64,
    generations: []u32,
    parent_offsets: []u64,
    parent_positions: []u64,
    reason_offsets: []u64,
    reasons: []u8,

    fn deinit(self: *CommitGraph, alloc: std.mem.Allocator) void {
        alloc.free(self.object_ids);
        alloc.free(self.roots);
        alloc.free(self.created_at_ms);
        alloc.free(self.generations);
        alloc.free(self.parent_offsets);
        alloc.free(self.parent_positions);
        alloc.free(self.reason_offsets);
        alloc.free(self.reasons);
    }

    fn lookup(self: *const CommitGraph, id: object_store.ObjectId) ?usize {
        var lo: usize = 0;
        var hi: usize = self.object_ids.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const candidate = self.object_ids[mid];
            if (candidate.eql(id)) return mid;
            if (std.mem.lessThan(u8, candidate.hash[0..], id.hash[0..])) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    fn reasonFor(self: *const CommitGraph, idx: usize) []const u8 {
        const start: usize = @intCast(self.reason_offsets[idx]);
        const end: usize = @intCast(self.reason_offsets[idx + 1]);
        return self.reasons[start..end];
    }

    fn rootFor(self: *const CommitGraph, id: object_store.ObjectId) ?object_store.ObjectId {
        const idx = self.lookup(id) orelse return null;
        return self.roots[idx];
    }

    fn toLogEntries(self: *const CommitGraph, alloc: std.mem.Allocator, start_id: object_store.ObjectId, max_entries: usize) ![]LogEntry {
        const start_idx = self.lookup(start_id) orelse return error.CommitGraphMissingCommit;
        var out = std.array_list.Managed(LogEntry).init(alloc);
        errdefer {
            for (out.items) |*entry| entry.deinit(alloc);
            out.deinit();
        }

        var next_idx: ?usize = start_idx;
        while (next_idx != null and out.items.len < max_entries) {
            const idx = next_idx.?;
            try out.append(.{
                .commit_id = self.object_ids[idx],
                .created_at_ms = self.created_at_ms[idx],
                .reason = try alloc.dupe(u8, self.reasonFor(idx)),
                .parent_count = @intCast(self.parent_offsets[idx + 1] - self.parent_offsets[idx]),
            });
            next_idx = if (self.parent_offsets[idx + 1] == self.parent_offsets[idx])
                null
            else
                @as(usize, @intCast(self.parent_positions[@intCast(self.parent_offsets[idx])]));
        }
        return try out.toOwnedSlice();
    }
};

const ReachabilityInputs = struct {
    refs: []RefEntry,
    reflog_ids: []object_store.ObjectId,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.refs) |*entry| entry.deinit(alloc);
        alloc.free(self.refs);
        alloc.free(self.reflog_ids);
    }
};

pub const CasManager = struct {
    alloc: std.mem.Allocator,
    store: object_store.ObjectStore,
    refs: RefStore,
    format: RepositoryFormat,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, fsync: cfg.FsyncPolicy) !CasManager {
        var store = try object_store.ObjectStore.init(alloc, path, fsync);
        errdefer store.deinit();
        const format = try loadOrInitRepositoryFormat(alloc, store.root, fsync);
        return .{
            .alloc = alloc,
            .store = store,
            .refs = try RefStore.init(alloc, path, fsync),
            .format = format,
        };
    }

    pub fn deinit(self: *CasManager) void {
        self.refs.deinit();
        self.store.deinit();
    }

    pub fn bootstrapIfMissing(
        self: *CasManager,
        data_dir: std.fs.Dir,
        manifest: *const manifest_mod.Manifest,
        tags: *const tags_mod.TagIndex,
        series_catalog: *const series_catalog_mod.SeriesCatalog,
    ) !object_store.ObjectId {
        if (try self.refs.readHead(main_ref)) |head| return head;
        var writer = CommitWriter{ .alloc = self.alloc, .store = &self.store, .extent_chunk_bytes = self.format.extent_chunk_bytes };
        const commit_id = try writer.writeSnapshot(data_dir, manifest, tags, series_catalog, null, "bootstrap");
        try self.refs.compareAndSwapRef(main_ref, null, commit_id, "bootstrap");
        try self.refreshCommitGraph();
        return commit_id;
    }

    pub fn syncLegacySnapshot(
        self: *CasManager,
        data_dir: std.fs.Dir,
        manifest: *const manifest_mod.Manifest,
        tags: *const tags_mod.TagIndex,
        series_catalog: *const series_catalog_mod.SeriesCatalog,
        reason: []const u8,
    ) !object_store.ObjectId {
        const parent = try self.refs.readHead(main_ref);
        var writer = CommitWriter{ .alloc = self.alloc, .store = &self.store, .extent_chunk_bytes = self.format.extent_chunk_bytes };
        const commit_id = try writer.writeSnapshot(data_dir, manifest, tags, series_catalog, parent, reason);
        try self.refs.compareAndSwapRef(main_ref, parent, commit_id, reason);
        try self.refreshCommitGraph();
        return commit_id;
    }

    pub fn verifyHeadMatchesLegacy(
        self: *CasManager,
        data_dir: std.fs.Dir,
        manifest: *const manifest_mod.Manifest,
        tags: *const tags_mod.TagIndex,
        series_catalog: *const series_catalog_mod.SeriesCatalog,
    ) !void {
        var reader = CommitReader{ .alloc = self.alloc, .store = &self.store, .refs = &self.refs };
        try reader.verifyHeadMatchesLegacy(data_dir, manifest, tags, series_catalog);
    }

    pub fn loadHeadIndex(self: *CasManager) !SnapshotIndex {
        var reader = CommitReader{ .alloc = self.alloc, .store = &self.store, .refs = &self.refs };
        return SnapshotIndex.init(self.alloc, &self.store, try reader.loadHeadSnapshot());
    }

    pub fn verifyHead(self: *CasManager, data_dir: std.fs.Dir, manifest: *const manifest_mod.Manifest, tags: *const tags_mod.TagIndex, series_catalog: *const series_catalog_mod.SeriesCatalog) !void {
        try self.verifyHeadMatchesLegacy(data_dir, manifest, tags, series_catalog);
        const refs = try self.refs.listRefs(self.alloc);
        defer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }
        _ = try self.collectReachable(refs);
        _ = loadCommitGraph(self.alloc, self.store.root) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    pub fn listRefs(self: *CasManager) ![]RefEntry {
        return try self.refs.listRefs(self.alloc);
    }

    pub fn resolveCommitSpec(self: *CasManager, spec: []const u8) !object_store.ObjectId {
        if (spec.len == 64) {
            return try object_store.ObjectId.fromHex(spec);
        }

        const normalized = if (std.mem.startsWith(u8, spec, "refs/")) spec["refs/".len..] else spec;
        return try self.refs.readRef(normalized) orelse error.RefNotFound;
    }

    pub fn loadLog(self: *CasManager, spec: []const u8, max_entries: usize) ![]LogEntry {
        const start = try self.resolveCommitSpec(spec);
        if (loadCommitGraph(self.alloc, self.store.root)) |loaded_graph| {
            var graph = loaded_graph;
            defer graph.deinit(self.alloc);
            return try graph.toLogEntries(self.alloc, start, max_entries);
        } else |err| switch (err) {
            error.FileNotFound,
            error.CorruptCommitGraph,
            error.UnsupportedCommitGraphVersion,
            => {},
            else => return err,
        }

        var out = std.array_list.Managed(LogEntry).init(self.alloc);
        errdefer {
            for (out.items) |*entry| entry.deinit(self.alloc);
            out.deinit();
        }

        var next_id: ?object_store.ObjectId = start;
        while (next_id != null and out.items.len < max_entries) {
            const commit_id = next_id.?;
            const loaded = try self.store.get(self.alloc, commit_id);
            defer self.alloc.free(loaded.payload);
            if (loaded.obj_type != .commit) return error.InvalidCommitObject;

            var commit = try decodeCommit(self.alloc, loaded.payload);
            defer commit.deinit(self.alloc);
            try out.append(.{
                .commit_id = commit_id,
                .created_at_ms = commit.created_at_ms,
                .reason = try self.alloc.dupe(u8, commit.reason),
                .parent_count = commit.parents.len,
            });
            next_id = if (commit.parents.len == 0) null else commit.parents[0];
        }

        return try out.toOwnedSlice();
    }

    pub fn createRef(self: *CasManager, ref_name: []const u8, spec: []const u8) !void {
        const commit_id = try self.resolveCommitSpec(spec);
        try self.refs.updateRefTxn(&[_]RefTxnUpdate{.{
            .ref_name = ref_name,
            .new_id = commit_id,
        }}, "create-ref");
        try self.refreshCommitGraph();
    }

    pub fn createCheckpoint(self: *CasManager, prefix: []const u8) !?[]u8 {
        const head = try self.refs.readHead(main_ref) orelse return null;
        const ref_name = try std.fmt.allocPrint(self.alloc, "checkpoints/{s}-{d}", .{ prefix, std.time.milliTimestamp() });
        errdefer self.alloc.free(ref_name);
        try self.refs.updateRefTxn(&[_]RefTxnUpdate{.{
            .ref_name = ref_name,
            .new_id = head,
        }}, prefix);
        try self.refreshCommitGraph();
        return ref_name;
    }

    pub fn rollbackMainTo(self: *CasManager, spec: []const u8) !void {
        const target = try self.resolveCommitSpec(spec);
        const current = try self.refs.readHead(main_ref);
        const reason = try std.fmt.allocPrint(self.alloc, "rollback:{s}", .{spec});
        defer self.alloc.free(reason);
        try self.refs.compareAndSwapRef(main_ref, current, target, reason);
        try self.refreshCommitGraph();
    }

    pub fn loadSnapshotForSpec(self: *CasManager, spec: []const u8) !Snapshot {
        const commit_id = try self.resolveCommitSpec(spec);
        var reader = CommitReader{ .alloc = self.alloc, .store = &self.store, .refs = &self.refs };
        return try reader.loadSnapshot(commit_id);
    }

    pub fn diffSnapshots(self: *CasManager, lhs_spec: []const u8, rhs_spec: []const u8) !SnapshotDiff {
        const lhs_commit_id = try self.resolveCommitSpec(lhs_spec);
        const rhs_commit_id = try self.resolveCommitSpec(rhs_spec);
        if (loadCommitGraph(self.alloc, self.store.root)) |loaded_graph| {
            var graph = loaded_graph;
            defer graph.deinit(self.alloc);
            if (graph.rootFor(lhs_commit_id)) |lhs_root| {
                if (graph.rootFor(rhs_commit_id)) |rhs_root| {
                    if (lhs_root.eql(rhs_root)) return .{
                        .segments_added = 0,
                        .segments_removed = 0,
                        .tags_changed = 0,
                        .series_entries_changed = 0,
                        .wal_chunks_added = 0,
                        .wal_chunks_removed = 0,
                    };
                }
            }
        } else |err| switch (err) {
            error.FileNotFound,
            error.CorruptCommitGraph,
            error.UnsupportedCommitGraphVersion,
            => {},
            else => return err,
        }

        var lhs = try self.loadSnapshotForSpec(lhs_spec);
        defer lhs.deinit(self.alloc);
        var rhs = try self.loadSnapshotForSpec(rhs_spec);
        defer rhs.deinit(self.alloc);

        return .{
            .segments_added = countDescriptorsNotIn(rhs.segment_descriptors, lhs.segment_descriptors),
            .segments_removed = countDescriptorsNotIn(lhs.segment_descriptors, rhs.segment_descriptors),
            .tags_changed = countTagEntriesChanged(lhs.tag_snapshot.entries, rhs.tag_snapshot.entries),
            .series_entries_changed = countSeriesEntriesChanged(lhs.series_catalog_snapshot.entries, rhs.series_catalog_snapshot.entries),
            .wal_chunks_added = countWalChunksNotIn(rhs.wal_index.entries, lhs.wal_index.entries),
            .wal_chunks_removed = countWalChunksNotIn(lhs.wal_index.entries, rhs.wal_index.entries),
        };
    }

    pub fn exportHeadToLegacy(self: *CasManager, data_dir: std.fs.Dir) !void {
        try self.exportSpecToLegacy(main_ref, data_dir);
    }

    pub fn exportSpecToLegacy(self: *CasManager, spec: []const u8, data_dir: std.fs.Dir) !void {
        var snapshot = try self.loadSnapshotForSpec(spec);
        defer snapshot.deinit(self.alloc);

        try materializeSnapshotMirrors(self.alloc, data_dir, &self.store, snapshot);
        try writeManifestFile(self.alloc, data_dir, snapshot.segment_descriptors);
        try writeTagsFile(self.alloc, data_dir, snapshot.tag_snapshot);
        try writeSeriesCatalogFile(self.alloc, data_dir, snapshot.series_catalog_snapshot);
        _ = try cleanupStaleMirrors(self.alloc, data_dir, snapshot, false);
    }

    pub fn gc(self: *CasManager, options: GcOptions) !GcResult {
        var inputs = try self.collectReachabilityInputs(options.include_reflogs);
        defer inputs.deinit(self.alloc);

        var reachable = try self.collectReachableFromInputs(inputs);
        defer reachable.deinit();

        var direct_reachable = try self.collectReachable(inputs.refs);
        defer direct_reachable.deinit();

        const all = try self.store.listIds(self.alloc);
        defer self.alloc.free(all);

        var unreachable_ids = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer unreachable_ids.deinit();

        var unreachable_bytes: u64 = 0;
        for (all) |id| {
            if (reachable.contains(id)) continue;
            try unreachable_ids.append(id);
            unreachable_bytes += try objectSize(self.alloc, &self.store, id);
        }

        const now_ms = std.time.milliTimestamp();
        const existing_pack_paths = try listFilesRecursive(self.alloc, self.store.root, "objects/packs");
        defer freeOwnedStrings(self.alloc, existing_pack_paths);

        var deleted: usize = 0;
        var quarantined_count: usize = 0;
        var quarantined_bytes: u64 = 0;
        if (!options.dry_run and unreachable_ids.items.len > 0) {
            const stamp_ms = now_ms;
            if (existing_pack_paths.len > 0) {
                try quarantinePackFiles(self.alloc, self.store.root, existing_pack_paths, stamp_ms);
                if (reachable.count() > 0) {
                    var reachable_ids = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
                    defer reachable_ids.deinit();
                    var it = reachable.keyIterator();
                    while (it.next()) |id_ptr| try reachable_ids.append(id_ptr.*);
                    var pack_write = try self.store.writePack(self.alloc, reachable_ids.items);
                    defer pack_write.deinit(self.alloc);
                } else {
                    try deleteActivePackFiles(self.store.root, existing_pack_paths);
                }
            }

            for (unreachable_ids.items) |id| {
                _ = try moveLooseObjectToCruft(self.alloc, self.store.root, id, stamp_ms);
            }
            quarantined_count = unreachable_ids.items.len;
            quarantined_bytes = unreachable_bytes;
            deleted = unreachable_ids.items.len;
        }

        var prunable = try scanExpiredCruft(self.alloc, self.store.root, now_ms, options.grace_period_ms);
        defer prunable.deinit(self.alloc);

        var pruned_count: usize = 0;
        var pruned_bytes: u64 = 0;
        if (!options.dry_run) {
            for (prunable.entries) |entry| {
                try self.store.root.deleteTree(entry.path);
                pruned_count += entry.file_count;
                pruned_bytes += entry.bytes;
            }
        } else {
            for (prunable.entries) |entry| {
                pruned_count += entry.file_count;
                pruned_bytes += entry.bytes;
            }
        }

        var stale_segment_files: usize = 0;
        var stale_segment_bytes: u64 = 0;
        var stale_wal_files: usize = 0;
        var stale_wal_bytes: u64 = 0;
        var mirror_deleted: usize = 0;

        if (try self.refs.readHead(main_ref) != null) {
            var head = try self.loadHeadIndex();
            defer head.deinit();

            const mirror_result = try cleanupStaleMirrors(self.alloc, self.store.root, head.snapshot, options.dry_run);
            stale_segment_files = mirror_result.stale_segment_files;
            stale_segment_bytes = mirror_result.stale_segment_bytes;
            stale_wal_files = mirror_result.stale_wal_files;
            stale_wal_bytes = mirror_result.stale_wal_bytes;
            mirror_deleted = mirror_result.deleted;
        }

        return .{
            .reachable = reachable.count(),
            .unreachable_count = unreachable_ids.items.len,
            .unreachable_bytes = unreachable_bytes,
            .reflog_protected = countProtectedObjects(&reachable, &direct_reachable),
            .quarantined_count = quarantined_count,
            .quarantined_bytes = quarantined_bytes,
            .pruned_count = pruned_count,
            .pruned_bytes = pruned_bytes,
            .deleted = deleted,
            .stale_segment_files = stale_segment_files,
            .stale_segment_bytes = stale_segment_bytes,
            .stale_wal_files = stale_wal_files,
            .stale_wal_bytes = stale_wal_bytes,
            .mirror_deleted = mirror_deleted,
        };
    }

    pub fn fsck(self: *CasManager, data_dir: std.fs.Dir, options: FsckOptions) !FsckReport {
        var inputs = try self.collectReachabilityInputs(options.include_reflogs);
        defer inputs.deinit(self.alloc);

        var reachable = try self.collectReachableFromInputs(inputs);
        defer reachable.deinit();
        var direct_reachable = try self.collectReachable(inputs.refs);
        defer direct_reachable.deinit();

        var report = FsckReport{
            .refs = inputs.refs.len,
            .reachable_objects = direct_reachable.count(),
            .reflog_heads = inputs.reflog_ids.len,
            .reflog_protected_objects = countProtectedObjects(&reachable, &direct_reachable),
            .commit_objects = 0,
            .tree_objects = 0,
            .blob_objects = 0,
            .commit_graph_entries_checked = 0,
            .segment_contents_checked = 0,
            .wal_contents_checked = 0,
            .missing_segment_mirrors = 0,
            .missing_wal_mirrors = 0,
            .reflog_files_checked = 0,
            .stale_reflog_files = 0,
            .dangling_objects = 0,
            .lost_found_objects = 0,
        };

        var it = direct_reachable.keyIterator();
        while (it.next()) |id_ptr| {
            const loaded = try self.store.get(self.alloc, id_ptr.*);
            defer self.alloc.free(loaded.payload);
            switch (loaded.obj_type) {
                .commit => report.commit_objects += 1,
                .tree => report.tree_objects += 1,
                .blob => report.blob_objects += 1,
                else => return error.UnsupportedCasObjectType,
            }
        }

        if (loadCommitGraph(self.alloc, self.store.root)) |loaded_graph| {
            var graph = loaded_graph;
            defer graph.deinit(self.alloc);
            if (graph.object_ids.len < report.commit_objects) return error.CorruptCommitGraph;
            for (graph.object_ids, 0..) |commit_id, idx| {
                if (!reachable.contains(commit_id)) continue;
                const loaded = try self.store.get(self.alloc, commit_id);
                defer self.alloc.free(loaded.payload);
                if (loaded.obj_type != .commit) return error.InvalidCommitObject;
                var commit = try decodeCommit(self.alloc, loaded.payload);
                defer commit.deinit(self.alloc);
                if (!graph.roots[idx].eql(commit.root)) return error.CorruptCommitGraph;
                if (graph.created_at_ms[idx] != commit.created_at_ms) return error.CorruptCommitGraph;
                const parent_start: usize = @intCast(graph.parent_offsets[idx]);
                const parent_end: usize = @intCast(graph.parent_offsets[idx + 1]);
                if ((parent_end - parent_start) != commit.parents.len) return error.CorruptCommitGraph;
                for (commit.parents, parent_start..) |parent, graph_parent_idx| {
                    const parent_pos: usize = @intCast(graph.parent_positions[graph_parent_idx]);
                    if (!graph.object_ids[parent_pos].eql(parent)) return error.CorruptCommitGraph;
                }
                report.commit_graph_entries_checked += 1;
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        if (options.mode == .full and try self.refs.readHead(main_ref) != null) {
            var snapshot = try self.loadHeadIndex();
            defer snapshot.deinit();

            for (snapshot.snapshot.segment_descriptors) |descriptor| {
                if (descriptor.contentRef()) |content| {
                    switch (content) {
                        .blob => |content_id| {
                            const loaded = try self.store.get(self.alloc, content_id);
                            defer self.alloc.free(loaded.payload);
                            if (loaded.obj_type != .blob) return error.InvalidSegmentContentObject;
                            const points = try segment_mod.readAllFromBytes(self.alloc, loaded.payload);
                            self.alloc.free(points);
                        },
                        .extent_tree => |tree| {
                            const bytes = try extents.readAll(self.alloc, &self.store, tree);
                            defer self.alloc.free(bytes);
                            const points = try segment_mod.readAllFromBytes(self.alloc, bytes);
                            self.alloc.free(points);
                        },
                    }
                    report.segment_contents_checked += 1;
                }
                if (descriptor.mirrorPath().len != 0) {
                    _ = data_dir.statFile(descriptor.mirrorPath()) catch |err| switch (err) {
                        error.FileNotFound => report.missing_segment_mirrors += 1,
                        else => return err,
                    };
                }
            }

            for (snapshot.snapshot.wal_index.entries) |entry| {
                if (entry.contentRef()) |content| {
                    var noop_ctx = struct {
                        pub fn onSeriesRegistration(_: *@This(), _: types.SeriesId, _: []const u8, _: []const u8) !void {}
                        pub fn onRecord(_: *@This(), _: types.SeriesId, _: i64, _: f64) !void {}
                    }{};
                    switch (content) {
                        .blob => |content_id| {
                            const loaded = try self.store.get(self.alloc, content_id);
                            defer self.alloc.free(loaded.payload);
                            if (loaded.obj_type != .blob) return error.InvalidWalChunkObject;
                            try wal_mod.replayBytes(self.alloc, loaded.payload, &noop_ctx);
                        },
                        .extent_tree => |tree| {
                            const bytes = try extents.readAll(self.alloc, &self.store, tree);
                            defer self.alloc.free(bytes);
                            try wal_mod.replayBytes(self.alloc, bytes, &noop_ctx);
                        },
                    }
                    report.wal_contents_checked += 1;
                }

                const path = try std.fmt.allocPrint(self.alloc, "wal/{s}", .{entry.mirrorName()});
                defer self.alloc.free(path);
                _ = data_dir.statFile(path) catch |err| switch (err) {
                    error.FileNotFound => report.missing_wal_mirrors += 1,
                    else => return err,
                };
            }
        }

        const reflog_files = try listFilesRecursive(self.alloc, self.store.root, "logs/refs");
        defer freeOwnedStrings(self.alloc, reflog_files);
        for (reflog_files) |path| {
            try validateReflogFile(self.alloc, self.store.root, path);
            report.reflog_files_checked += 1;
            const ref_name = path["logs/refs/".len..];
            if (!containsRef(inputs.refs, ref_name)) {
                report.stale_reflog_files += 1;
            }
        }

        const all = try self.store.listIds(self.alloc);
        defer self.alloc.free(all);
        var dangling = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer dangling.deinit();
        for (all) |id| {
            if (!reachable.contains(id)) try dangling.append(id);
        }
        report.dangling_objects = dangling.items.len;
        if (options.write_lost_found) {
            report.lost_found_objects = try writeLostFoundEntries(self.alloc, self.store.root, &self.store, dangling.items);
        }

        return report;
    }

    pub fn pack(self: *CasManager) !PackResult {
        const refs = try self.refs.listRefs(self.alloc);
        defer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }

        var reachable = try self.collectReachable(refs);
        defer reachable.deinit();

        const all_ids = try self.store.listIds(self.alloc);
        defer self.alloc.free(all_ids);

        var ids = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer ids.deinit();
        var it = reachable.keyIterator();
        while (it.next()) |id_ptr| {
            try ids.append(id_ptr.*);
        }

        var rewritten_objects: usize = 0;
        if (ids.items.len > 0) {
            var pack_write = try self.store.writePack(self.alloc, ids.items);
            defer pack_write.deinit(self.alloc);
            rewritten_objects = pack_write.object_count;
        } else {
            const existing_pack_paths = try listFilesRecursive(self.alloc, self.store.root, "objects/packs");
            defer freeOwnedStrings(self.alloc, existing_pack_paths);
            try deleteActivePackFiles(self.store.root, existing_pack_paths);
        }

        for (all_ids) |id| {
            if (reachable.contains(id)) continue;
            self.store.delete(id) catch |err| switch (err) {
                error.FileNotFound, error.ObjectStoredInPack => {},
                else => return err,
            };
        }

        return .{
            .reachable_objects = reachable.count(),
            .rewritten_objects = rewritten_objects,
        };
    }

    fn refreshCommitGraph(self: *CasManager) !void {
        const refs = try self.refs.listRefs(self.alloc);
        defer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }
        var graph = try buildCommitGraph(self.alloc, &self.store, refs);
        defer graph.deinit(self.alloc);
        try writeCommitGraph(self.alloc, self.store.root, graph, self.store.fsync);
    }

    fn collectReachabilityInputs(self: *CasManager, include_reflogs: bool) !ReachabilityInputs {
        const refs = try self.refs.listRefs(self.alloc);
        errdefer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }

        const reflog_ids = if (include_reflogs)
            try collectReflogObjectIds(self.alloc, self.store.root)
        else
            try self.alloc.alloc(object_store.ObjectId, 0);
        errdefer self.alloc.free(reflog_ids);

        return .{
            .refs = refs,
            .reflog_ids = reflog_ids,
        };
    }

    fn collectReachableFromInputs(self: *CasManager, inputs: ReachabilityInputs) !std.AutoHashMap(object_store.ObjectId, void) {
        var starts = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer starts.deinit();
        for (inputs.refs) |entry| try starts.append(entry.id);
        try starts.appendSlice(inputs.reflog_ids);
        return try self.collectReachableFromIds(starts.items);
    }

    fn collectReachable(self: *CasManager, refs: []const RefEntry) !std.AutoHashMap(object_store.ObjectId, void) {
        var starts = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer starts.deinit();
        for (refs) |entry| try starts.append(entry.id);
        return try self.collectReachableFromIds(starts.items);
    }

    fn collectReachableFromIds(self: *CasManager, starts: []const object_store.ObjectId) !std.AutoHashMap(object_store.ObjectId, void) {
        var seen = std.AutoHashMap(object_store.ObjectId, void).init(self.alloc);
        errdefer seen.deinit();

        var stack = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer stack.deinit();

        for (starts) |id| {
            try stack.append(id);
        }

        while (stack.pop()) |id| {
            const gop = try seen.getOrPut(id);
            if (gop.found_existing) continue;

            const loaded = try self.store.get(self.alloc, id);
            defer self.alloc.free(loaded.payload);

            switch (loaded.obj_type) {
                .commit => {
                    var commit = try decodeCommit(self.alloc, loaded.payload);
                    defer commit.deinit(self.alloc);
                    try stack.append(commit.root);
                    for (commit.parents) |parent| {
                        try stack.append(parent);
                    }
                },
                .tree => {
                    var tree = try decodeTree(self.alloc, loaded.payload);
                    defer tree.deinit(self.alloc);
                    for (tree.entries) |entry| {
                        try stack.append(entry.object_id);
                    }
                },
                .blob => try appendReferencedBlobObjects(&stack, loaded.payload),
                else => return error.UnsupportedCasObjectType,
            }
        }

        return seen;
    }
};

fn appendReferencedBlobObjects(
    stack: *std.array_list.Managed(object_store.ObjectId),
    payload: []const u8,
) !void {
    if (appendSegmentDescriptorBlob(stack, payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    }) return;
    _ = appendWalIndexBlob(stack, payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
}

fn appendSegmentDescriptorBlob(
    stack: *std.array_list.Managed(object_store.ObjectId),
    payload: []const u8,
) !bool {
    const original_len = stack.items.len;
    errdefer stack.items.len = original_len;

    if (payload.len == 0) return false;

    var idx: usize = 0;
    const version = payload[idx];
    idx += 1;
    if (version != 1 and version != 2 and version != 3 and version != 4) return false;

    var content_root: ?object_store.ObjectId = null;
    switch (version) {
        1 => {},
        2 => {
            if (idx >= payload.len) return false;
            const flag = payload[idx];
            idx += 1;
            switch (flag) {
                0 => {},
                1 => content_root = .{ .hash = try readHashAt(payload, &idx) },
                else => return false,
            }
        },
        3 => {
            content_root = .{ .hash = try readHashAt(payload, &idx) };
        },
        4 => {
            const kind = try readByteAt(payload, &idx);
            switch (kind) {
                0 => {},
                1 => content_root = .{ .hash = try readHashAt(payload, &idx) },
                2 => {
                    content_root = .{ .hash = try readHashAt(payload, &idx) };
                    _ = try readIntAt(payload, &idx, u64);
                    _ = try readIntAt(payload, &idx, u32);
                },
                else => return false,
            }
        },
        else => unreachable,
    }

    _ = try readStringAt(payload, &idx);
    idx += 32; // file hash
    _ = try readIntAt(payload, &idx, u64); // file_size
    _ = try readIntAt(payload, &idx, u64); // series_id
    _ = try readIntAt(payload, &idx, i64); // hour_bucket
    _ = try readIntAt(payload, &idx, i64); // start_ts
    _ = try readIntAt(payload, &idx, i64); // end_ts
    _ = try readIntAt(payload, &idx, u32); // count
    if (idx + 2 != payload.len) return false;

    if (content_root) |id| try stack.append(id);
    return true;
}

fn appendWalIndexBlob(
    stack: *std.array_list.Managed(object_store.ObjectId),
    payload: []const u8,
) !bool {
    const original_len = stack.items.len;
    errdefer stack.items.len = original_len;

    if (payload.len == 0) return false;

    var idx: usize = 0;
    const version = payload[idx];
    idx += 1;
    if (version != 1 and version != 2 and version != 3 and version != 4) return false;

    const entry_count = try readIntAt(payload, &idx, u32);
    var entry_idx: u32 = 0;
    while (entry_idx < entry_count) : (entry_idx += 1) {
        _ = try readStringAt(payload, &idx);

        switch (version) {
            1 => {},
            2 => {
                if (idx >= payload.len) return false;
                const flag = payload[idx];
                idx += 1;
                switch (flag) {
                    0 => {},
                    1 => try stack.append(.{ .hash = try readHashAt(payload, &idx) }),
                    else => return false,
                }
            },
            3 => try stack.append(.{ .hash = try readHashAt(payload, &idx) }),
            4 => {
                const kind = try readByteAt(payload, &idx);
                switch (kind) {
                    0 => {},
                    1 => try stack.append(.{ .hash = try readHashAt(payload, &idx) }),
                    2 => {
                        try stack.append(.{ .hash = try readHashAt(payload, &idx) });
                        _ = try readIntAt(payload, &idx, u64);
                        _ = try readIntAt(payload, &idx, u32);
                    },
                    else => return false,
                }
            },
            else => unreachable,
        }

        _ = try readIntAt(payload, &idx, u64); // file_size
        idx += 32; // file_hash
        if (idx >= payload.len) return false;
        idx += 1; // mutable
        if (version >= 3) _ = try readIntAt(payload, &idx, u64); // captured_bytes
    }

    return idx == payload.len;
}

fn readIntAt(payload: []const u8, idx: *usize, comptime T: type) !T {
    const size = @sizeOf(T);
    if (idx.* + size > payload.len) return error.TruncatedObject;
    const value = std.mem.readInt(T, @as(*const [size]u8, @ptrCast(payload[idx.* .. idx.* + size].ptr)), .little);
    idx.* += size;
    return value;
}

fn readByteAt(payload: []const u8, idx: *usize) !u8 {
    if (idx.* >= payload.len) return error.TruncatedObject;
    const byte = payload[idx.*];
    idx.* += 1;
    return byte;
}

fn readHashAt(payload: []const u8, idx: *usize) ![32]u8 {
    if (idx.* + 32 > payload.len) return error.TruncatedObject;
    var out: [32]u8 = undefined;
    @memcpy(out[0..], payload[idx.* .. idx.* + 32]);
    idx.* += 32;
    return out;
}

fn readStringAt(payload: []const u8, idx: *usize) ![]const u8 {
    const len = try readIntAt(payload, idx, u32);
    if (idx.* + len > payload.len) return error.TruncatedObject;
    const start = idx.*;
    idx.* += len;
    return payload[start..idx.*];
}

const BundleRef = struct {
    name: []u8,
    id: object_store.ObjectId,

    fn deinit(self: *BundleRef, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

const BundleManifest = struct {
    format_version: u16,
    incremental: bool,
    refs: []BundleRef,
    prerequisites: []object_store.ObjectId,
    object_count: usize,

    fn deinit(self: *BundleManifest, alloc: std.mem.Allocator) void {
        for (self.refs) |*entry| entry.deinit(alloc);
        alloc.free(self.refs);
        alloc.free(self.prerequisites);
    }
};

pub const BundleResult = struct {
    ref_count: usize,
    prerequisite_count: usize,
    object_count: usize,
};

const bundle_manifest_name = "bundle.manifest";
const bundle_manifest_magic = "SYDBUNDLE1";

fn cloneBundleRefs(alloc: std.mem.Allocator, refs: []const RefEntry) ![]BundleRef {
    const cloned = try alloc.alloc(BundleRef, refs.len);
    errdefer {
        for (cloned[0..]) |*entry| {
            if (entry.name.len != 0) entry.deinit(alloc);
        }
        alloc.free(cloned);
    }

    for (cloned) |*entry| entry.* = .{ .name = &[_]u8{}, .id = undefined };
    for (refs, 0..) |ref, idx| {
        cloned[idx] = .{
            .name = try alloc.dupe(u8, ref.name),
            .id = ref.id,
        };
    }
    return cloned;
}

fn writeBundleManifest(alloc: std.mem.Allocator, dst_path: []const u8, manifest: BundleManifest) !void {
    _ = alloc;
    var root = try std.fs.cwd().openDir(dst_path, .{ .iterate = true });
    defer root.close();

    const temp_name = bundle_manifest_name ++ ".tmp";
    var file = try root.createFile(temp_name, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_name) catch {};

    var write_buf: [4096]u8 = undefined;
    var writer_state = file.writer(&write_buf);
    const writer = &writer_state.interface;

    try writer.print("{s}\n", .{bundle_manifest_magic});
    try writer.print("format_version {d}\n", .{manifest.format_version});
    try writer.print("incremental {d}\n", .{@intFromBool(manifest.incremental)});
    try writer.print("object_count {d}\n", .{manifest.object_count});
    try writer.print("prerequisites {d}\n", .{manifest.prerequisites.len});
    for (manifest.prerequisites) |prerequisite| {
        const hex = prerequisite.toHex();
        try writer.print("{s}\n", .{hex});
    }
    try writer.print("refs {d}\n", .{manifest.refs.len});
    for (manifest.refs) |entry| {
        const hex = entry.id.toHex();
        try writer.print("{s} {s}\n", .{ entry.name, hex });
    }
    try writer_state.end();
    try file.sync();
    try root.rename(temp_name, bundle_manifest_name);
}

fn readBundleManifest(alloc: std.mem.Allocator, bundle_path: []const u8) !BundleManifest {
    var root = try std.fs.cwd().openDir(bundle_path, .{ .iterate = true });
    defer root.close();

    const body = try root.readFileAlloc(alloc, bundle_manifest_name, 1024 * 1024);
    defer alloc.free(body);

    var line_it = std.mem.tokenizeAny(u8, body, "\r\n");
    const magic = line_it.next() orelse return error.InvalidBundle;
    if (!std.mem.eql(u8, magic, bundle_manifest_magic)) return error.InvalidBundle;

    const format_version = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "format_version");
    if (format_version != 1) return error.UnsupportedBundleFormatVersion;
    const incremental_value = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "incremental");
    const object_count = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "object_count");
    const prerequisite_count = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "prerequisites");

    const prerequisites = try alloc.alloc(object_store.ObjectId, prerequisite_count);
    errdefer alloc.free(prerequisites);
    for (prerequisites) |*entry| {
        const line = line_it.next() orelse return error.InvalidBundle;
        entry.* = try object_store.ObjectId.fromHex(line);
    }

    const ref_count = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "refs");
    const refs = try alloc.alloc(BundleRef, ref_count);
    errdefer {
        for (refs[0..]) |*entry| {
            if (entry.name.len != 0) entry.deinit(alloc);
        }
        alloc.free(refs);
    }
    for (refs) |*entry| entry.* = .{ .name = &[_]u8{}, .id = undefined };
    for (refs) |*entry| {
        const line = line_it.next() orelse return error.InvalidBundle;
        const sep = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidBundle;
        entry.* = .{
            .name = try alloc.dupe(u8, line[0..sep]),
            .id = try object_store.ObjectId.fromHex(line[sep + 1 ..]),
        };
    }

    return .{
        .format_version = @intCast(format_version),
        .incremental = incremental_value != 0,
        .refs = refs,
        .prerequisites = prerequisites,
        .object_count = object_count,
    };
}

fn parseBundleCountLine(line: []const u8, key: []const u8) !usize {
    if (line.len <= key.len or !std.mem.eql(u8, line[0..key.len], key) or line[key.len] != ' ') {
        return error.InvalidBundle;
    }
    return try std.fmt.parseInt(usize, line[key.len + 1 ..], 10);
}

pub fn createBundle(alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, fsync: cfg.FsyncPolicy, since_spec: ?[]const u8) !BundleResult {
    var source = try CasManager.init(alloc, src_path, fsync);
    defer source.deinit();

    try std.fs.cwd().makePath(dst_path);
    var dst_root = try std.fs.cwd().openDir(dst_path, .{ .iterate = true });
    defer dst_root.close();
    var dst_it = dst_root.iterate();
    if (try dst_it.next() != null) return error.BundleDestinationNotEmpty;

    const refs = try source.refs.listRefs(alloc);
    defer {
        for (refs) |*entry| entry.deinit(alloc);
        alloc.free(refs);
    }
    var reachable = try source.collectReachable(refs);
    defer reachable.deinit();

    var prerequisite_ids = std.array_list.Managed(object_store.ObjectId).init(alloc);
    defer prerequisite_ids.deinit();
    var base_reachable: ?std.AutoHashMap(object_store.ObjectId, void) = null;
    defer if (base_reachable) |*map| map.deinit();
    if (since_spec) |spec| {
        const base_id = try source.resolveCommitSpec(spec);
        try prerequisite_ids.append(base_id);
        base_reachable = try source.collectReachableFromIds(&[_]object_store.ObjectId{base_id});
    }

    var bundle_store = try object_store.ObjectStore.init(alloc, dst_path, .none);
    defer bundle_store.deinit();

    var selected = std.array_list.Managed(object_store.ObjectId).init(alloc);
    defer selected.deinit();
    var it = reachable.keyIterator();
    while (it.next()) |id_ptr| {
        if (base_reachable) |*base| {
            if (base.contains(id_ptr.*)) continue;
        }
        const loaded = try source.store.get(alloc, id_ptr.*);
        defer alloc.free(loaded.payload);
        const stored_id = try bundle_store.put(loaded.obj_type, loaded.payload);
        try selected.append(stored_id);
    }

    var pack_write = try bundle_store.writePack(alloc, selected.items);
    defer pack_write.deinit(alloc);

    const manifest = BundleManifest{
        .format_version = 1,
        .incremental = since_spec != null,
        .refs = try cloneBundleRefs(alloc, refs),
        .prerequisites = try alloc.dupe(object_store.ObjectId, prerequisite_ids.items),
        .object_count = selected.items.len,
    };
    defer {
        var owned = manifest;
        owned.deinit(alloc);
    }
    try writeBundleManifest(alloc, dst_path, manifest);
    return .{
        .ref_count = refs.len,
        .prerequisite_count = prerequisite_ids.items.len,
        .object_count = selected.items.len,
    };
}

pub fn verifyBundle(alloc: std.mem.Allocator, bundle_path: []const u8) !BundleResult {
    var manifest = try readBundleManifest(alloc, bundle_path);
    defer manifest.deinit(alloc);

    var root = try std.fs.cwd().openDir(bundle_path, .{ .iterate = true });
    defer root.close();
    var store = object_store.ObjectStore{ .allocator = alloc, .root = root, .fsync = .none };

    const ids = try store.listIds(alloc);
    defer alloc.free(ids);
    if (ids.len != manifest.object_count) return error.InvalidBundle;

    for (ids) |id| {
        const loaded = try store.get(alloc, id);
        alloc.free(loaded.payload);
    }

    for (manifest.refs) |entry| {
        if (!containsObjectId(ids, entry.id) and !containsObjectId(manifest.prerequisites, entry.id)) {
            return error.BundleMissingRefObject;
        }
    }

    return .{
        .ref_count = manifest.refs.len,
        .prerequisite_count = manifest.prerequisites.len,
        .object_count = ids.len,
    };
}

pub fn applyBundle(alloc: std.mem.Allocator, bundle_path: []const u8, dst_path: []const u8, fsync: cfg.FsyncPolicy) !BundleResult {
    var manifest = try readBundleManifest(alloc, bundle_path);
    defer manifest.deinit(alloc);

    const verify = try verifyBundle(alloc, bundle_path);
    _ = verify;

    var bundle_root = try std.fs.cwd().openDir(bundle_path, .{ .iterate = true });
    defer bundle_root.close();
    var bundle_store = object_store.ObjectStore{ .allocator = alloc, .root = bundle_root, .fsync = .none };

    var dest = try CasManager.init(alloc, dst_path, fsync);
    defer dest.deinit();

    for (manifest.prerequisites) |prereq| {
        const loaded = dest.store.get(alloc, prereq) catch return error.BundlePrerequisiteMissing;
        alloc.free(loaded.payload);
    }

    const ids = try bundle_store.listIds(alloc);
    defer alloc.free(ids);
    for (ids) |id| {
        const loaded = try bundle_store.get(alloc, id);
        defer alloc.free(loaded.payload);
        _ = try dest.store.put(loaded.obj_type, loaded.payload);
    }

    var updates = try alloc.alloc(RefTxnUpdate, manifest.refs.len);
    defer alloc.free(updates);
    for (manifest.refs, 0..) |entry, idx| {
        updates[idx] = .{
            .ref_name = entry.name,
            .new_id = entry.id,
        };
    }
    if (updates.len > 0) {
        try dest.refs.updateRefTxn(updates, "bundle-apply");
    }
    try dest.refreshCommitGraph();

    return .{
        .ref_count = manifest.refs.len,
        .prerequisite_count = manifest.prerequisites.len,
        .object_count = ids.len,
    };
}

const MirrorGcResult = struct {
    stale_segment_files: usize,
    stale_segment_bytes: u64,
    stale_wal_files: usize,
    stale_wal_bytes: u64,
    deleted: usize,
};

fn cleanupStaleMirrors(alloc: std.mem.Allocator, data_dir: std.fs.Dir, snapshot: Snapshot, dry_run: bool) !MirrorGcResult {
    var expected_segments = std.StringHashMap(void).init(alloc);
    defer expected_segments.deinit();
    for (snapshot.segment_descriptors) |descriptor| {
        const mirror_path = descriptor.mirrorPath();
        if (mirror_path.len == 0) continue;
        try expected_segments.put(mirror_path, {});
    }

    var stale_segment_files: usize = 0;
    var stale_segment_bytes: u64 = 0;
    var deleted: usize = 0;

    const segment_paths = try listFilesRecursive(alloc, data_dir, "segments");
    defer freeOwnedStrings(alloc, segment_paths);
    for (segment_paths) |path| {
        if (expected_segments.contains(path)) continue;
        const stat = try data_dir.statFile(path);
        stale_segment_files += 1;
        stale_segment_bytes += stat.size;
        if (!dry_run) {
            data_dir.deleteFile(path) catch {};
            deleted += 1;
        }
    }

    var stale_wal_files: usize = 0;
    var stale_wal_bytes: u64 = 0;
    const wal_paths = try listFilesRecursive(alloc, data_dir, "wal");
    defer freeOwnedStrings(alloc, wal_paths);
    for (wal_paths) |path| {
        if (std.mem.eql(u8, path, "wal/current.wal") or walPathReferenced(snapshot.wal_index.entries, path)) continue;
        const stat = try data_dir.statFile(path);
        stale_wal_files += 1;
        stale_wal_bytes += stat.size;
        if (!dry_run) {
            data_dir.deleteFile(path) catch {};
            deleted += 1;
        }
    }

    return .{
        .stale_segment_files = stale_segment_files,
        .stale_segment_bytes = stale_segment_bytes,
        .stale_wal_files = stale_wal_files,
        .stale_wal_bytes = stale_wal_bytes,
        .deleted = deleted,
    };
}

const CruftDirInfo = struct {
    path: []u8,
    bytes: u64,
    file_count: usize,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};

const CruftScan = struct {
    entries: []CruftDirInfo,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
    }
};

fn walPathReferenced(entries: []const WalChunkDescriptor, path: []const u8) bool {
    for (entries) |entry| {
        var buf: [256]u8 = undefined;
        const candidate = std.fmt.bufPrint(&buf, "wal/{s}", .{entry.mirrorName()}) catch continue;
        if (std.mem.eql(u8, candidate, path)) return true;
    }
    return false;
}

fn listFilesRecursive(alloc: std.mem.Allocator, dir: std.fs.Dir, root_path: []const u8) ![][]u8 {
    var subdir = dir.openDir(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc([]u8, 0),
        else => return err,
    };
    defer subdir.close();

    var files = std.array_list.Managed([]u8).init(alloc);
    errdefer {
        for (files.items) |item| alloc.free(item);
        files.deinit();
    }
    try appendFilesRecursive(alloc, &files, subdir, root_path);
    return try files.toOwnedSlice();
}

fn appendFilesRecursive(alloc: std.mem.Allocator, files: *std.array_list.Managed([]u8), dir: std.fs.Dir, prefix: []const u8) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });
        defer alloc.free(path);
        switch (entry.kind) {
            .file => try files.append(try alloc.dupe(u8, path)),
            .directory => {
                var child = try dir.openDir(entry.name, .{ .iterate = true });
                defer child.close();
                try appendFilesRecursive(alloc, files, child, path);
            },
            else => {},
        }
    }
}

fn freeOwnedStrings(alloc: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn objectSize(alloc: std.mem.Allocator, store: *object_store.ObjectStore, id: object_store.ObjectId) !u64 {
    var objects_dir = try store.root.openDir("objects", .{ .iterate = true });
    defer objects_dir.close();

    const bucket_name = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
    var bucket_dir = objects_dir.openDir(bucket_name[0..], .{}) catch |err| switch (err) {
        error.FileNotFound => return packedObjectSize(alloc, store, id),
        else => return err,
    };
    defer bucket_dir.close();

    const object_name = id.toHex();
    const stat = bucket_dir.statFile(object_name[0..]) catch |err| switch (err) {
        error.FileNotFound => return packedObjectSize(alloc, store, id),
        else => return err,
    };
    return stat.size;
}

fn packedObjectSize(alloc: std.mem.Allocator, store: *object_store.ObjectStore, id: object_store.ObjectId) !u64 {
    const loaded = try store.get(alloc, id);
    defer alloc.free(loaded.payload);
    return 32 + 1 + @sizeOf(u64) + @as(u64, @intCast(loaded.payload.len));
}

fn containsRef(refs: []const RefEntry, needle: []const u8) bool {
    for (refs) |entry| {
        if (std.mem.eql(u8, entry.name, needle)) return true;
    }
    return false;
}

fn validateReflogFile(alloc: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !void {
    const body = try dir.readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(body);

    var line_it = std.mem.tokenizeScalar(u8, body, '\n');
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        _ = try parseReflogLine(line);
    }
}

fn parseReflogLine(line: []const u8) !struct {
    old_id: ?object_store.ObjectId,
    new_id: object_store.ObjectId,
} {
    var field_it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = field_it.next() orelse return error.InvalidReflog;
    const old_hex = field_it.next() orelse return error.InvalidReflog;
    const new_hex = field_it.next() orelse return error.InvalidReflog;
    const old_id = if (isZeroHex(old_hex)) null else try object_store.ObjectId.fromHex(old_hex);
    return .{
        .old_id = old_id,
        .new_id = try object_store.ObjectId.fromHex(new_hex),
    };
}

fn isZeroHex(hex: []const u8) bool {
    if (hex.len != 64) return false;
    for (hex) |ch| {
        if (ch != '0') return false;
    }
    return true;
}

fn collectReflogObjectIds(alloc: std.mem.Allocator, root: std.fs.Dir) ![]object_store.ObjectId {
    const reflog_files = try listFilesRecursive(alloc, root, "logs/refs");
    defer freeOwnedStrings(alloc, reflog_files);

    var ids = std.array_list.Managed(object_store.ObjectId).init(alloc);
    defer ids.deinit();
    var seen = std.AutoHashMap(object_store.ObjectId, void).init(alloc);
    defer seen.deinit();

    for (reflog_files) |path| {
        const body = try root.readFileAlloc(alloc, path, 1024 * 1024);
        defer alloc.free(body);
        var line_it = std.mem.tokenizeScalar(u8, body, '\n');
        while (line_it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            const parsed = try parseReflogLine(line);
            if (parsed.old_id) |old_id| {
                if (!seen.contains(old_id)) {
                    try seen.put(old_id, {});
                    try ids.append(old_id);
                }
            }
            if (!seen.contains(parsed.new_id)) {
                try seen.put(parsed.new_id, {});
                try ids.append(parsed.new_id);
            }
        }
    }
    return try ids.toOwnedSlice();
}

fn countProtectedObjects(reachable: *const std.AutoHashMap(object_store.ObjectId, void), direct: *const std.AutoHashMap(object_store.ObjectId, void)) usize {
    var protected: usize = 0;
    var it = reachable.keyIterator();
    while (it.next()) |id_ptr| {
        if (!direct.contains(id_ptr.*)) protected += 1;
    }
    return protected;
}

fn quarantinePackFiles(alloc: std.mem.Allocator, root: std.fs.Dir, pack_paths: [][]u8, stamp_ms: i64) !void {
    const dst_dir = try std.fmt.allocPrint(alloc, "objects/cruft/{d}/packs", .{stamp_ms});
    defer alloc.free(dst_dir);
    try root.makePath(dst_dir);

    for (pack_paths) |path| {
        const base = std.fs.path.basename(path);
        const dst_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dst_dir, base });
        defer alloc.free(dst_path);
        root.copyFile(path, root, dst_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

fn deleteActivePackFiles(root: std.fs.Dir, pack_paths: [][]u8) !void {
    for (pack_paths) |path| {
        root.deleteFile(path) catch {};
    }
}

fn moveLooseObjectToCruft(alloc: std.mem.Allocator, root: std.fs.Dir, id: object_store.ObjectId, stamp_ms: i64) !bool {
    const hex = id.toHex();
    const src_path = try std.fmt.allocPrint(alloc, "objects/{s}/{s}", .{ hex[0..2], hex[0..] });
    defer alloc.free(src_path);

    const dst_dir = try std.fmt.allocPrint(alloc, "objects/cruft/{d}/loose", .{stamp_ms});
    defer alloc.free(dst_dir);
    try root.makePath(dst_dir);

    const dst_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dst_dir, hex[0..] });
    defer alloc.free(dst_path);

    root.rename(src_path, dst_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.PathAlreadyExists => return false,
        else => return err,
    };
    return true;
}

fn scanExpiredCruft(alloc: std.mem.Allocator, root: std.fs.Dir, now_ms: i64, grace_period_ms: i64) !CruftScan {
    var cruft_dir = root.openDir("objects/cruft", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .entries = try alloc.alloc(CruftDirInfo, 0) },
        else => return err,
    };
    defer cruft_dir.close();

    const cutoff = now_ms - grace_period_ms;
    var entries = std.array_list.Managed(CruftDirInfo).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    var it = cruft_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const stamp_ms = std.fmt.parseInt(i64, entry.name, 10) catch continue;
        if (stamp_ms >= cutoff) continue;

        const rel_path = try std.fmt.allocPrint(alloc, "objects/cruft/{s}", .{entry.name});
        errdefer alloc.free(rel_path);
        const stats = try countFilesAndBytesRecursive(alloc, root, rel_path);
        try entries.append(.{
            .path = rel_path,
            .bytes = stats.bytes,
            .file_count = stats.file_count,
        });
    }

    return .{ .entries = try entries.toOwnedSlice() };
}

fn countFilesAndBytesRecursive(alloc: std.mem.Allocator, dir: std.fs.Dir, root_path: []const u8) !struct {
    file_count: usize,
    bytes: u64,
} {
    const files = try listFilesRecursive(alloc, dir, root_path);
    defer freeOwnedStrings(alloc, files);

    var file_count: usize = 0;
    var bytes: u64 = 0;
    for (files) |path| {
        const stat = try dir.statFile(path);
        file_count += 1;
        bytes += stat.size;
    }
    return .{ .file_count = file_count, .bytes = bytes };
}

fn writeLostFoundEntries(alloc: std.mem.Allocator, root: std.fs.Dir, store: *object_store.ObjectStore, ids: []const object_store.ObjectId) !usize {
    try root.makePath("lost-found/commit");
    try root.makePath("lost-found/blob");
    try root.makePath("lost-found/tree");

    var written: usize = 0;
    for (ids) |id| {
        const loaded = try store.get(alloc, id);
        defer alloc.free(loaded.payload);
        const kind = switch (loaded.obj_type) {
            .commit => "commit",
            .blob => "blob",
            .tree => "tree",
            else => continue,
        };
        const hex = id.toHex();
        const path = try std.fmt.allocPrint(alloc, "lost-found/{s}/{s}", .{ kind, hex[0..] });
        defer alloc.free(path);
        root.writeFile(.{
            .sub_path = path,
            .data = hex[0..],
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        written += 1;
    }
    return written;
}

const CommitGraphBuildEntry = struct {
    id: object_store.ObjectId,
    root: object_store.ObjectId,
    parents: []object_store.ObjectId,
    created_at_ms: i64,
    reason: []u8,

    fn deinit(self: *CommitGraphBuildEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.parents);
        alloc.free(self.reason);
    }
};

fn buildCommitGraph(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    refs: []const RefEntry,
) !CommitGraph {
    var entries = std.array_list.Managed(CommitGraphBuildEntry).init(alloc);
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    var seen = std.AutoHashMap(object_store.ObjectId, void).init(alloc);
    defer seen.deinit();

    var stack = std.array_list.Managed(object_store.ObjectId).init(alloc);
    defer stack.deinit();
    for (refs) |entry| try stack.append(entry.id);

    while (stack.pop()) |commit_id| {
        if (seen.contains(commit_id)) continue;
        try seen.put(commit_id, {});

        const loaded = try store.get(alloc, commit_id);
        defer alloc.free(loaded.payload);
        if (loaded.obj_type != .commit) return error.InvalidCommitObject;

        const commit = try decodeCommit(alloc, loaded.payload);
        try entries.append(.{
            .id = commit_id,
            .root = commit.root,
            .parents = commit.parents,
            .created_at_ms = commit.created_at_ms,
            .reason = commit.reason,
        });

        for (entries.items[entries.items.len - 1].parents) |parent| {
            try stack.append(parent);
        }
    }

    std.sort.block(CommitGraphBuildEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: CommitGraphBuildEntry, rhs: CommitGraphBuildEntry) bool {
            return std.mem.lessThan(u8, lhs.id.hash[0..], rhs.id.hash[0..]);
        }
    }.lessThan);

    const object_ids = try alloc.alloc(object_store.ObjectId, entries.items.len);
    errdefer alloc.free(object_ids);
    const roots = try alloc.alloc(object_store.ObjectId, entries.items.len);
    errdefer alloc.free(roots);
    const created_at_ms = try alloc.alloc(i64, entries.items.len);
    errdefer alloc.free(created_at_ms);
    const generations = try alloc.alloc(u32, entries.items.len);
    errdefer alloc.free(generations);
    @memset(generations, 0);
    const parent_offsets = try alloc.alloc(u64, entries.items.len + 1);
    errdefer alloc.free(parent_offsets);
    const reason_offsets = try alloc.alloc(u64, entries.items.len + 1);
    errdefer alloc.free(reason_offsets);

    var positions = std.AutoHashMap(object_store.ObjectId, usize).init(alloc);
    defer positions.deinit();
    for (entries.items, 0..) |entry, idx| try positions.put(entry.id, idx);

    var parent_positions = std.array_list.Managed(u64).init(alloc);
    defer parent_positions.deinit();
    var reasons = std.array_list.Managed(u8).init(alloc);
    defer reasons.deinit();

    parent_offsets[0] = 0;
    reason_offsets[0] = 0;
    for (entries.items, 0..) |entry, idx| {
        object_ids[idx] = entry.id;
        roots[idx] = entry.root;
        created_at_ms[idx] = entry.created_at_ms;
        for (entry.parents) |parent| {
            const parent_idx = positions.get(parent) orelse return error.CorruptCommitGraph;
            try parent_positions.append(@intCast(parent_idx));
        }
        parent_offsets[idx + 1] = @intCast(parent_positions.items.len);
        try reasons.appendSlice(entry.reason);
        reason_offsets[idx + 1] = @intCast(reasons.items.len);
    }

    var idx: usize = 0;
    while (idx < entries.items.len) : (idx += 1) {
        generations[idx] = try computeCommitGeneration(idx, parent_offsets, parent_positions.items, generations);
    }

    return .{
        .object_ids = object_ids,
        .roots = roots,
        .created_at_ms = created_at_ms,
        .generations = generations,
        .parent_offsets = parent_offsets,
        .parent_positions = try parent_positions.toOwnedSlice(),
        .reason_offsets = reason_offsets,
        .reasons = try reasons.toOwnedSlice(),
    };
}

fn computeCommitGeneration(
    idx: usize,
    parent_offsets: []const u64,
    parent_positions: []const u64,
    generations: []u32,
) !u32 {
    if (generations[idx] != 0) return generations[idx];
    const start: usize = @intCast(parent_offsets[idx]);
    const end: usize = @intCast(parent_offsets[idx + 1]);
    if (start == end) {
        generations[idx] = 1;
        return 1;
    }

    var max_parent: u32 = 0;
    for (parent_positions[start..end]) |parent_idx_u64| {
        const parent_idx: usize = @intCast(parent_idx_u64);
        const parent_generation = try computeCommitGeneration(parent_idx, parent_offsets, parent_positions, generations);
        if (parent_generation > max_parent) max_parent = parent_generation;
    }
    generations[idx] = max_parent + 1;
    return generations[idx];
}

fn writeCommitGraph(alloc: std.mem.Allocator, root: std.fs.Dir, graph: CommitGraph, fsync: cfg.FsyncPolicy) !void {
    var bytes = std.array_list.Managed(u8).init(alloc);
    defer bytes.deinit();

    try bytes.appendSlice(commit_graph_magic[0..]);
    try appendInt(&bytes, u16, 1);
    try appendInt(&bytes, u64, @intCast(graph.object_ids.len));
    for (graph.object_ids) |id| try bytes.appendSlice(id.hash[0..]);
    for (graph.roots) |root_id| try bytes.appendSlice(root_id.hash[0..]);
    for (graph.created_at_ms) |created| try appendInt(&bytes, i64, created);
    for (graph.generations) |generation| try appendInt(&bytes, u32, generation);
    for (graph.parent_offsets) |offset| try appendInt(&bytes, u64, offset);
    for (graph.parent_positions) |position| try appendInt(&bytes, u64, position);
    for (graph.reason_offsets) |offset| try appendInt(&bytes, u64, offset);
    try bytes.appendSlice(graph.reasons);

    const temp_path = "objects/info/commit-graph.tmp";
    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};
    try file.writeAll(bytes.items);
    if (fsync != .none) {
        try file.sync();
    }
    root.rename(temp_path, commit_graph_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(commit_graph_path) catch {};
            try root.rename(temp_path, commit_graph_path);
        },
        else => return err,
    };
}

fn loadCommitGraph(alloc: std.mem.Allocator, root: std.fs.Dir) !CommitGraph {
    const bytes = try root.readFileAlloc(alloc, commit_graph_path, 256 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < commit_graph_magic.len + @sizeOf(u16) + @sizeOf(u64)) return error.CorruptCommitGraph;
    if (!std.mem.eql(u8, bytes[0..commit_graph_magic.len], commit_graph_magic[0..])) return error.CorruptCommitGraph;

    var cursor = Cursor{ .bytes = bytes, .index = commit_graph_magic.len };
    const version = try cursor.readInt(u16);
    if (version != 1) return error.UnsupportedCommitGraphVersion;
    const commit_count = try cursor.readInt(u64);

    const object_ids = try alloc.alloc(object_store.ObjectId, @intCast(commit_count));
    errdefer alloc.free(object_ids);
    for (object_ids) |*id| id.* = .{ .hash = try cursor.readHash() };

    const roots = try alloc.alloc(object_store.ObjectId, @intCast(commit_count));
    errdefer alloc.free(roots);
    for (roots) |*root_id| root_id.* = .{ .hash = try cursor.readHash() };

    const created_at_ms = try alloc.alloc(i64, @intCast(commit_count));
    errdefer alloc.free(created_at_ms);
    for (created_at_ms) |*created| created.* = try cursor.readInt(i64);

    const generations = try alloc.alloc(u32, @intCast(commit_count));
    errdefer alloc.free(generations);
    for (generations) |*generation| generation.* = try cursor.readInt(u32);

    const parent_offsets = try alloc.alloc(u64, @intCast(commit_count + 1));
    errdefer alloc.free(parent_offsets);
    for (parent_offsets) |*offset| offset.* = try cursor.readInt(u64);

    const parent_count = parent_offsets[parent_offsets.len - 1];
    const parent_positions = try alloc.alloc(u64, @intCast(parent_count));
    errdefer alloc.free(parent_positions);
    for (parent_positions) |*position| position.* = try cursor.readInt(u64);

    const reason_offsets = try alloc.alloc(u64, @intCast(commit_count + 1));
    errdefer alloc.free(reason_offsets);
    for (reason_offsets) |*offset| offset.* = try cursor.readInt(u64);

    const reasons_len = reason_offsets[reason_offsets.len - 1];
    const reasons = try alloc.alloc(u8, @intCast(reasons_len));
    errdefer alloc.free(reasons);
    @memcpy(reasons, cursor.bytes[cursor.index .. cursor.index + reasons.len]);
    cursor.index += reasons.len;
    try cursor.finish();

    return .{
        .object_ids = object_ids,
        .roots = roots,
        .created_at_ms = created_at_ms,
        .generations = generations,
        .parent_offsets = parent_offsets,
        .parent_positions = parent_positions,
        .reason_offsets = reason_offsets,
        .reasons = reasons,
    };
}

fn loadOrInitRepositoryFormat(alloc: std.mem.Allocator, root: std.fs.Dir, fsync: cfg.FsyncPolicy) !RepositoryFormat {
    return loadRepositoryFormat(root) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const format = RepositoryFormat{};
            try writeRepositoryFormat(alloc, root, format, fsync);
            break :blk format;
        },
        else => return err,
    };
}

fn loadRepositoryFormat(root: std.fs.Dir) !RepositoryFormat {
    const bytes = try root.readFileAlloc(std.heap.page_allocator, store_format_path, 1024);
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len < store_format_magic.len + @sizeOf(u16) + 1 + @sizeOf(u32)) return error.CorruptStoreFormat;
    if (!std.mem.eql(u8, bytes[0..store_format_magic.len], store_format_magic)) return error.CorruptStoreFormat;
    var cursor = Cursor{ .bytes = bytes, .index = store_format_magic.len };
    const version = try cursor.readInt(u16);
    const ref_backend = std.meta.intToEnum(RefBackend, try cursor.readByte()) catch return error.UnsupportedRefBackend;
    const extent_chunk_bytes = try cursor.readInt(u32);
    try cursor.finish();
    return .{
        .version = version,
        .ref_backend = ref_backend,
        .extent_chunk_bytes = extent_chunk_bytes,
    };
}

fn writeRepositoryFormat(alloc: std.mem.Allocator, root: std.fs.Dir, format: RepositoryFormat, fsync: cfg.FsyncPolicy) !void {
    var bytes = std.array_list.Managed(u8).init(alloc);
    defer bytes.deinit();
    try bytes.appendSlice(store_format_magic);
    try appendInt(&bytes, u16, format.version);
    try bytes.append(@intFromEnum(format.ref_backend));
    try appendInt(&bytes, u32, format.extent_chunk_bytes);

    const temp_path = store_format_path ++ ".tmp";
    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};
    try file.writeAll(bytes.items);
    if (fsync != .none) try file.sync();
    root.rename(temp_path, store_format_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(store_format_path) catch {};
            try root.rename(temp_path, store_format_path);
        },
        else => return err,
    };
    if (fsync != .none) {
        var mutable_root = root;
        try syncDir(&mutable_root);
    }
}

fn writePackedObject(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    temp_dir_name: []const u8,
    id: object_store.ObjectId,
    obj_type: object_store.ObjectType,
    payload: []const u8,
    fsync: cfg.FsyncPolicy,
) !void {
    const dir_name = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
    const bucket_path = try std.fmt.allocPrint(alloc, "{s}/objects/{s}", .{ temp_dir_name, dir_name[0..] });
    defer alloc.free(bucket_path);
    try root.makePath(bucket_path);

    const object_hex = id.toHex();
    const object_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ bucket_path, object_hex[0..] });
    defer alloc.free(object_path);

    var file = try root.createFile(object_path, .{ .truncate = true, .read = true });
    defer file.close();

    var header = [_]u8{ @intFromEnum(obj_type), 0, 0, 0, 0 };
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    try file.writeAll(&header);
    try file.writeAll(payload);
    if (fsync != .none) {
        try file.sync();
    }
}

pub fn buildLegacySnapshot(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    manifest: *const manifest_mod.Manifest,
    tags: *const tags_mod.TagIndex,
    series_catalog: *const series_catalog_mod.SeriesCatalog,
    store: ?*object_store.ObjectStore,
    extent_chunk_bytes: u32,
) !LegacySnapshot {
    var descriptors = std.array_list.Managed(SegmentDescriptor).init(alloc);
    errdefer {
        for (descriptors.items) |*descriptor| descriptor.deinit(alloc);
        descriptors.deinit();
    }

    for (manifest.entries.items) |entry| {
        var metadata = try segment_mod.inspectMetadata(alloc, data_dir, entry.path);
        defer metadata.deinit(alloc);
        if (metadata.series_id != entry.series_id or metadata.hour_bucket != entry.hour_bucket or metadata.start_ts != entry.start_ts or metadata.end_ts != entry.end_ts or metadata.count != entry.count) {
            return error.ManifestSegmentMismatch;
        }
        const content = try ensureContentRefForFile(alloc, store, data_dir, entry.path, extent_chunk_bytes);
        try descriptors.append(.{
            .path = try alloc.dupe(u8, entry.path),
            .mirror_path = &[_]u8{},
            .content_id = if (content) |ref| switch (ref) {
                .blob => |id| id,
                .extent_tree => null,
            } else null,
            .content = content,
            .file_hash = try hashFile(data_dir, entry.path),
            .file_size = metadata.file_size,
            .series_id = entry.series_id,
            .hour_bucket = entry.hour_bucket,
            .start_ts = entry.start_ts,
            .end_ts = entry.end_ts,
            .count = entry.count,
            .ts_codec = metadata.ts_codec,
            .val_codec = metadata.val_codec,
        });
    }

    sortDescriptors(descriptors.items);

    return .{
        .segment_descriptors = try descriptors.toOwnedSlice(),
        .tag_snapshot = try buildTagSnapshot(alloc, tags),
        .series_catalog_snapshot = try buildSeriesCatalogSnapshot(alloc, series_catalog),
        .wal_index = try buildWalIndex(alloc, data_dir, store, extent_chunk_bytes),
    };
}

pub fn verifyLegacySnapshot(live: LegacySnapshot, stored: Snapshot) !void {
    if (live.segment_descriptors.len != stored.segment_descriptors.len) return error.CasVerificationFailed;
    for (live.segment_descriptors, stored.segment_descriptors) |lhs, rhs| {
        if (!lhs.eql(rhs)) return error.CasVerificationFailed;
    }

    if (live.tag_snapshot.entries.len != stored.tag_snapshot.entries.len) return error.CasVerificationFailed;
    for (live.tag_snapshot.entries, stored.tag_snapshot.entries) |lhs, rhs| {
        if (!lhs.eql(rhs)) return error.CasVerificationFailed;
    }

    if (live.series_catalog_snapshot.entries.len != stored.series_catalog_snapshot.entries.len) return error.CasVerificationFailed;
    for (live.series_catalog_snapshot.entries, stored.series_catalog_snapshot.entries) |lhs, rhs| {
        if (!lhs.eql(rhs)) return error.CasVerificationFailed;
    }
}

fn buildTagSnapshot(alloc: std.mem.Allocator, tags: *const tags_mod.TagIndex) !TagSnapshot {
    var entries = std.array_list.Managed(TagSnapshotEntry).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    var it = tags.map.iterator();
    while (it.next()) |entry| {
        const owned_key = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(owned_key);

        const ids = try alloc.alloc(types.SeriesId, entry.value_ptr.items.len);
        errdefer alloc.free(ids);
        @memcpy(ids, entry.value_ptr.items);
        std.sort.block(types.SeriesId, ids, {}, struct {
            fn lessThan(_: void, lhs: types.SeriesId, rhs: types.SeriesId) bool {
                return lhs < rhs;
            }
        }.lessThan);

        try entries.append(.{
            .key = owned_key,
            .series_ids = ids,
        });
    }

    std.sort.block(TagSnapshotEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: TagSnapshotEntry, rhs: TagSnapshotEntry) bool {
            return std.mem.lessThan(u8, lhs.key, rhs.key);
        }
    }.lessThan);

    return .{ .entries = try entries.toOwnedSlice() };
}

fn buildSeriesCatalogSnapshot(alloc: std.mem.Allocator, series_catalog: *const series_catalog_mod.SeriesCatalog) !SeriesCatalogSnapshot {
    var catalog = @constCast(series_catalog);
    catalog.mutex.lock();
    defer catalog.mutex.unlock();

    var entries = std.array_list.Managed(SeriesCatalogSnapshotEntry).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    for (catalog.entries.items) |entry| {
        try entries.append(.{
            .series = try alloc.dupe(u8, entry.series),
            .canonical_tags = try alloc.dupe(u8, entry.canonical_tags),
            .series_id = entry.series_id,
        });
    }

    sortSeriesCatalogEntries(entries.items);
    return .{ .entries = try entries.toOwnedSlice() };
}

fn buildWalIndex(alloc: std.mem.Allocator, data_dir: std.fs.Dir, store: ?*object_store.ObjectStore, extent_chunk_bytes: u32) !WalIndex {
    const infos = try wal_mod.collectWalFileInfos(alloc, data_dir);
    defer wal_mod.freeWalFileInfos(alloc, infos);

    var entries = std.array_list.Managed(WalChunkDescriptor).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    for (infos) |info| {
        const content = try ensureContentRefForWalFile(alloc, store, data_dir, info.name, extent_chunk_bytes);
        try entries.append(.{
            .name = try alloc.dupe(u8, info.name),
            .mirror_name = &[_]u8{},
            .content_id = if (content) |ref| switch (ref) {
                .blob => |id| id,
                .extent_tree => null,
            } else null,
            .content = content,
            .file_size = info.size,
            .file_hash = info.hash,
            .mutable = std.mem.eql(u8, info.name, "current.wal"),
            .captured_bytes = info.size,
        });
    }
    return .{ .entries = try entries.toOwnedSlice() };
}

fn verifyWalFiles(alloc: std.mem.Allocator, wal_index: WalIndex, data_dir: std.fs.Dir, store: *object_store.ObjectStore) !void {
    for (wal_index.entries) |entry| {
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "wal/{s}", .{entry.mirrorName()});
        defer std.heap.page_allocator.free(path);

        var file = data_dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.CasVerificationFailed,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (!entry.mutable and stat.size != entry.file_size) return error.CasVerificationFailed;
        if (entry.mutable and stat.size < entry.captured_bytes) return error.CasVerificationFailed;
        if (!entry.mutable or stat.size == entry.captured_bytes) {
            const live_hash = try hashFile(data_dir, path);
            if (!std.mem.eql(u8, live_hash[0..], entry.file_hash[0..])) return error.CasVerificationFailed;
        } else if (entry.contentRef()) |content| {
            switch (content) {
                .blob => |content_id| {
                    const loaded = try store.get(alloc, content_id);
                    defer alloc.free(loaded.payload);
                    if (loaded.obj_type != .blob) return error.InvalidWalChunkObject;
                    if (loaded.payload.len != entry.captured_bytes) return error.CasVerificationFailed;
                    if (!try wal_mod.filePrefixMatches(data_dir, path, loaded.payload)) return error.CasVerificationFailed;
                },
                .extent_tree => |tree| {
                    const bytes = try extents.readAll(alloc, store, tree);
                    defer alloc.free(bytes);
                    if (bytes.len != entry.captured_bytes) return error.CasVerificationFailed;
                    if (!try wal_mod.filePrefixMatches(data_dir, path, bytes)) return error.CasVerificationFailed;
                },
            }
        }
    }
}

fn buildParentSlice(alloc: std.mem.Allocator, parent: ?object_store.ObjectId) ![]object_store.ObjectId {
    if (parent) |id| {
        var parents = try alloc.alloc(object_store.ObjectId, 1);
        parents[0] = id;
        return parents;
    }
    return try alloc.alloc(object_store.ObjectId, 0);
}

fn hashFile(data_dir: std.fs.Dir, path: []const u8) ![32]u8 {
    var file = try data_dir.openFile(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.init(.{});
    while (true) {
        const bytes_read = try file.read(buf[0..]);
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
    }
    var out: [32]u8 = undefined;
    hasher.final(out[0..]);
    return out;
}

fn ensureContentRefForFile(
    alloc: std.mem.Allocator,
    store: ?*object_store.ObjectStore,
    data_dir: std.fs.Dir,
    path: []const u8,
    chunk_bytes: u32,
) !?ContentRef {
    const bytes = try data_dir.readFileAlloc(alloc, path, 128 * 1024 * 1024);
    defer alloc.free(bytes);
    if (store) |object_store_ref| {
        const written = try extents.writeAll(alloc, object_store_ref, bytes, chunk_bytes);
        return ContentRef{ .extent_tree = .{
            .root_id = written.root_id,
            .size_bytes = written.size_bytes,
            .chunk_bytes = written.chunk_bytes,
        } };
    }
    const blob_id = object_store.computeId(.blob, bytes);
    return ContentRef{ .blob = blob_id };
}

fn ensureContentRefForWalFile(
    alloc: std.mem.Allocator,
    store: ?*object_store.ObjectStore,
    data_dir: std.fs.Dir,
    wal_name: []const u8,
    chunk_bytes: u32,
) !?ContentRef {
    const path = try std.fmt.allocPrint(alloc, "wal/{s}", .{wal_name});
    defer alloc.free(path);
    return try ensureContentRefForFile(alloc, store, data_dir, path, chunk_bytes);
}

fn encodeSegmentDescriptor(alloc: std.mem.Allocator, descriptor: SegmentDescriptor) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    const content = descriptor.contentRef() orelse return error.MissingSegmentContentId;

    try bytes.append(4);
    try encodeContentRef(&bytes, content);
    try appendString(&bytes, descriptor.mirrorPath());
    try bytes.appendSlice(descriptor.file_hash[0..]);
    try appendInt(&bytes, u64, descriptor.file_size);
    try appendInt(&bytes, u64, descriptor.series_id);
    try appendInt(&bytes, i64, descriptor.hour_bucket);
    try appendInt(&bytes, i64, descriptor.start_ts);
    try appendInt(&bytes, i64, descriptor.end_ts);
    try appendInt(&bytes, u32, descriptor.count);
    try bytes.append(descriptor.ts_codec);
    try bytes.append(descriptor.val_codec);
    return try bytes.toOwnedSlice();
}

fn decodeSegmentDescriptor(alloc: std.mem.Allocator, payload: []const u8) !SegmentDescriptor {
    var cursor = Cursor{ .bytes = payload };
    const version = try cursor.readByte();
    if (version != 1 and version != 2 and version != 3 and version != 4) return error.UnsupportedSegmentDescriptorVersion;

    const content = if (version == 4)
        try decodeContentRef(&cursor)
    else if (version == 1)
        null
    else if (version == 2)
        if (try cursor.readOptionalObjectId()) |id| ContentRef{ .blob = id } else null
    else
        ContentRef{ .blob = .{ .hash = try cursor.readHash() } };
    const path = try cursor.readOwnedString(alloc);
    errdefer alloc.free(path);

    const file_hash = try cursor.readHash();
    const file_size = try cursor.readInt(u64);
    const series_id = try cursor.readInt(u64);
    const hour_bucket = try cursor.readInt(i64);
    const start_ts = try cursor.readInt(i64);
    const end_ts = try cursor.readInt(i64);
    const count = try cursor.readInt(u32);
    const ts_codec = try cursor.readByte();
    const val_codec = try cursor.readByte();
    try cursor.finish();

    return .{
        .path = path,
        .mirror_path = &[_]u8{},
        .content_id = if (content) |ref| switch (ref) {
            .blob => |id| id,
            .extent_tree => null,
        } else null,
        .content = content,
        .file_hash = file_hash,
        .file_size = file_size,
        .series_id = series_id,
        .hour_bucket = hour_bucket,
        .start_ts = start_ts,
        .end_ts = end_ts,
        .count = count,
        .ts_codec = ts_codec,
        .val_codec = val_codec,
    };
}

fn encodeTagSnapshot(alloc: std.mem.Allocator, snapshot: TagSnapshot) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(1);
    try appendInt(&bytes, u32, @intCast(snapshot.entries.len));
    for (snapshot.entries) |entry| {
        try appendString(&bytes, entry.key);
        try appendInt(&bytes, u32, @intCast(entry.series_ids.len));
        for (entry.series_ids) |series_id| {
            try appendInt(&bytes, u64, series_id);
        }
    }
    return try bytes.toOwnedSlice();
}

fn decodeTagSnapshot(alloc: std.mem.Allocator, payload: []const u8) !TagSnapshot {
    var cursor = Cursor{ .bytes = payload };
    const version = try cursor.readByte();
    if (version != 1) return error.UnsupportedTagSnapshotVersion;

    const entry_count = try cursor.readInt(u32);
    var entries = try alloc.alloc(TagSnapshotEntry, entry_count);
    errdefer {
        for (entries[0..@min(entries.len, cursor.objects_read)]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const key = try cursor.readOwnedString(alloc);
        errdefer alloc.free(key);

        const series_len = try cursor.readInt(u32);
        const series_ids = try alloc.alloc(types.SeriesId, series_len);
        errdefer alloc.free(series_ids);
        for (series_ids, 0..) |*series_id, idx| {
            _ = idx;
            series_id.* = try cursor.readInt(u64);
        }

        entries[i] = .{
            .key = key,
            .series_ids = series_ids,
        };
        cursor.objects_read += 1;
    }
    try cursor.finish();
    return .{ .entries = entries };
}

fn encodeSeriesCatalogSnapshot(alloc: std.mem.Allocator, snapshot: SeriesCatalogSnapshot) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(1);
    try appendInt(&bytes, u32, @intCast(snapshot.entries.len));
    for (snapshot.entries) |entry| {
        try appendString(&bytes, entry.series);
        try appendString(&bytes, entry.canonical_tags);
        try appendInt(&bytes, u64, entry.series_id);
    }
    return try bytes.toOwnedSlice();
}

fn decodeSeriesCatalogSnapshot(alloc: std.mem.Allocator, payload: []const u8) !SeriesCatalogSnapshot {
    var cursor = Cursor{ .bytes = payload };
    const version = try cursor.readByte();
    if (version != 1) return error.UnsupportedSeriesCatalogSnapshotVersion;

    const entry_count = try cursor.readInt(u32);
    var entries = try alloc.alloc(SeriesCatalogSnapshotEntry, entry_count);
    errdefer {
        for (entries[0..@min(entries.len, cursor.objects_read)]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const series = try cursor.readOwnedString(alloc);
        errdefer alloc.free(series);
        const canonical_tags = try cursor.readOwnedString(alloc);
        errdefer alloc.free(canonical_tags);
        const series_id = try cursor.readInt(u64);
        entries[i] = .{
            .series = series,
            .canonical_tags = canonical_tags,
            .series_id = series_id,
        };
        cursor.objects_read += 1;
    }
    try cursor.finish();
    return .{ .entries = entries };
}

fn encodeWalIndex(alloc: std.mem.Allocator, wal_index: WalIndex) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(4);
    try appendInt(&bytes, u32, @intCast(wal_index.entries.len));
    for (wal_index.entries) |entry| {
        const content = entry.contentRef() orelse return error.MissingWalContentId;
        try appendString(&bytes, entry.mirrorName());
        try encodeContentRef(&bytes, content);
        try appendInt(&bytes, u64, entry.file_size);
        try bytes.appendSlice(entry.file_hash[0..]);
        try bytes.append(if (entry.mutable) 1 else 0);
        try appendInt(&bytes, u64, entry.captured_bytes);
    }
    return try bytes.toOwnedSlice();
}

fn decodeWalIndex(alloc: std.mem.Allocator, payload: []const u8) !WalIndex {
    var cursor = Cursor{ .bytes = payload };
    const version = try cursor.readByte();
    if (version != 1 and version != 2 and version != 3 and version != 4) return error.UnsupportedWalIndexVersion;

    const entry_count = try cursor.readInt(u32);
    var entries = try alloc.alloc(WalChunkDescriptor, entry_count);
    errdefer {
        for (entries[0..@min(entries.len, cursor.objects_read)]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const name = try cursor.readOwnedString(alloc);
        errdefer alloc.free(name);
        const content = if (version == 4)
            try decodeContentRef(&cursor)
        else if (version == 1)
            null
        else if (version == 2)
            if (try cursor.readOptionalObjectId()) |id| ContentRef{ .blob = id } else null
        else
            ContentRef{ .blob = .{ .hash = try cursor.readHash() } };
        const file_size = try cursor.readInt(u64);
        const file_hash = try cursor.readHash();
        const mutable = (try cursor.readByte()) != 0;
        const captured_bytes = if (version >= 3) try cursor.readInt(u64) else file_size;
        entries[i] = .{
            .name = name,
            .mirror_name = &[_]u8{},
            .content_id = if (content) |ref| switch (ref) {
                .blob => |id| id,
                .extent_tree => null,
            } else null,
            .content = content,
            .file_size = file_size,
            .file_hash = file_hash,
            .mutable = mutable,
            .captured_bytes = captured_bytes,
        };
        cursor.objects_read += 1;
    }
    try cursor.finish();
    return .{ .entries = entries };
}

fn encodeTree(alloc: std.mem.Allocator, tree: Tree) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(1);
    try appendInt(&bytes, u32, @intCast(tree.entries.len));
    for (tree.entries) |entry| {
        try appendString(&bytes, entry.name);
        try bytes.append(@intFromEnum(entry.object_type));
        try bytes.appendSlice(entry.object_id.hash[0..]);
    }
    return try bytes.toOwnedSlice();
}

fn decodeTree(alloc: std.mem.Allocator, payload: []const u8) !Tree {
    var cursor = Cursor{ .bytes = payload };
    const version = try cursor.readByte();
    if (version != 1) return error.UnsupportedTreeVersion;

    const entry_count = try cursor.readInt(u32);
    var entries = try alloc.alloc(TreeEntry, entry_count);
    errdefer {
        for (entries[0..@min(entries.len, cursor.objects_read)]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const name = try cursor.readOwnedString(alloc);
        errdefer alloc.free(name);

        const object_type = std.meta.intToEnum(object_store.ObjectType, try cursor.readByte()) catch return error.UnknownTreeObjectType;
        const object_id = object_store.ObjectId{ .hash = try cursor.readHash() };
        entries[i] = .{
            .name = name,
            .object_type = object_type,
            .object_id = object_id,
        };
        cursor.objects_read += 1;
    }
    try cursor.finish();
    return .{ .entries = entries };
}

fn encodeCommit(alloc: std.mem.Allocator, commit: Commit) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(1);
    try appendInt(&bytes, u16, commit.format_version);
    try bytes.appendSlice(commit.root.hash[0..]);
    try appendInt(&bytes, u32, @intCast(commit.parents.len));
    for (commit.parents) |parent| {
        try bytes.appendSlice(parent.hash[0..]);
    }
    try appendInt(&bytes, i64, commit.created_at_ms);
    try appendString(&bytes, commit.reason);
    return try bytes.toOwnedSlice();
}

fn decodeCommit(alloc: std.mem.Allocator, payload: []const u8) !Commit {
    var cursor = Cursor{ .bytes = payload };
    const version = try cursor.readByte();
    if (version != 1) return error.UnsupportedCommitVersion;

    const format_version = try cursor.readInt(u16);
    if (format_version != current_format_version) return error.UnsupportedCommitFormatVersion;
    const root = object_store.ObjectId{ .hash = try cursor.readHash() };
    const parent_count = try cursor.readInt(u32);
    const parents = try alloc.alloc(object_store.ObjectId, parent_count);
    errdefer alloc.free(parents);
    for (parents, 0..) |*parent, idx| {
        _ = idx;
        parent.* = .{ .hash = try cursor.readHash() };
    }
    const created_at_ms = try cursor.readInt(i64);
    const reason = try cursor.readOwnedString(alloc);
    errdefer alloc.free(reason);
    try cursor.finish();
    return .{
        .format_version = format_version,
        .root = root,
        .parents = parents,
        .created_at_ms = created_at_ms,
        .reason = reason,
    };
}

fn appendString(bytes: *std.array_list.Managed(u8), value: []const u8) !void {
    try appendInt(bytes, u32, @intCast(value.len));
    try bytes.appendSlice(value);
}

fn encodeContentRef(bytes: *std.array_list.Managed(u8), content: ContentRef) !void {
    switch (content) {
        .blob => |id| {
            try bytes.append(1);
            try bytes.appendSlice(id.hash[0..]);
        },
        .extent_tree => |tree| {
            try bytes.append(2);
            try bytes.appendSlice(tree.root_id.hash[0..]);
            try appendInt(bytes, u64, tree.size_bytes);
            try appendInt(bytes, u32, tree.chunk_bytes);
        },
    }
}

fn appendOptionalObjectId(bytes: *std.array_list.Managed(u8), maybe_id: ?object_store.ObjectId) !void {
    try bytes.append(if (maybe_id != null) 1 else 0);
    if (maybe_id) |id| {
        try bytes.appendSlice(id.hash[0..]);
    }
}

fn appendInt(bytes: *std.array_list.Managed(u8), comptime T: type, value: T) !void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, tmp[0..], value, .little);
    try bytes.appendSlice(tmp[0..]);
}

const Cursor = struct {
    bytes: []const u8,
    index: usize = 0,
    objects_read: usize = 0,

    fn readByte(self: *Cursor) !u8 {
        if (self.index >= self.bytes.len) return error.TruncatedObject;
        const byte = self.bytes[self.index];
        self.index += 1;
        return byte;
    }

    fn readInt(self: *Cursor, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.index + size > self.bytes.len) return error.TruncatedObject;
        const window = self.bytes[self.index .. self.index + size];
        const value = std.mem.readInt(T, @ptrCast(window.ptr), .little);
        self.index += size;
        return value;
    }

    fn readHash(self: *Cursor) ![32]u8 {
        if (self.index + 32 > self.bytes.len) return error.TruncatedObject;
        var out: [32]u8 = undefined;
        @memcpy(out[0..], self.bytes[self.index .. self.index + 32]);
        self.index += 32;
        return out;
    }

    fn readOwnedString(self: *Cursor, alloc: std.mem.Allocator) ![]u8 {
        const len = try self.readInt(u32);
        if (self.index + len > self.bytes.len) return error.TruncatedObject;
        const out = try alloc.dupe(u8, self.bytes[self.index .. self.index + len]);
        self.index += len;
        return out;
    }

    fn readOptionalObjectId(self: *Cursor) !?object_store.ObjectId {
        return switch (try self.readByte()) {
            0 => null,
            1 => .{ .hash = try self.readHash() },
            else => error.InvalidOptionalObjectIdFlag,
        };
    }

    fn finish(self: *Cursor) !void {
        if (self.index != self.bytes.len) return error.ExtraObjectBytes;
    }
};

fn decodeContentRef(cursor: *Cursor) !?ContentRef {
    return switch (try cursor.readByte()) {
        0 => null,
        1 => ContentRef{ .blob = .{ .hash = try cursor.readHash() } },
        2 => ContentRef{ .extent_tree = .{
            .root_id = .{ .hash = try cursor.readHash() },
            .size_bytes = try cursor.readInt(u64),
            .chunk_bytes = try cursor.readInt(u32),
        } },
        else => error.UnsupportedContentRefVersion,
    };
}

fn optionalObjectIdEql(lhs: ?object_store.ObjectId, rhs: ?object_store.ObjectId) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return lhs.?.eql(rhs.?);
}

fn optionalContentRefEql(lhs: ?ContentRef, rhs: ?ContentRef) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return lhs.?.eql(rhs.?);
}

fn countDescriptorsNotIn(lhs: []const SegmentDescriptor, rhs: []const SegmentDescriptor) usize {
    var count: usize = 0;
    for (lhs) |entry| {
        var found = false;
        for (rhs) |other| {
            if (entry.eql(other)) {
                found = true;
                break;
            }
        }
        if (!found) count += 1;
    }
    return count;
}

fn countWalChunksNotIn(lhs: []const WalChunkDescriptor, rhs: []const WalChunkDescriptor) usize {
    var count: usize = 0;
    for (lhs) |entry| {
        var found = false;
        for (rhs) |other| {
            if (entry.eql(other)) {
                found = true;
                break;
            }
        }
        if (!found) count += 1;
    }
    return count;
}

fn countTagEntriesChanged(lhs: []const TagSnapshotEntry, rhs: []const TagSnapshotEntry) usize {
    var count: usize = 0;
    for (lhs) |entry| {
        const rhs_idx = binarySearchTagEntry(rhs, entry.key) orelse {
            count += 1;
            continue;
        };
        if (!entry.eql(rhs[rhs_idx])) count += 1;
    }
    for (rhs) |entry| {
        if (binarySearchTagEntry(lhs, entry.key) == null) count += 1;
    }
    return count;
}

fn countSeriesEntriesChanged(lhs: []const SeriesCatalogSnapshotEntry, rhs: []const SeriesCatalogSnapshotEntry) usize {
    var count: usize = 0;
    for (lhs) |entry| {
        if (!containsSeriesEntry(rhs, entry)) count += 1;
    }
    for (rhs) |entry| {
        if (!containsSeriesEntry(lhs, entry)) count += 1;
    }
    return count;
}

fn containsSeriesEntry(entries: []const SeriesCatalogSnapshotEntry, needle: SeriesCatalogSnapshotEntry) bool {
    for (entries) |entry| {
        if (entry.eql(needle)) return true;
    }
    return false;
}

fn containsObjectId(entries: []const object_store.ObjectId, needle: object_store.ObjectId) bool {
    for (entries) |entry| {
        if (entry.eql(needle)) return true;
    }
    return false;
}

fn sortDescriptors(descriptors: []SegmentDescriptor) void {
    std.sort.block(SegmentDescriptor, descriptors, {}, struct {
        fn lessThan(_: void, lhs: SegmentDescriptor, rhs: SegmentDescriptor) bool {
            if (lhs.series_id != rhs.series_id) return lhs.series_id < rhs.series_id;
            if (lhs.hour_bucket != rhs.hour_bucket) return lhs.hour_bucket < rhs.hour_bucket;
            if (lhs.start_ts != rhs.start_ts) return lhs.start_ts < rhs.start_ts;
            return std.mem.lessThan(u8, lhs.mirrorPath(), rhs.mirrorPath());
        }
    }.lessThan);
}

fn sortSeriesCatalogEntries(entries: []SeriesCatalogSnapshotEntry) void {
    std.sort.block(SeriesCatalogSnapshotEntry, entries, {}, struct {
        fn lessThan(_: void, lhs: SeriesCatalogSnapshotEntry, rhs: SeriesCatalogSnapshotEntry) bool {
            if (!std.mem.eql(u8, lhs.series, rhs.series)) return std.mem.lessThan(u8, lhs.series, rhs.series);
            if (!std.mem.eql(u8, lhs.canonical_tags, rhs.canonical_tags)) return std.mem.lessThan(u8, lhs.canonical_tags, rhs.canonical_tags);
            return lhs.series_id < rhs.series_id;
        }
    }.lessThan);
}

fn binarySearchTagEntry(entries: []const TagSnapshotEntry, key: []const u8) ?usize {
    var left: usize = 0;
    var right: usize = entries.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (std.mem.order(u8, entries[mid].key, key) == .lt) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    if (left < entries.len and std.mem.eql(u8, entries[left].key, key)) return left;
    return null;
}

fn findTreeEntry(entries: []const TreeEntry, name: []const u8) ?object_store.ObjectId {
    for (entries) |entry| {
        if (entry.object_type != .tree) continue;
        if (std.mem.eql(u8, entry.name, name)) return entry.object_id;
    }
    return null;
}

fn findBlobEntry(entries: []const TreeEntry, name: []const u8) ?object_store.ObjectId {
    for (entries) |entry| {
        if (entry.object_type != .blob) continue;
        if (std.mem.eql(u8, entry.name, name)) return entry.object_id;
    }
    return null;
}

fn listRefsRecursive(self: *RefStore, alloc: std.mem.Allocator, refs: *std.array_list.Managed(RefEntry), dir: std.fs.Dir, prefix: []const u8) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const ref_name = if (prefix.len == 0)
                    try alloc.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });
                errdefer alloc.free(ref_name);

                const ref_id = try self.readRef(ref_name) orelse {
                    alloc.free(ref_name);
                    continue;
                };
                try refs.append(.{
                    .name = ref_name,
                    .id = ref_id,
                });
            },
            .directory => {
                const next_prefix = if (prefix.len == 0)
                    try alloc.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });
                defer alloc.free(next_prefix);

                var child = try dir.openDir(entry.name, .{ .iterate = true });
                defer child.close();
                try listRefsRecursive(self, alloc, refs, child, next_prefix);
            },
            else => {},
        }
    }
}

fn writeManifestFile(alloc: std.mem.Allocator, data_dir: std.fs.Dir, descriptors: []const SegmentDescriptor) !void {
    var manifest = manifest_mod.Manifest{ .alloc = alloc, .entries = .{} };
    defer manifest.deinit();

    for (descriptors) |descriptor| {
        const mirror_path = descriptor.mirrorPath();
        if (mirror_path.len == 0) continue;
        try manifest.entries.append(alloc, .{
            .series_id = descriptor.series_id,
            .hour_bucket = descriptor.hour_bucket,
            .start_ts = descriptor.start_ts,
            .end_ts = descriptor.end_ts,
            .count = descriptor.count,
            .path = try alloc.dupe(u8, mirror_path),
        });
    }
    try manifest.rewriteCheckpoint(data_dir);
}

fn writeTagsFile(alloc: std.mem.Allocator, data_dir: std.fs.Dir, tag_snapshot: TagSnapshot) !void {
    _ = alloc;
    const temp_name = "tags.json.tmp";
    var file = try data_dir.createFile(temp_name, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer data_dir.deleteFile(temp_name) catch {};

    var write_buf: [4096]u8 = undefined;
    var writer_state = file.writer(&write_buf);
    const writer = &writer_state.interface;
    var jw = std.json.Stringify{ .writer = writer };
    try jw.beginObject();
    for (tag_snapshot.entries) |entry| {
        try jw.objectField(entry.key);
        try jw.beginArray();
        for (entry.series_ids) |series_id| {
            try jw.write(series_id);
        }
        try jw.endArray();
    }
    try jw.endObject();
    try writer_state.end();
    try file.sync();
    try data_dir.rename(temp_name, "tags.json");
}

fn writeSeriesCatalogFile(alloc: std.mem.Allocator, data_dir: std.fs.Dir, series_catalog_snapshot: SeriesCatalogSnapshot) !void {
    _ = alloc;
    const temp_name = "series_catalog.jsonl.tmp";
    var file = try data_dir.createFile(temp_name, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer data_dir.deleteFile(temp_name) catch {};

    var write_buf: [4096]u8 = undefined;
    var writer_state = file.writer(&write_buf);
    const writer = &writer_state.interface;

    for (series_catalog_snapshot.entries) |entry| {
        var jw = std.json.Stringify{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("series");
        try jw.write(entry.series);
        try jw.objectField("tags_json");
        try jw.write(entry.canonical_tags);
        try jw.objectField("series_id");
        try jw.write(entry.series_id);
        try jw.endObject();
        try writer.writeAll("\n");
    }
    try writer_state.end();
    try file.sync();
    try data_dir.rename(temp_name, "series_catalog.jsonl");
}

fn readContentBytes(alloc: std.mem.Allocator, store: *object_store.ObjectStore, content: ContentRef) ![]u8 {
    return switch (content) {
        .blob => |content_id| blk: {
            const loaded = try store.get(alloc, content_id);
            defer alloc.free(loaded.payload);
            if (loaded.obj_type != .blob) return error.InvalidContentBlobObject;
            break :blk try alloc.dupe(u8, loaded.payload);
        },
        .extent_tree => |tree| try extents.readAll(alloc, store, tree),
    };
}

fn materializeSnapshotMirrors(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    snapshot: Snapshot,
) !void {
    for (snapshot.segment_descriptors) |descriptor| {
        const mirror_path = descriptor.mirrorPath();
        if (mirror_path.len == 0) continue;
        const content = descriptor.contentRef() orelse continue;
        try writeContentRefToPath(alloc, data_dir, store, mirror_path, content);
    }
    for (snapshot.wal_index.entries) |entry| {
        const mirror_name = entry.mirrorName();
        if (mirror_name.len == 0) continue;
        const content = entry.contentRef() orelse continue;
        const path = try std.fmt.allocPrint(alloc, "wal/{s}", .{mirror_name});
        defer alloc.free(path);
        try writeContentRefToPath(alloc, data_dir, store, path, content);
    }
}

fn writeContentRefToPath(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    path: []const u8,
    content: ContentRef,
) !void {
    const bytes = try readContentBytes(alloc, store, content);
    defer alloc.free(bytes);

    if (std.fs.path.dirname(path)) |dirname| try data_dir.makePath(dirname);
    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(temp_path);

    var file = try data_dir.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer data_dir.deleteFile(temp_path) catch {};
    try file.writeAll(bytes);
    try file.sync();
    data_dir.rename(temp_path, path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            data_dir.deleteFile(path) catch {};
            try data_dir.rename(temp_path, path);
        },
        else => return err,
    };
}

fn syncDir(dir: *std.fs.Dir) !void {
    if (@hasDecl(std.fs.Dir, "sync")) {
        try dir.sync();
    }
}

test "cas codecs are deterministic for identical logical data" {
    const content_id = object_store.computeId(.blob, "deterministic-segment");
    var descriptor_a = SegmentDescriptor{
        .path = try std.testing.allocator.dupe(u8, "segments/1/a.seg"),
        .content_id = content_id,
        .file_hash = [_]u8{0xAA} ** 32,
        .file_size = 64,
        .series_id = 123,
        .hour_bucket = 3600,
        .start_ts = 10,
        .end_ts = 20,
        .count = 2,
        .ts_codec = 1,
        .val_codec = 1,
    };
    defer descriptor_a.deinit(std.testing.allocator);

    var descriptor_b = SegmentDescriptor{
        .path = try std.testing.allocator.dupe(u8, "segments/1/a.seg"),
        .content_id = content_id,
        .file_hash = [_]u8{0xAA} ** 32,
        .file_size = 64,
        .series_id = 123,
        .hour_bucket = 3600,
        .start_ts = 10,
        .end_ts = 20,
        .count = 2,
        .ts_codec = 1,
        .val_codec = 1,
    };
    defer descriptor_b.deinit(std.testing.allocator);

    const encoded_a = try encodeSegmentDescriptor(std.testing.allocator, descriptor_a);
    defer std.testing.allocator.free(encoded_a);
    const encoded_b = try encodeSegmentDescriptor(std.testing.allocator, descriptor_b);
    defer std.testing.allocator.free(encoded_b);

    try std.testing.expectEqualStrings(encoded_a, encoded_b);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/cas-store", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try object_store.ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const id_a = try store.put(.blob, encoded_a);
    const id_b = try store.put(.blob, encoded_b);
    try std.testing.expect(id_a.eql(id_b));
}

test "cas manager initializes a repository format marker" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/repo-format", .{tmp_dir.sub_path});
    defer alloc.free(data_path);

    var cas_manager = try CasManager.init(alloc, data_path, .none);
    defer cas_manager.deinit();

    try std.testing.expectEqual(current_repository_format_version, cas_manager.format.version);
    try std.testing.expectEqual(RefBackend.loose, cas_manager.format.ref_backend);
    try std.testing.expectEqual(default_extent_chunk_bytes, cas_manager.format.extent_chunk_bytes);

    const loaded = try loadRepositoryFormat(cas_manager.store.root);
    try std.testing.expectEqual(cas_manager.format.version, loaded.version);
    try std.testing.expectEqual(cas_manager.format.ref_backend, loaded.ref_backend);
    try std.testing.expectEqual(cas_manager.format.extent_chunk_bytes, loaded.extent_chunk_bytes);
}

test "legacy descriptor decoders normalize blob content refs" {
    const alloc = std.testing.allocator;
    const content_id = object_store.computeId(.blob, "legacy-blob");

    var legacy_segment = std.array_list.Managed(u8).init(alloc);
    defer legacy_segment.deinit();
    try legacy_segment.append(3);
    try legacy_segment.appendSlice(content_id.hash[0..]);
    try appendString(&legacy_segment, "segments/legacy.seg");
    try legacy_segment.appendSlice(([_]u8{0x42} ** 32)[0..]);
    try appendInt(&legacy_segment, u64, 123);
    try appendInt(&legacy_segment, u64, 77);
    try appendInt(&legacy_segment, i64, 3600);
    try appendInt(&legacy_segment, i64, 10);
    try appendInt(&legacy_segment, i64, 20);
    try appendInt(&legacy_segment, u32, 2);
    try legacy_segment.append(1);
    try legacy_segment.append(1);

    var decoded_segment = try decodeSegmentDescriptor(alloc, legacy_segment.items);
    defer decoded_segment.deinit(alloc);
    try std.testing.expect(decoded_segment.contentRef() != null);
    try std.testing.expect(decoded_segment.contentRef().?.eql(.{ .blob = content_id }));
    try std.testing.expectEqualStrings("segments/legacy.seg", decoded_segment.mirrorPath());

    var legacy_wal = std.array_list.Managed(u8).init(alloc);
    defer legacy_wal.deinit();
    try legacy_wal.append(3);
    try appendInt(&legacy_wal, u32, 1);
    try appendString(&legacy_wal, "current.wal");
    try legacy_wal.appendSlice(content_id.hash[0..]);
    try appendInt(&legacy_wal, u64, 256);
    try legacy_wal.appendSlice(([_]u8{0x24} ** 32)[0..]);
    try legacy_wal.append(1);
    try appendInt(&legacy_wal, u64, 128);

    var decoded_wal = try decodeWalIndex(alloc, legacy_wal.items);
    defer decoded_wal.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), decoded_wal.entries.len);
    try std.testing.expect(decoded_wal.entries[0].contentRef() != null);
    try std.testing.expect(decoded_wal.entries[0].contentRef().?.eql(.{ .blob = content_id }));
    try std.testing.expectEqualStrings("current.wal", decoded_wal.entries[0].mirrorName());
    try std.testing.expectEqual(@as(u64, 128), decoded_wal.entries[0].captured_bytes);
}

test "cas bootstrap imports legacy metadata into a genesis commit" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("bootstrap.series");
    const points = [_]types.Point{
        .{ .ts = 1_000, .value = 1.5 },
        .{ .ts = 1_005, .value = 2.5 },
    };
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, points[0].ts, points[points.len - 1].ts, @intCast(points.len), seg_path);
    try manifest.rewriteCheckpoint(data_dir);
    try tags.add("host=bootstrap", sid);
    try tags.save(data_dir);
    _ = try series_catalog.register("bootstrap.series", "{}", sid);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();

    const head = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    const ref_head = try cas_manager.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(head.eql(ref_head));
    try cas_manager.verifyHeadMatchesLegacy(data_dir, &manifest, &tags, &series_catalog);

    var reader = CommitReader{ .alloc = talloc, .store = &cas_manager.store, .refs = &cas_manager.refs };
    var snapshot = try reader.loadHeadSnapshot();
    defer snapshot.deinit(talloc);

    try std.testing.expectEqual(@as(usize, 0), snapshot.commit.parents.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.segment_descriptors.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.tag_snapshot.entries.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.series_catalog_snapshot.entries.len);
}

test "retention rewrites manifest and emits a CAS commit" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("retention.series");
    const now: i64 = @intCast(std.time.timestamp());
    const old_points = [_]types.Point{
        .{ .ts = now - 3 * 24 * 3600, .value = 1.0 },
        .{ .ts = now - 3 * 24 * 3600 + 10, .value = 2.0 },
    };
    const new_points = [_]types.Point{
        .{ .ts = now - 60, .value = 3.0 },
        .{ .ts = now - 30, .value = 4.0 },
    };

    _ = try series_catalog.register("retention.series", "{}", sid);
    const old_path = try segment_mod.writeSegment(talloc, data_dir, sid, old_points[0].ts - @mod(old_points[0].ts, 3600), old_points[0..]);
    defer talloc.free(old_path);
    try manifest.add(data_dir, sid, old_points[0].ts - @mod(old_points[0].ts, 3600), old_points[0].ts, old_points[old_points.len - 1].ts, @intCast(old_points.len), old_path);

    const new_path = try segment_mod.writeSegment(talloc, data_dir, sid, new_points[0].ts - @mod(new_points[0].ts, 3600), new_points[0..]);
    defer talloc.free(new_path);
    try manifest.add(data_dir, sid, new_points[0].ts - @mod(new_points[0].ts, 3600), new_points[0].ts, new_points[new_points.len - 1].ts, @intCast(new_points.len), new_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const initial_head = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);

    const changed = try retention_mod.applyWithResult(data_dir, &manifest, 1);
    try std.testing.expect(changed);

    var reloaded = try manifest_mod.Manifest.loadOrInit(talloc, data_dir);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.entries.items.len);

    const next_head = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "retention");
    try std.testing.expect(!initial_head.eql(next_head));
    try cas_manager.verifyHeadMatchesLegacy(data_dir, &manifest, &tags, &series_catalog);
}

test "compaction rewrites manifest and emits a CAS commit" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("compact.series");
    const first_points = [_]types.Point{
        .{ .ts = 1_000, .value = 1.0 },
        .{ .ts = 1_005, .value = 2.0 },
    };
    const second_points = [_]types.Point{
        .{ .ts = 1_010, .value = 3.0 },
        .{ .ts = 1_015, .value = 4.0 },
    };

    _ = try series_catalog.register("compact.series", "{}", sid);
    const first_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, first_points[0..]);
    defer talloc.free(first_path);
    try manifest.add(data_dir, sid, 0, first_points[0].ts, first_points[first_points.len - 1].ts, @intCast(first_points.len), first_path);

    const second_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, second_points[0..]);
    defer talloc.free(second_path);
    try manifest.add(data_dir, sid, 0, second_points[0].ts, second_points[second_points.len - 1].ts, @intCast(second_points.len), second_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const initial_head = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);

    const changed = try compact_mod.compactAllWithResult(talloc, data_dir, &manifest);
    try std.testing.expect(changed);

    var reloaded = try manifest_mod.Manifest.loadOrInit(talloc, data_dir);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.entries.items.len);

    const next_head = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "compaction");
    try std.testing.expect(!initial_head.eql(next_head));
    try cas_manager.verifyHeadMatchesLegacy(data_dir, &manifest, &tags, &series_catalog);
}

test "wal index captures CAS content ids for mutable current wal" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/wal-index", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var wal = try wal_mod.WAL.open(talloc, data_dir, .none);
    defer wal.close();
    _ = try wal.append(77, 1_000, 3.25);

    var index = try buildWalIndex(talloc, data_dir, null, default_extent_chunk_bytes);
    defer index.deinit(talloc);

    try std.testing.expectEqual(@as(usize, 1), index.entries.len);
    try std.testing.expect(std.mem.eql(u8, index.entries[0].name, "current.wal"));
    try std.testing.expect(index.entries[0].content_id != null);
    try std.testing.expect(index.entries[0].mutable);
    try std.testing.expectEqual(index.entries[0].file_size, index.entries[0].captured_bytes);
}

test "ref store rejects torn ref contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/refs", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var refs = try RefStore.init(std.testing.allocator, path, .none);
    defer refs.deinit();

    try refs.root.writeFile(.{
        .sub_path = "refs/heads/main",
        .data = "deadbeef\n",
    });
    try std.testing.expectError(error.InvalidObjectIdHex, refs.readHead(main_ref));
}

test "ref transactions enforce compare-and-swap and append reflogs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/ref-txn", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var refs = try RefStore.init(std.testing.allocator, path, .none);
    defer refs.deinit();

    const first = object_store.computeId(.commit, "first");
    const second = object_store.computeId(.commit, "second");
    const wrong = object_store.computeId(.commit, "wrong");

    try refs.updateRefAtomic(main_ref, first);
    try std.testing.expectError(error.RefConflict, refs.compareAndSwapRef(main_ref, wrong, second, "should-conflict"));
    try refs.compareAndSwapRef(main_ref, first, second, "advance-main");

    const head = try refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(head.eql(second));

    const reflog = try refs.root.readFileAlloc(std.testing.allocator, "logs/refs/heads/main", 4096);
    defer std.testing.allocator.free(reflog);
    try std.testing.expect(std.mem.indexOf(u8, reflog, "advance-main") != null);
}

test "checkpoints support diffing and rollback" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/checkpoint", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("checkpoint.series");
    _ = try series_catalog.register("checkpoint.series", "{}", sid);

    const first_points = [_]types.Point{.{ .ts = 1_000, .value = 1.0 }};
    const first_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, first_points[0..]);
    defer talloc.free(first_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, first_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const initial = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    const checkpoint_ref = (try cas_manager.createCheckpoint("manual")) orelse return error.MissingCasHead;
    defer talloc.free(checkpoint_ref);

    const second_points = [_]types.Point{.{ .ts = 2_000, .value = 2.0 }};
    const second_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, second_points[0..]);
    defer talloc.free(second_path);
    try manifest.add(data_dir, sid, 0, 2_000, 2_000, 1, second_path);

    const advanced = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "advance");
    try std.testing.expect(!advanced.eql(initial));

    const diff = try cas_manager.diffSnapshots(checkpoint_ref, main_ref);
    try std.testing.expect(diff.segments_added > 0);

    try cas_manager.rollbackMainTo(checkpoint_ref);
    const head = try cas_manager.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(head.eql(initial));
}

test "commit graph indexes reachable commit ancestry" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/commit-graph", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("commit.graph.series");
    _ = try series_catalog.register("commit.graph.series", "{}", sid);

    const first_points = [_]types.Point{.{ .ts = 1_000, .value = 1.0 }};
    const first_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, first_points[0..]);
    defer talloc.free(first_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, first_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const initial = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);

    const second_points = [_]types.Point{.{ .ts = 2_000, .value = 2.0 }};
    const second_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, second_points[0..]);
    defer talloc.free(second_path);
    try manifest.add(data_dir, sid, 0, 2_000, 2_000, 1, second_path);

    const advanced = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "advance");
    try std.testing.expect(!advanced.eql(initial));

    var graph = try loadCommitGraph(talloc, cas_manager.store.root);
    defer graph.deinit(talloc);
    try std.testing.expectEqual(@as(usize, 2), graph.object_ids.len);

    const advanced_idx = graph.lookup(advanced) orelse return error.CommitGraphMissingCommit;
    const initial_idx = graph.lookup(initial) orelse return error.CommitGraphMissingCommit;
    try std.testing.expect(graph.generations[advanced_idx] > graph.generations[initial_idx]);
    try std.testing.expectEqual(@as(usize, 1), @as(usize, @intCast(graph.parent_offsets[advanced_idx + 1] - graph.parent_offsets[advanced_idx])));
    try std.testing.expect(graph.object_ids[@intCast(graph.parent_positions[@intCast(graph.parent_offsets[advanced_idx])])].eql(initial));

    const log_entries = try cas_manager.loadLog(main_ref, 8);
    defer {
        for (log_entries) |*entry| entry.deinit(talloc);
        talloc.free(log_entries);
    }
    try std.testing.expectEqual(@as(usize, 2), log_entries.len);
    try std.testing.expect(log_entries[0].commit_id.eql(advanced));
    try std.testing.expectEqualStrings("advance", log_entries[0].reason);
}

test "gc prunes unreachable commits" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("gc.series");
    _ = try series_catalog.register("gc.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 1.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, points[0].ts, points[0].ts, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const initial = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    const orphan = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "orphan");
    try std.testing.expect(!initial.eql(orphan));
    try cas_manager.refs.updateHeadAtomic(main_ref, initial);

    try data_dir.makePath("wal");
    try data_dir.writeFile(.{ .sub_path = "segments/stale.seg", .data = "stale-segment" });
    try data_dir.writeFile(.{ .sub_path = "wal/stale.wal", .data = "stale-wal" });

    const dry_run = try cas_manager.gc(.{
        .dry_run = true,
        .include_reflogs = false,
        .grace_period_ms = 0,
    });
    try std.testing.expect(dry_run.unreachable_count > 0);
    try std.testing.expect(dry_run.stale_segment_files > 0);
    try std.testing.expect(dry_run.stale_wal_files > 0);
    const applied = try cas_manager.gc(.{
        .dry_run = false,
        .include_reflogs = false,
        .grace_period_ms = 0,
    });
    try std.testing.expect(applied.deleted > 0);
    try std.testing.expect(applied.quarantined_count > 0);
    try std.testing.expect(applied.mirror_deleted > 0);
    try std.testing.expectError(error.FileNotFound, data_dir.statFile("segments/stale.seg"));
    try std.testing.expectError(error.FileNotFound, data_dir.statFile("wal/stale.wal"));

    std.Thread.sleep(2 * std.time.ns_per_ms);
    const pruned = try cas_manager.gc(.{
        .dry_run = false,
        .include_reflogs = false,
        .grace_period_ms = 0,
    });
    try std.testing.expect(pruned.pruned_count > 0);
}

test "fsck and pack preserve the reachable CAS head" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/pack", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("pack.series");
    _ = try series_catalog.register("pack.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 4.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();

    const initial = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    const orphan = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "orphan-pack");
    try std.testing.expect(!initial.eql(orphan));
    try cas_manager.refs.updateHeadAtomic(main_ref, initial);

    const fsck = try cas_manager.fsck(data_dir, .{});
    try std.testing.expect(fsck.reachable_objects > 0);
    try std.testing.expect(fsck.commit_objects > 0);
    try std.testing.expect(fsck.commit_graph_entries_checked > 0);

    const pack_result = try cas_manager.pack();
    try std.testing.expectEqual(fsck.reachable_objects, pack_result.reachable_objects);

    const all_ids = try cas_manager.store.listIds(talloc);
    defer talloc.free(all_ids);
    try std.testing.expectEqual(fsck.reachable_objects, all_ids.len);
    try std.testing.expect(containsObjectId(all_ids, initial));
    try std.testing.expect(!containsObjectId(all_ids, orphan));
}

test "gc and fsck protect reflog-referenced commits by default" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/reflog-protect", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("reflog.series");
    _ = try series_catalog.register("reflog.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 9.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const initial = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    const orphan = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "reflog-orphan");
    try std.testing.expect(!initial.eql(orphan));
    try cas_manager.refs.updateHeadAtomic(main_ref, initial);

    const protected_gc = try cas_manager.gc(.{ .dry_run = true });
    try std.testing.expectEqual(@as(usize, 0), protected_gc.unreachable_count);
    try std.testing.expect(protected_gc.reflog_protected > 0);

    const protected_fsck = try cas_manager.fsck(data_dir, .{});
    try std.testing.expectEqual(@as(usize, 0), protected_fsck.dangling_objects);
    try std.testing.expect(protected_fsck.reflog_protected_objects > 0);

    const orphan_hex = orphan.toHex();
    const no_reflog_fsck = try cas_manager.fsck(data_dir, .{
        .mode = .connectivity_only,
        .include_reflogs = false,
        .write_lost_found = true,
    });
    try std.testing.expect(no_reflog_fsck.dangling_objects > 0);
    try std.testing.expect(no_reflog_fsck.lost_found_objects > 0);

    const lost_found_path = try std.fmt.allocPrint(talloc, "lost-found/commit/{s}", .{orphan_hex[0..]});
    defer talloc.free(lost_found_path);
    _ = try cas_manager.store.root.statFile(lost_found_path);
}

test "bundle create, verify, and apply round-trip the CAS head" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/bundle-data", .{tmp.sub_path});
    defer talloc.free(data_path);
    const bundle_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/bundle-out", .{tmp.sub_path});
    defer talloc.free(bundle_path);
    const restore_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/bundle-restore", .{tmp.sub_path});
    defer talloc.free(restore_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("bundle.series");
    _ = try series_catalog.register("bundle.series", "{}", sid);
    try tags.add("host=bundle", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 7.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const head = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);

    const created = try createBundle(talloc, data_path, bundle_path, .none, null);
    try std.testing.expect(created.ref_count > 0);
    try std.testing.expect(created.object_count > 0);

    const verified = try verifyBundle(talloc, bundle_path);
    try std.testing.expectEqual(created.ref_count, verified.ref_count);
    try std.testing.expectEqual(created.object_count, verified.object_count);

    const applied = try applyBundle(talloc, bundle_path, restore_path, .none);
    try std.testing.expectEqual(verified.object_count, applied.object_count);

    var restored = try CasManager.init(talloc, restore_path, .none);
    defer restored.deinit();
    const restored_head = try restored.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(restored_head.eql(head));

    var restored_snapshot = try restored.loadHeadIndex();
    defer restored_snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored_snapshot.snapshot.segment_descriptors.len);
    try std.testing.expectEqual(@as(usize, 1), restored_snapshot.snapshot.tag_snapshot.entries.len);
    try std.testing.expectEqual(@as(usize, 1), restored_snapshot.snapshot.series_catalog_snapshot.entries.len);
}

test "incremental bundle apply requires its prerequisite head" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/incremental-data", .{tmp.sub_path});
    defer talloc.free(data_path);
    const base_bundle_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/bundle-base", .{tmp.sub_path});
    defer talloc.free(base_bundle_path);
    const incremental_bundle_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/bundle-incremental", .{tmp.sub_path});
    defer talloc.free(incremental_bundle_path);
    const restore_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/bundle-dst", .{tmp.sub_path});
    defer talloc.free(restore_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("bundle.incremental");
    _ = try series_catalog.register("bundle.incremental", "{}", sid);

    const first_points = [_]types.Point{.{ .ts = 1_000, .value = 1.0 }};
    const first_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, first_points[0..]);
    defer talloc.free(first_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, first_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const initial = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    const initial_hex = initial.toHex();

    _ = try createBundle(talloc, data_path, base_bundle_path, .none, null);

    const second_points = [_]types.Point{.{ .ts = 2_000, .value = 2.0 }};
    const second_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, second_points[0..]);
    defer talloc.free(second_path);
    try manifest.add(data_dir, sid, 0, 2_000, 2_000, 1, second_path);
    const advanced = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "advance-bundle");
    try std.testing.expect(!advanced.eql(initial));

    const created = try createBundle(talloc, data_path, incremental_bundle_path, .none, initial_hex[0..]);
    try std.testing.expectEqual(@as(usize, 1), created.prerequisite_count);
    try std.testing.expect(created.object_count > 0);

    try std.testing.expectError(error.BundlePrerequisiteMissing, applyBundle(talloc, incremental_bundle_path, restore_path, .none));

    _ = try applyBundle(talloc, base_bundle_path, restore_path, .none);
    _ = try applyBundle(talloc, incremental_bundle_path, restore_path, .none);

    var restored = try CasManager.init(talloc, restore_path, .none);
    defer restored.deinit();
    const restored_head = try restored.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(restored_head.eql(advanced));
}

test "exportSpecToLegacy materializes segment and wal mirrors from content refs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/checkout-export", .{tmp.sub_path});
    defer alloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = alloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = alloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(alloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(alloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("checkout.series");
    const points = [_]types.Point{
        .{ .ts = 10, .value = 1.0 },
        .{ .ts = 20, .value = 2.0 },
    };
    const seg_path = try segment_mod.writeSegment(alloc, data_dir, sid, 0, points[0..]);
    defer alloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, points[0].ts, points[points.len - 1].ts, @intCast(points.len), seg_path);
    try tags.add("host=checkout", sid);
    _ = try series_catalog.register("checkout.series", "{}", sid);

    var wal = try wal_mod.WAL.open(alloc, data_dir, .none);
    defer wal.close();
    _ = try wal.appendSeriesRegistration(sid, "checkout.series", "{}");
    _ = try wal.append(sid, 30, 3.0);

    var cas_manager = try CasManager.init(alloc, data_path, .none);
    defer cas_manager.deinit();
    _ = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);

    try data_dir.deleteFile(seg_path);
    try data_dir.deleteFile("wal/current.wal");

    try cas_manager.exportSpecToLegacy(main_ref, data_dir);

    const restored_points = try segment_mod.readAll(alloc, data_dir, seg_path);
    defer alloc.free(restored_points);
    try std.testing.expectEqual(@as(usize, 2), restored_points.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), restored_points[0].value, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), restored_points[1].value, 1e-9);

    var seen = struct {
        records: usize = 0,
        registrations: usize = 0,

        pub fn onSeriesRegistration(self: *@This(), _: types.SeriesId, _: []const u8, _: []const u8) !void {
            self.registrations += 1;
        }

        pub fn onRecord(self: *@This(), _: types.SeriesId, _: i64, _: f64) !void {
            self.records += 1;
        }
    }{};
    const wal_bytes = try data_dir.readFileAlloc(alloc, "wal/current.wal", 1024 * 1024);
    defer alloc.free(wal_bytes);
    try wal_mod.replayBytes(alloc, wal_bytes, &seen);
    try std.testing.expectEqual(@as(usize, 1), seen.registrations);
    try std.testing.expectEqual(@as(usize, 1), seen.records);
}
