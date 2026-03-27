const std = @import("std");
const cfg = @import("../config.zig");
const types = @import("../types.zig");
const manifest_mod = @import("manifest.zig");
const compact_mod = @import("compact.zig");
const object_store = @import("object_store.zig");
const segment_mod = @import("segment.zig");
const series_catalog_mod = @import("series_catalog.zig");
const tags_mod = @import("tags.zig");
const retention_mod = @import("retention.zig");
const wal_mod = @import("wal.zig");

pub const current_format_version: u16 = 1;
pub const main_ref = "heads/main";

pub const SegmentDescriptor = struct {
    path: []u8,
    content_id: ?object_store.ObjectId = null,
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

    pub fn eql(self: SegmentDescriptor, other: SegmentDescriptor) bool {
        return std.mem.eql(u8, self.path, other.path) and
            optionalObjectIdEql(self.content_id, other.content_id) and
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
    content_id: ?object_store.ObjectId = null,
    file_size: u64,
    file_hash: [32]u8,
    mutable: bool,

    pub fn deinit(self: *WalChunkDescriptor, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }

    pub fn eql(self: WalChunkDescriptor, other: WalChunkDescriptor) bool {
        return std.mem.eql(u8, self.name, other.name) and
            optionalObjectIdEql(self.content_id, other.content_id) and
            self.file_size == other.file_size and
            std.mem.eql(u8, self.file_hash[0..], other.file_hash[0..]) and
            self.mutable == other.mutable;
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

pub const RefStore = struct {
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    fsync: cfg.FsyncPolicy,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, fsync: cfg.FsyncPolicy) !RefStore {
        var cwd = std.fs.cwd();
        try cwd.makePath(path);
        const root = try cwd.openDir(path, .{ .iterate = true });
        try root.makePath("refs");
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
        try self.updateRefAtomic(ref_name, id);
    }

    pub fn updateRefAtomic(self: *RefStore, ref_name: []const u8, id: object_store.ObjectId) !void {
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

    pub fn writeSnapshot(
        self: *CommitWriter,
        data_dir: std.fs.Dir,
        manifest: *const manifest_mod.Manifest,
        tags: *const tags_mod.TagIndex,
        series_catalog: *const series_catalog_mod.SeriesCatalog,
        parent: ?object_store.ObjectId,
        reason: []const u8,
    ) !object_store.ObjectId {
        var snapshot = try buildLegacySnapshot(self.alloc, data_dir, manifest, tags, series_catalog, self.store);
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
        try wal_entries.append(.{
            .name = try self.alloc.dupe(u8, "index"),
            .object_type = .blob,
            .object_id = wal_blob_id,
        });
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
                .name = try self.alloc.dupe(u8, std.fs.path.basename(descriptor.path)),
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
        var live = try buildLegacySnapshot(self.alloc, data_dir, manifest, tags, series_catalog, self.store);
        defer live.deinit(self.alloc);

        var stored = try self.loadHeadSnapshot();
        defer stored.deinit(self.alloc);

        try verifyLegacySnapshot(live, stored);
        try verifyWalFiles(stored.wal_index, data_dir);
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

pub const GcResult = struct {
    reachable: usize,
    unreachable_count: usize,
    deleted: usize,
};

pub const CasManager = struct {
    alloc: std.mem.Allocator,
    store: object_store.ObjectStore,
    refs: RefStore,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, fsync: cfg.FsyncPolicy) !CasManager {
        return .{
            .alloc = alloc,
            .store = try object_store.ObjectStore.init(alloc, path, fsync),
            .refs = try RefStore.init(alloc, path, fsync),
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
        var writer = CommitWriter{ .alloc = self.alloc, .store = &self.store };
        const commit_id = try writer.writeSnapshot(data_dir, manifest, tags, series_catalog, null, "bootstrap");
        try self.refs.updateHeadAtomic(main_ref, commit_id);
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
        var writer = CommitWriter{ .alloc = self.alloc, .store = &self.store };
        const commit_id = try writer.writeSnapshot(data_dir, manifest, tags, series_catalog, parent, reason);
        try self.refs.updateHeadAtomic(main_ref, commit_id);
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
        try self.refs.updateRefAtomic(ref_name, commit_id);
    }

    pub fn exportHeadToLegacy(self: *CasManager, data_dir: std.fs.Dir) !void {
        var snapshot_index = try self.loadHeadIndex();
        defer snapshot_index.deinit();

        try writeManifestFile(self.alloc, data_dir, snapshot_index.snapshot.segment_descriptors);
        try writeTagsFile(self.alloc, data_dir, snapshot_index.snapshot.tag_snapshot);
        try writeSeriesCatalogFile(self.alloc, data_dir, snapshot_index.snapshot.series_catalog_snapshot);
    }

    pub fn gc(self: *CasManager, dry_run: bool) !GcResult {
        const refs = try self.refs.listRefs(self.alloc);
        defer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }

        var reachable = try self.collectReachable(refs);
        defer reachable.deinit();

        const all = try self.store.listIds(self.alloc);
        defer self.alloc.free(all);

        var unreachable_count: usize = 0;
        var deleted: usize = 0;
        for (all) |id| {
            if (reachable.contains(id)) continue;
            unreachable_count += 1;
            if (!dry_run) {
                try self.store.delete(id);
                deleted += 1;
            }
        }

        return .{
            .reachable = reachable.count(),
            .unreachable_count = unreachable_count,
            .deleted = deleted,
        };
    }

    fn collectReachable(self: *CasManager, refs: []const RefEntry) !std.AutoHashMap(object_store.ObjectId, void) {
        var seen = std.AutoHashMap(object_store.ObjectId, void).init(self.alloc);
        errdefer seen.deinit();

        var stack = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer stack.deinit();

        for (refs) |entry| {
            try stack.append(entry.id);
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
                .blob => {},
                else => return error.UnsupportedCasObjectType,
            }
        }

        return seen;
    }
};

pub fn buildLegacySnapshot(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    manifest: *const manifest_mod.Manifest,
    tags: *const tags_mod.TagIndex,
    series_catalog: *const series_catalog_mod.SeriesCatalog,
    store: ?*object_store.ObjectStore,
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
        const content_id = try ensureBlobForFile(alloc, store, data_dir, entry.path);
        try descriptors.append(.{
            .path = try alloc.dupe(u8, entry.path),
            .content_id = content_id,
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
        .wal_index = try buildWalIndex(alloc, data_dir, store),
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

fn buildWalIndex(alloc: std.mem.Allocator, data_dir: std.fs.Dir, store: ?*object_store.ObjectStore) !WalIndex {
    const infos = try wal_mod.collectWalFileInfos(alloc, data_dir);
    defer wal_mod.freeWalFileInfos(alloc, infos);

    var entries = std.array_list.Managed(WalChunkDescriptor).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    for (infos) |info| {
        const content_id = try ensureBlobForWalFile(alloc, store, data_dir, info.name);
        try entries.append(.{
            .name = try alloc.dupe(u8, info.name),
            .content_id = content_id,
            .file_size = info.size,
            .file_hash = info.hash,
            .mutable = std.mem.eql(u8, info.name, "current.wal"),
        });
    }
    return .{ .entries = try entries.toOwnedSlice() };
}

fn verifyWalFiles(wal_index: WalIndex, data_dir: std.fs.Dir) !void {
    for (wal_index.entries) |entry| {
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "wal/{s}", .{entry.name});
        defer std.heap.page_allocator.free(path);

        var file = data_dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.CasVerificationFailed,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (!entry.mutable and stat.size != entry.file_size) return error.CasVerificationFailed;
        if (entry.mutable and stat.size < entry.file_size) return error.CasVerificationFailed;
        if (stat.size == entry.file_size) {
            const live_hash = try hashFile(data_dir, path);
            if (!std.mem.eql(u8, live_hash[0..], entry.file_hash[0..])) return error.CasVerificationFailed;
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

fn ensureBlobForFile(
    alloc: std.mem.Allocator,
    store: ?*object_store.ObjectStore,
    data_dir: std.fs.Dir,
    path: []const u8,
) !?object_store.ObjectId {
    const bytes = try data_dir.readFileAlloc(alloc, path, 128 * 1024 * 1024);
    defer alloc.free(bytes);
    const id = object_store.computeId(.blob, bytes);
    if (store) |object_store_ref| {
        const stored = try object_store_ref.put(.blob, bytes);
        if (!stored.eql(id)) return error.UnexpectedObjectId;
    }
    return id;
}

fn ensureBlobForWalFile(
    alloc: std.mem.Allocator,
    store: ?*object_store.ObjectStore,
    data_dir: std.fs.Dir,
    wal_name: []const u8,
) !?object_store.ObjectId {
    const path = try std.fmt.allocPrint(alloc, "wal/{s}", .{wal_name});
    defer alloc.free(path);
    return try ensureBlobForFile(alloc, store, data_dir, path);
}

fn encodeSegmentDescriptor(alloc: std.mem.Allocator, descriptor: SegmentDescriptor) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(2);
    try appendOptionalObjectId(&bytes, descriptor.content_id);
    try appendString(&bytes, descriptor.path);
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
    if (version != 1 and version != 2) return error.UnsupportedSegmentDescriptorVersion;

    const content_id = if (version >= 2) try cursor.readOptionalObjectId() else null;
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
        .content_id = content_id,
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

    try bytes.append(2);
    try appendInt(&bytes, u32, @intCast(wal_index.entries.len));
    for (wal_index.entries) |entry| {
        try appendString(&bytes, entry.name);
        try appendOptionalObjectId(&bytes, entry.content_id);
        try appendInt(&bytes, u64, entry.file_size);
        try bytes.appendSlice(entry.file_hash[0..]);
        try bytes.append(if (entry.mutable) 1 else 0);
    }
    return try bytes.toOwnedSlice();
}

fn decodeWalIndex(alloc: std.mem.Allocator, payload: []const u8) !WalIndex {
    var cursor = Cursor{ .bytes = payload };
    const version = try cursor.readByte();
    if (version != 1 and version != 2) return error.UnsupportedWalIndexVersion;

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
        const content_id = if (version >= 2) try cursor.readOptionalObjectId() else null;
        const file_size = try cursor.readInt(u64);
        const file_hash = try cursor.readHash();
        const mutable = (try cursor.readByte()) != 0;
        entries[i] = .{
            .name = name,
            .content_id = content_id,
            .file_size = file_size,
            .file_hash = file_hash,
            .mutable = mutable,
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

fn optionalObjectIdEql(lhs: ?object_store.ObjectId, rhs: ?object_store.ObjectId) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return lhs.?.eql(rhs.?);
}

fn sortDescriptors(descriptors: []SegmentDescriptor) void {
    std.sort.block(SegmentDescriptor, descriptors, {}, struct {
        fn lessThan(_: void, lhs: SegmentDescriptor, rhs: SegmentDescriptor) bool {
            if (lhs.series_id != rhs.series_id) return lhs.series_id < rhs.series_id;
            if (lhs.hour_bucket != rhs.hour_bucket) return lhs.hour_bucket < rhs.hour_bucket;
            if (lhs.start_ts != rhs.start_ts) return lhs.start_ts < rhs.start_ts;
            return std.mem.lessThan(u8, lhs.path, rhs.path);
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
        try manifest.entries.append(alloc, .{
            .series_id = descriptor.series_id,
            .hour_bucket = descriptor.hour_bucket,
            .start_ts = descriptor.start_ts,
            .end_ts = descriptor.end_ts,
            .count = descriptor.count,
            .path = try alloc.dupe(u8, descriptor.path),
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

fn syncDir(dir: *std.fs.Dir) !void {
    if (@hasDecl(std.fs.Dir, "sync")) {
        try dir.sync();
    }
}

test "cas codecs are deterministic for identical logical data" {
    var descriptor_a = SegmentDescriptor{
        .path = try std.testing.allocator.dupe(u8, "segments/1/a.seg"),
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

    var index = try buildWalIndex(talloc, data_dir, null);
    defer index.deinit(talloc);

    try std.testing.expectEqual(@as(usize, 1), index.entries.len);
    try std.testing.expect(std.mem.eql(u8, index.entries[0].name, "current.wal"));
    try std.testing.expect(index.entries[0].content_id != null);
    try std.testing.expect(index.entries[0].mutable);
}

test "ref store rejects torn ref contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/refs", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var refs = try RefStore.init(std.testing.allocator, path, .none);
    defer refs.deinit();

    try refs.root.writeFile("refs/heads/main", "deadbeef\n");
    try std.testing.expectError(error.InvalidObjectIdHex, refs.readHead(main_ref));
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

    const dry_run = try cas_manager.gc(true);
    try std.testing.expect(dry_run.unreachable_count > 0);
    const applied = try cas_manager.gc(false);
    try std.testing.expect(applied.deleted > 0);
}
