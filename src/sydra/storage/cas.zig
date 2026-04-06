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
pub const legacy_repository_format_version: u16 = 1;
pub const current_repository_format_version: u16 = 3;
pub const default_extent_chunk_bytes: u32 = 64 * 1024;
const store_format_path = "objects/info/store-format";
const store_format_magic = "SYDSTORE1";
const repository_id_path = "objects/info/repository-id";
const repository_id_magic = "SYDREPO1";

pub const RefBackend = enum(u8) {
    loose = 1,
    reftable = 2,
};

pub const RepositoryFormat = struct {
    version: u16 = current_repository_format_version,
    ref_backend: RefBackend = .reftable,
    extent_chunk_bytes: u32 = default_extent_chunk_bytes,
};

pub const RepositoryIdentity = struct {
    bytes: [32]u8,

    pub fn eql(self: RepositoryIdentity, other: RepositoryIdentity) bool {
        return std.mem.eql(u8, self.bytes[0..], other.bytes[0..]);
    }

    pub fn toHex(self: RepositoryIdentity) [64]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }
};

pub const StartupDefaults = struct {
    cas_mode: cfg.CasMode,
    metadata_read_mode: cfg.MetadataReadMode,
};

const legacy_startup_defaults = StartupDefaults{
    .cas_mode = .off,
    .metadata_read_mode = .legacy,
};

const primary_startup_defaults = StartupDefaults{
    .cas_mode = .dual_write,
    .metadata_read_mode = .primary,
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
    segment_root: ?object_store.ObjectId = null,
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

    pub fn segmentRoot(self: SegmentDescriptor) ?object_store.ObjectId {
        return self.segment_root;
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

pub const CheckpointSeriesHighwater = struct {
    series_id: types.SeriesId,
    highwater_ts: i64,

    pub fn eql(self: CheckpointSeriesHighwater, other: CheckpointSeriesHighwater) bool {
        return self.series_id == other.series_id and self.highwater_ts == other.highwater_ts;
    }
};

pub const CheckpointWalEntry = struct {
    name: []u8,
    journal_root: ?object_store.ObjectId = null,
    mutable: bool,
    captured_bytes: u64,

    pub fn deinit(self: *CheckpointWalEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }

    pub fn eql(self: CheckpointWalEntry, other: CheckpointWalEntry) bool {
        return std.mem.eql(u8, self.name, other.name) and
            self.mutable == other.mutable and
            self.captured_bytes == other.captured_bytes;
    }
};

pub const CheckpointState = struct {
    highwaters: []CheckpointSeriesHighwater,
    wal_entries: []CheckpointWalEntry,

    pub fn empty(alloc: std.mem.Allocator) !CheckpointState {
        return .{
            .highwaters = try alloc.alloc(CheckpointSeriesHighwater, 0),
            .wal_entries = try alloc.alloc(CheckpointWalEntry, 0),
        };
    }

    pub fn deinit(self: *CheckpointState, alloc: std.mem.Allocator) void {
        alloc.free(self.highwaters);
        for (self.wal_entries) |*entry| entry.deinit(alloc);
        alloc.free(self.wal_entries);
    }
};

pub const WalChunkDescriptor = struct {
    name: []u8,
    mirror_name: []u8 = &[_]u8{},
    journal_root: ?object_store.ObjectId = null,
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

    pub fn journalRoot(self: WalChunkDescriptor) ?object_store.ObjectId {
        return self.journal_root;
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
    checkpoint_state: CheckpointState,

    pub fn deinit(self: *LegacySnapshot, alloc: std.mem.Allocator) void {
        for (self.segment_descriptors) |*descriptor| descriptor.deinit(alloc);
        alloc.free(self.segment_descriptors);
        self.tag_snapshot.deinit(alloc);
        self.series_catalog_snapshot.deinit(alloc);
        self.wal_index.deinit(alloc);
        self.checkpoint_state.deinit(alloc);
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
    checkpoint_state: CheckpointState,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        self.commit.deinit(alloc);
        for (self.segment_descriptors) |*descriptor| descriptor.deinit(alloc);
        alloc.free(self.segment_descriptors);
        self.tag_snapshot.deinit(alloc);
        self.series_catalog_snapshot.deinit(alloc);
        self.wal_index.deinit(alloc);
        self.checkpoint_state.deinit(alloc);
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
    backend: RefBackend = .loose,

    const ReflogValidation = struct {
        checked: usize,
        stale: usize,
    };

    pub fn init(alloc: std.mem.Allocator, path: []const u8, fsync: cfg.FsyncPolicy) !RefStore {
        var cwd = std.fs.cwd();
        try cwd.makePath(path);
        const root = try cwd.openDir(path, .{ .iterate = true });
        try root.makePath("refs");
        try root.makePath("refs/heads");
        try root.makePath("logs/refs");
        try root.makePath("logs/refs/heads");
        try root.makePath("refs/txn");
        try root.makePath("reftable");
        try root.makePath("reftable/info");
        try root.makePath("symrefs");
        return .{ .alloc = alloc, .root = root, .fsync = fsync };
    }

    pub fn deinit(self: *RefStore) void {
        self.root.close();
    }

    pub fn setBackend(self: *RefStore, backend: RefBackend) void {
        self.backend = backend;
    }

    pub fn readSymRef(self: *RefStore, name: []const u8) !?[]u8 {
        const path = try std.fmt.allocPrint(self.alloc, "symrefs/{s}", .{name});
        defer self.alloc.free(path);

        const body = self.root.readFileAlloc(self.alloc, path, 4096) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.alloc.free(body);
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try self.alloc.dupe(u8, trimmed);
    }

    pub fn writeSymRef(self: *RefStore, name: []const u8, target: []const u8) !void {
        const path = try std.fmt.allocPrint(self.alloc, "symrefs/{s}", .{name});
        defer self.alloc.free(path);
        if (std.fs.path.dirname(path)) |dirname| try self.root.makePath(dirname);

        const temp_path = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{path});
        defer self.alloc.free(temp_path);
        var file = try self.root.createFile(temp_path, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer self.root.deleteFile(temp_path) catch {};
        try file.writeAll(target);
        try file.writeAll("\n");
        if (self.fsync != .none) try file.sync();
        self.root.rename(temp_path, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                self.root.deleteFile(path) catch {};
                try self.root.rename(temp_path, path);
            },
            else => return err,
        };
        if (self.fsync != .none) {
            try syncDir(&self.root);
        }
    }

    pub fn readHead(self: *RefStore, ref_name: []const u8) !?object_store.ObjectId {
        return self.readRef(ref_name);
    }

    pub fn readRef(self: *RefStore, ref_name: []const u8) !?object_store.ObjectId {
        if (self.backend == .reftable) {
            const reftable_id = try self.readReftableRef(ref_name);
            if (reftable_id != null or try self.hasReftableTables()) return reftable_id;
        }
        return self.readLooseRef(ref_name);
    }

    fn readLooseRef(self: *RefStore, ref_name: []const u8) !?object_store.ObjectId {
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

    pub fn deleteRef(self: *RefStore, ref_name: []const u8, reason: []const u8) !void {
        const current = try self.readRef(ref_name) orelse return error.RefNotFound;
        if (self.backend == .reftable and try self.hasReftableTables()) {
            var records = [_]ReftableRefRecord{.{
                .name = try self.alloc.dupe(u8, ref_name),
                .id = null,
            }};
            defer records[0].deinit(self.alloc);
            var reflogs = [_]ReflogEntry{.{
                .ref_name = try self.alloc.dupe(u8, ref_name),
                .old_id = current,
                .new_id = current,
                .timestamp_ms = std.time.milliTimestamp(),
                .reason = try self.alloc.dupe(u8, reason),
            }};
            defer reflogs[0].deinit(self.alloc);
            try self.appendReftableRecords(records[0..], reflogs[0..]);
            try self.maybeCompactReftable();
            return;
        }

        try self.deleteRefFile(ref_name);
        try self.appendReflog(ref_name, current, current, reason);
    }

    pub fn renameRef(self: *RefStore, old_ref_name: []const u8, new_ref_name: []const u8, reason: []const u8) !void {
        const current = try self.readRef(old_ref_name) orelse return error.RefNotFound;
        if (try self.readRef(new_ref_name) != null) return error.RefConflict;

        if (self.backend == .reftable and try self.hasReftableTables()) {
            var records = [_]ReftableRefRecord{
                .{
                    .name = try self.alloc.dupe(u8, old_ref_name),
                    .id = null,
                },
                .{
                    .name = try self.alloc.dupe(u8, new_ref_name),
                    .id = current,
                },
            };
            defer {
                for (&records) |*record| record.deinit(self.alloc);
            }
            var reflogs = [_]ReflogEntry{
                .{
                    .ref_name = try self.alloc.dupe(u8, old_ref_name),
                    .old_id = current,
                    .new_id = current,
                    .timestamp_ms = std.time.milliTimestamp(),
                    .reason = try self.alloc.dupe(u8, reason),
                },
                .{
                    .ref_name = try self.alloc.dupe(u8, new_ref_name),
                    .old_id = null,
                    .new_id = current,
                    .timestamp_ms = std.time.milliTimestamp(),
                    .reason = try self.alloc.dupe(u8, reason),
                },
            };
            defer {
                for (&reflogs) |*entry| entry.deinit(self.alloc);
            }
            try self.appendReftableRecords(records[0..], reflogs[0..]);
            try self.maybeCompactReftable();
            return;
        }

        try self.writeRefFileAtomic(new_ref_name, current);
        try self.deleteRefFile(old_ref_name);
        try self.appendReflog(old_ref_name, current, current, reason);
        try self.appendReflog(new_ref_name, null, current, reason);
    }

    pub fn loadReflog(self: *RefStore, alloc: std.mem.Allocator, ref_name: []const u8, max_entries: usize) ![]ReflogEntry {
        if (self.backend == .reftable and try self.hasReftableTables()) {
            return try loadReftableReflogEntriesForRef(alloc, self.root, ref_name, max_entries);
        }
        const all_entries = try loadLooseReflogEntriesForRef(alloc, self.root, ref_name);
        errdefer {
            for (all_entries) |*entry| entry.deinit(alloc);
            alloc.free(all_entries);
        }

        var filtered = std.array_list.Managed(ReflogEntry).init(alloc);
        errdefer {
            for (filtered.items) |*entry| entry.deinit(alloc);
            filtered.deinit();
        }
        var idx = all_entries.len;
        while (idx > 0 and filtered.items.len < max_entries) {
            idx -= 1;
            const entry = all_entries[idx];
            if (!std.mem.eql(u8, entry.ref_name, ref_name)) continue;
            try filtered.append(.{
                .ref_name = try alloc.dupe(u8, entry.ref_name),
                .old_id = entry.old_id,
                .new_id = entry.new_id,
                .timestamp_ms = entry.timestamp_ms,
                .reason = try alloc.dupe(u8, entry.reason),
            });
        }
        for (all_entries) |*entry| entry.deinit(alloc);
        alloc.free(all_entries);
        return try filtered.toOwnedSlice();
    }

    pub fn updateRefTxn(self: *RefStore, updates: []const RefTxnUpdate, reason: []const u8) !void {
        if (self.backend == .reftable) {
            return try self.updateReftableRefTxn(updates, reason);
        }
        return try self.updateLooseRefTxn(updates, reason);
    }

    fn updateLooseRefTxn(self: *RefStore, updates: []const RefTxnUpdate, reason: []const u8) !void {
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

    fn updateReftableRefTxn(self: *RefStore, updates: []const RefTxnUpdate, reason: []const u8) !void {
        if (updates.len == 0) return;

        const intent_path = try self.writeIntent(updates, reason);
        defer {
            self.root.deleteFile(intent_path) catch {};
            self.alloc.free(intent_path);
        }

        var old_ids = try self.alloc.alloc(?object_store.ObjectId, updates.len);
        defer self.alloc.free(old_ids);

        var ref_records = std.array_list.Managed(ReftableRefRecord).init(self.alloc);
        defer {
            for (ref_records.items) |*record| record.deinit(self.alloc);
            ref_records.deinit();
        }
        var reflogs = std.array_list.Managed(ReflogEntry).init(self.alloc);
        defer {
            for (reflogs.items) |*entry| entry.deinit(self.alloc);
            reflogs.deinit();
        }

        for (updates, 0..) |update, idx| {
            const current = try self.readRef(update.ref_name);
            old_ids[idx] = current;
            if (!optionalObjectIdEql(update.expected_old, current)) {
                if (update.expected_old != null) return error.RefConflict;
            }
            try ref_records.append(.{
                .name = try self.alloc.dupe(u8, update.ref_name),
                .id = update.new_id,
            });
            try reflogs.append(.{
                .ref_name = try self.alloc.dupe(u8, update.ref_name),
                .old_id = current,
                .new_id = update.new_id,
                .timestamp_ms = std.time.milliTimestamp(),
                .reason = try self.alloc.dupe(u8, reason),
            });
        }

        try self.appendReftableRecords(ref_records.items, reflogs.items);
        try self.maybeCompactReftable();
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

    fn deleteRefFile(self: *RefStore, ref_name: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.alloc, "refs/{s}", .{ref_name});
        defer self.alloc.free(full_path);
        self.root.deleteFile(full_path) catch |err| switch (err) {
            error.FileNotFound => return error.RefNotFound,
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

    fn writeLooseReflogFile(
        alloc: std.mem.Allocator,
        root: std.fs.Dir,
        log_path: []const u8,
        entries: []const ReflogEntry,
        fsync: cfg.FsyncPolicy,
    ) !void {
        if (std.fs.path.dirname(log_path)) |dirname| {
            try root.makePath(dirname);
        }
        const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{log_path});
        defer alloc.free(temp_path);

        var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer root.deleteFile(temp_path) catch {};

        var write_buf: [1024]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;
        for (entries) |entry| {
            const old_hex = if (entry.old_id) |id| id.toHex() else [_]u8{'0'} ** 64;
            const new_hex = entry.new_id.toHex();
            try writer.print("{d} {s} {s} {s}\n", .{
                entry.timestamp_ms,
                old_hex,
                new_hex,
                entry.reason,
            });
        }
        try writer_state.end();
        if (fsync != .none) {
            try file.sync();
        }
        root.rename(temp_path, log_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                root.deleteFile(log_path) catch {};
                try root.rename(temp_path, log_path);
            },
            else => return err,
        };
        if (fsync != .none) {
            var root_for_sync = root;
            try syncDir(&root_for_sync);
        }
    }

    pub fn listRefs(self: *RefStore, alloc: std.mem.Allocator) ![]RefEntry {
        if (self.backend == .reftable) {
            const reftable_refs = try self.listReftableRefs(alloc);
            if (reftable_refs.len != 0 or try self.hasReftableTables()) return reftable_refs;
            alloc.free(reftable_refs);
        }
        return try self.listLooseRefs(alloc);
    }

    fn listLooseRefs(self: *RefStore, alloc: std.mem.Allocator) ![]RefEntry {
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

    pub fn collectReflogObjectIds(self: *RefStore, alloc: std.mem.Allocator) ![]object_store.ObjectId {
        if (self.backend == .reftable and try self.hasReftableTables()) {
            return try self.collectReftableReflogObjectIds(alloc);
        }
        return try collectLooseReflogObjectIds(alloc, self.root);
    }

    pub fn validateReflogs(self: *RefStore, alloc: std.mem.Allocator, refs: []const RefEntry) !ReflogValidation {
        if (self.backend == .reftable and try self.hasReftableTables()) {
            return try self.validateReftableReflogs(alloc, refs);
        }

        const reflog_files = try listFilesRecursive(alloc, self.root, "logs/refs");
        defer freeOwnedStrings(alloc, reflog_files);

        var checked: usize = 0;
        var stale: usize = 0;
        for (reflog_files) |path| {
            try validateReflogFile(alloc, self.root, path);
            checked += 1;
            const ref_name = path["logs/refs/".len..];
            if (!containsRef(refs, ref_name)) {
                stale += 1;
            }
        }
        return .{ .checked = checked, .stale = stale };
    }

    pub fn migrateLooseToReftable(self: *RefStore) !void {
        if (try self.hasReftableTables()) {
            self.backend = .reftable;
            return;
        }

        const refs = try self.listLooseRefs(self.alloc);
        defer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }
        const reflogs = try loadLooseReflogEntries(self.alloc, self.root);
        defer {
            for (reflogs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(reflogs);
        }

        try self.writeReftableSnapshot(refs, reflogs);
        self.backend = .reftable;
    }

    pub fn rebuildReftableMetadata(self: *RefStore) !struct {
        state_rebuilt: bool,
        tables_list_rebuilt: bool,
    } {
        const table_names = try scanReftableTableFiles(self.alloc, self.root);
        defer freeOwnedStrings(self.alloc, table_names);

        if (table_names.len == 0 and self.backend != .reftable) {
            return .{
                .state_rebuilt = false,
                .tables_list_rebuilt = false,
            };
        }

        try self.root.makePath("reftable");
        try self.root.makePath("reftable/info");
        try writeReftableTablesList(self.alloc, self.root, table_names, self.fsync);
        try writeReftableState(self.alloc, self.root, .{
            .next_update_index = try inferNextReftableUpdateIndexFromNames(table_names),
        }, self.fsync);
        try rebuildReftableSummaryIndex(self.alloc, self.root, self.fsync);
        return .{
            .state_rebuilt = true,
            .tables_list_rebuilt = true,
        };
    }

    pub fn expireReflogEntries(self: *RefStore, cutoff_ms: i64) !usize {
        if (self.backend == .reftable and try self.hasReftableTables()) {
            const refs = try self.listRefs(self.alloc);
            defer {
                for (refs) |*entry| entry.deinit(self.alloc);
                self.alloc.free(refs);
            }
            const reflogs = try loadReftableReflogEntries(self.alloc, self.root);
            defer {
                for (reflogs) |*entry| entry.deinit(self.alloc);
                self.alloc.free(reflogs);
            }

            var kept = std.array_list.Managed(ReflogEntry).init(self.alloc);
            defer {
                for (kept.items) |*entry| entry.deinit(self.alloc);
                kept.deinit();
            }

            var expired: usize = 0;
            for (reflogs) |entry| {
                if (entry.timestamp_ms < cutoff_ms) {
                    expired += 1;
                    continue;
                }
                try kept.append(.{
                    .ref_name = try self.alloc.dupe(u8, entry.ref_name),
                    .old_id = entry.old_id,
                    .new_id = entry.new_id,
                    .timestamp_ms = entry.timestamp_ms,
                    .reason = try self.alloc.dupe(u8, entry.reason),
                });
            }
            if (expired == 0) return 0;
            try self.replaceReftableSnapshot(refs, kept.items);
            return expired;
        }

        const reflog_files = try listFilesRecursive(self.alloc, self.root, "logs/refs");
        defer freeOwnedStrings(self.alloc, reflog_files);

        var expired: usize = 0;
        for (reflog_files) |path| {
            const ref_name = path["logs/refs/".len..];
            const entries = try loadLooseReflogEntriesForRef(self.alloc, self.root, ref_name);
            defer {
                for (entries) |*entry| entry.deinit(self.alloc);
                self.alloc.free(entries);
            }

            var kept = std.array_list.Managed(ReflogEntry).init(self.alloc);
            defer {
                for (kept.items) |*entry| entry.deinit(self.alloc);
                kept.deinit();
            }

            var changed = false;
            for (entries) |entry| {
                if (entry.timestamp_ms < cutoff_ms) {
                    expired += 1;
                    changed = true;
                    continue;
                }
                try kept.append(.{
                    .ref_name = try self.alloc.dupe(u8, entry.ref_name),
                    .old_id = entry.old_id,
                    .new_id = entry.new_id,
                    .timestamp_ms = entry.timestamp_ms,
                    .reason = try self.alloc.dupe(u8, entry.reason),
                });
            }
            if (!changed) continue;
            if (kept.items.len == 0) {
                self.root.deleteFile(path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                continue;
            }
            try writeLooseReflogFile(self.alloc, self.root, path, kept.items, self.fsync);
        }
        return expired;
    }

    fn readReftableRef(self: *RefStore, ref_name: []const u8) !?object_store.ObjectId {
        return try readReftableRefWithCursor(self.alloc, self.root, ref_name);
    }

    fn listReftableRefs(self: *RefStore, alloc: std.mem.Allocator) ![]RefEntry {
        return try listReftableRefsWithCursor(alloc, self.root);
    }

    fn collectReftableReflogObjectIds(self: *RefStore, alloc: std.mem.Allocator) ![]object_store.ObjectId {
        const table_names = try loadReftableTableNames(alloc, self.root);
        defer freeOwnedStrings(alloc, table_names);

        var ids = std.array_list.Managed(object_store.ObjectId).init(alloc);
        defer ids.deinit();
        var seen = std.AutoHashMap(object_store.ObjectId, void).init(alloc);
        defer seen.deinit();

        for (table_names) |table_name| {
            var table = try loadReftableTable(alloc, self.root, table_name);
            defer table.deinit(alloc);
            for (table.reflogs) |entry| {
                if (entry.old_id) |old_id| {
                    const gop = try seen.getOrPut(old_id);
                    if (!gop.found_existing) try ids.append(old_id);
                }
                const gop = try seen.getOrPut(entry.new_id);
                if (!gop.found_existing) try ids.append(entry.new_id);
            }
        }
        return try ids.toOwnedSlice();
    }

    fn validateReftableReflogs(self: *RefStore, alloc: std.mem.Allocator, refs: []const RefEntry) !ReflogValidation {
        const table_names = try loadReftableTableNames(alloc, self.root);
        defer freeOwnedStrings(alloc, table_names);

        var checked: usize = 0;
        var stale: usize = 0;
        for (table_names) |table_name| {
            var table = try loadReftableTable(alloc, self.root, table_name);
            defer table.deinit(alloc);
            checked += table.reflogs.len;
            for (table.reflogs) |entry| {
                if (!containsRef(refs, entry.ref_name)) stale += 1;
            }
        }
        return .{ .checked = checked, .stale = stale };
    }

    fn appendReftableRecords(self: *RefStore, refs: []const ReftableRefRecord, reflogs: []const ReflogEntry) !void {
        var state = try loadOrInitReftableState(self.alloc, self.root);
        const update_index = state.next_update_index;
        state.next_update_index += 1;
        try writeReftableState(self.alloc, self.root, state, self.fsync);

        const span = ReftableSpan{
            .min_update_index = update_index,
            .max_update_index = update_index,
        };
        const table_name = try reftableTablePathForSpan(self.alloc, span);
        defer self.alloc.free(table_name);
        try writeReftableTable(self.alloc, self.root, table_name, span, refs, reflogs, self.fsync);

        const tables = try loadReftableTableNames(self.alloc, self.root);
        defer freeOwnedStrings(self.alloc, tables);
        var next = std.array_list.Managed([]u8).init(self.alloc);
        defer {
            for (next.items) |name| self.alloc.free(name);
            next.deinit();
        }
        for (tables) |name| try next.append(try self.alloc.dupe(u8, name));
        try next.append(try self.alloc.dupe(u8, table_name));
        try writeReftableTablesList(self.alloc, self.root, next.items, self.fsync);
        try rebuildReftableSummaryIndex(self.alloc, self.root, self.fsync);
    }

    fn writeReftableSnapshot(self: *RefStore, refs: []const RefEntry, reflogs: []const ReflogEntry) !void {
        var ref_records = try self.alloc.alloc(ReftableRefRecord, refs.len);
        defer {
            for (ref_records) |*record| record.deinit(self.alloc);
            self.alloc.free(ref_records);
        }
        for (refs, 0..) |entry, idx| {
            ref_records[idx] = .{
                .name = try self.alloc.dupe(u8, entry.name),
                .id = entry.id,
            };
        }

        var state = try loadOrInitReftableState(self.alloc, self.root);
        const update_index = state.next_update_index;
        state.next_update_index += 1;
        try writeReftableState(self.alloc, self.root, state, self.fsync);

        const span = ReftableSpan{
            .min_update_index = update_index,
            .max_update_index = update_index,
        };
        const table_name = try reftableTablePathForSpan(self.alloc, span);
        defer self.alloc.free(table_name);
        try writeReftableTable(self.alloc, self.root, table_name, span, ref_records, reflogs, self.fsync);
        const names = [_][]const u8{table_name};
        try writeReftableTablesList(self.alloc, self.root, names[0..], self.fsync);
        try rebuildReftableSummaryIndex(self.alloc, self.root, self.fsync);
    }

    fn replaceReftableSnapshot(self: *RefStore, refs: []const RefEntry, reflogs: []const ReflogEntry) !void {
        const existing_names = try scanReftableTableFiles(self.alloc, self.root);
        defer freeOwnedStrings(self.alloc, existing_names);

        var ref_records = try self.alloc.alloc(ReftableRefRecord, refs.len);
        defer {
            for (ref_records) |*record| record.deinit(self.alloc);
            self.alloc.free(ref_records);
        }
        for (refs, 0..) |entry, idx| {
            ref_records[idx] = .{
                .name = try self.alloc.dupe(u8, entry.name),
                .id = entry.id,
            };
        }

        var state = try loadOrInitReftableState(self.alloc, self.root);
        const update_index = state.next_update_index;
        state.next_update_index += 1;
        try writeReftableState(self.alloc, self.root, state, self.fsync);

        const span = ReftableSpan{
            .min_update_index = update_index,
            .max_update_index = update_index,
        };
        const table_name = try reftableTablePathForSpan(self.alloc, span);
        defer self.alloc.free(table_name);
        try writeReftableTable(self.alloc, self.root, table_name, span, ref_records, reflogs, self.fsync);
        const names = [_][]const u8{table_name};
        try writeReftableTablesList(self.alloc, self.root, names[0..], self.fsync);
        try rebuildReftableSummaryIndex(self.alloc, self.root, self.fsync);

        for (existing_names) |name| {
            if (std.mem.eql(u8, name, table_name)) continue;
            self.root.deleteFile(name) catch {};
        }
    }

    fn maybeCompactReftable(self: *RefStore) !void {
        const table_names = try loadReftableTableNames(self.alloc, self.root);
        defer freeOwnedStrings(self.alloc, table_names);
        const compact_from = try selectReftableCompactionStart(self.alloc, self.root, table_names);
        if (compact_from == null) return;

        const start = compact_from.?;
        var merged = try mergeReftableTables(self.alloc, self.root, table_names[start..]);
        defer merged.deinit(self.alloc);

        const merged_name = try reftableTablePathForSpan(self.alloc, .{
            .min_update_index = merged.min_update_index,
            .max_update_index = merged.max_update_index,
        });
        defer self.alloc.free(merged_name);
        try writeReftableTable(
            self.alloc,
            self.root,
            merged_name,
            .{
                .min_update_index = merged.min_update_index,
                .max_update_index = merged.max_update_index,
            },
            merged.refs,
            merged.reflogs,
            self.fsync,
        );

        var next = std.array_list.Managed([]u8).init(self.alloc);
        defer {
            for (next.items) |name| self.alloc.free(name);
            next.deinit();
        }
        for (table_names[0..start]) |name| try next.append(try self.alloc.dupe(u8, name));
        try next.append(try self.alloc.dupe(u8, merged_name));
        try writeReftableTablesList(self.alloc, self.root, next.items, self.fsync);
        try rebuildReftableSummaryIndex(self.alloc, self.root, self.fsync);
        for (table_names[start..]) |name| self.root.deleteFile(name) catch {};
    }

    fn hasReftableTables(self: *RefStore) !bool {
        const table_names = try loadReftableTableNames(self.alloc, self.root);
        defer freeOwnedStrings(self.alloc, table_names);
        return table_names.len != 0;
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

    pub fn writeCanonicalSnapshot(
        self: *CommitWriter,
        snapshot: *const LegacySnapshot,
        parents: []const object_store.ObjectId,
        created_at_ms: i64,
        reason: []const u8,
    ) !object_store.ObjectId {
        return try self.writePreparedSnapshotWithMetadata(snapshot, parents, created_at_ms, reason);
    }

    fn writePreparedSnapshot(
        self: *CommitWriter,
        snapshot: *const LegacySnapshot,
        parent: ?object_store.ObjectId,
        reason: []const u8,
    ) !object_store.ObjectId {
        const parent_ids = try buildParentSlice(self.alloc, parent);
        defer self.alloc.free(parent_ids);
        return try self.writePreparedSnapshotWithMetadata(snapshot, parent_ids, std.time.milliTimestamp(), reason);
    }

    fn writePreparedSnapshotWithMetadata(
        self: *CommitWriter,
        snapshot: *const LegacySnapshot,
        parents: []const object_store.ObjectId,
        created_at_ms: i64,
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

        const checkpoint_payload = try encodeCheckpointState(self.alloc, snapshot.checkpoint_state);
        defer self.alloc.free(checkpoint_payload);
        const checkpoint_blob_id = try self.store.put(.blob, checkpoint_payload);

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
            .name = try self.alloc.dupe(u8, "checkpoint"),
            .object_type = .blob,
            .object_id = checkpoint_blob_id,
        });
        try wal_entries.append(.{
            .name = try self.alloc.dupe(u8, "index"),
            .object_type = .blob,
            .object_id = wal_blob_id,
        });
        for (snapshot.wal_index.entries) |entry| {
            if (entry.journalRoot()) |journal_root| {
                const gop = try wal_chunk_ids.getOrPut(journal_root);
                if (!gop.found_existing) {
                    const chunk_hex = journal_root.toHex();
                    try wal_entries.append(.{
                        .name = try std.fmt.allocPrint(self.alloc, "journal-{s}", .{chunk_hex[0..]}),
                        .object_type = .tree,
                        .object_id = journal_root,
                    });
                }
            }
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

        const reason_copy = try self.alloc.dupe(u8, reason);
        defer self.alloc.free(reason_copy);
        const commit = Commit{
            .format_version = current_format_version,
            .root = root_id,
            .parents = try self.alloc.dupe(object_store.ObjectId, parents),
            .created_at_ms = created_at_ms,
            .reason = reason_copy,
        };
        defer self.alloc.free(commit.parents);
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
        var checkpoint_state = try CheckpointState.empty(self.alloc);
        errdefer checkpoint_state.deinit(self.alloc);

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

            if (findBlobEntry(wal_tree.entries, "checkpoint")) |checkpoint_blob_id| {
                const loaded = try self.store.get(self.alloc, checkpoint_blob_id);
                defer self.alloc.free(loaded.payload);
                if (loaded.obj_type != .blob) return error.InvalidCheckpointStateObject;
                checkpoint_state.deinit(self.alloc);
                checkpoint_state = try decodeCheckpointState(self.alloc, loaded.payload);
            } else {
                checkpoint_state.deinit(self.alloc);
                checkpoint_state = try buildCheckpointState(self.alloc, descriptors.items, wal_index.entries);
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
            .checkpoint_state = checkpoint_state,
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

pub const PruneOptions = struct {
    dry_run: bool = false,
    grace_period_ms: i64 = 24 * 60 * 60 * 1000,
};

pub const PruneResult = struct {
    pruned_count: usize,
    pruned_bytes: u64,
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
    compatibility_debt: CompatibilityDebtReport = .{},
};

pub const PackResult = struct {
    reachable_objects: usize,
    rewritten_objects: usize,
};

const commit_graph_path = "objects/info/commit-graph";
const commit_graph_magic = "SYDCGR1\x00";
const reachability_bitmap_path = "objects/info/reachability-bitmap";
const reachability_bitmap_magic = "SYDRBIT1";
const object_refs_index_path = "objects/info/object-refs";
const object_refs_magic = "SYDOREF1";
const changed_path_bloom_bytes: usize = 128;

const ObjectLogicalRole = enum(u8) {
    generic = 0,
    commit = 1,
    tree = 2,
    segment_descriptor = 3,
    wal_index = 4,
    checkpoint_state = 5,
};

const ObjectRefsIndexRecord = struct {
    id: object_store.ObjectId,
    obj_type: object_store.ObjectType,
    role: ObjectLogicalRole,
    children: []object_store.ObjectId,

    fn deinit(self: *ObjectRefsIndexRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.children);
    }
};

const ObjectRefsIndex = struct {
    records: []ObjectRefsIndexRecord,

    fn deinit(self: *ObjectRefsIndex, alloc: std.mem.Allocator) void {
        for (self.records) |*record| record.deinit(alloc);
        alloc.free(self.records);
    }

    fn lookup(self: *const ObjectRefsIndex, id: object_store.ObjectId) ?ObjectRefsIndexRecord {
        var lo: usize = 0;
        var hi: usize = self.records.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const candidate = self.records[mid];
            if (candidate.id.eql(id)) return candidate;
            if (std.mem.lessThan(u8, candidate.id.hash[0..], id.hash[0..])) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }
};

const CommitGraph = struct {
    object_ids: []object_store.ObjectId,
    roots: []object_store.ObjectId,
    created_at_ms: []i64,
    generations: []u32,
    parent_offsets: []u64,
    parent_positions: []u64,
    reason_offsets: []u64,
    reasons: []u8,
    changed_path_bloom_bytes: u16,
    changed_path_blooms: []u8,

    fn deinit(self: *CommitGraph, alloc: std.mem.Allocator) void {
        alloc.free(self.object_ids);
        alloc.free(self.roots);
        alloc.free(self.created_at_ms);
        alloc.free(self.generations);
        alloc.free(self.parent_offsets);
        alloc.free(self.parent_positions);
        alloc.free(self.reason_offsets);
        alloc.free(self.reasons);
        alloc.free(self.changed_path_blooms);
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

    fn changedPathMayMatch(self: *const CommitGraph, id: object_store.ObjectId, path: []const u8) bool {
        const idx = self.lookup(id) orelse return true;
        return self.changedPathMayMatchByIndex(idx, path);
    }

    fn changedPathMayMatchByIndex(self: *const CommitGraph, idx: usize, path: []const u8) bool {
        const bloom = self.changedPathBloom(idx);
        if (bloom.len == 0) return true;
        var seed: u64 = 0x9e3779b97f4a7c15;
        var iter: usize = 0;
        while (iter < 4) : (iter += 1) {
            const hash_value = std.hash.Wyhash.hash(seed, path);
            const bit_count = bloom.len * 8;
            const bit_index: usize = @intCast(hash_value % bit_count);
            if ((bloom[bit_index / 8] & (@as(u8, 1) << @intCast(bit_index % 8))) == 0) return false;
            seed +%= 0x517cc1b727220a95;
        }
        return true;
    }

    fn changedPathBloom(self: *const CommitGraph, idx: usize) []const u8 {
        if (self.changed_path_bloom_bytes == 0) return &.{};
        const width: usize = self.changed_path_bloom_bytes;
        const start = idx * width;
        return self.changed_path_blooms[start .. start + width];
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

const ReachabilityBitmap = struct {
    refs: []RefEntry,
    reachable_ids: []object_store.ObjectId,

    fn deinit(self: *const ReachabilityBitmap, alloc: std.mem.Allocator) void {
        for (self.refs) |*entry| entry.deinit(alloc);
        alloc.free(self.refs);
        alloc.free(self.reachable_ids);
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
    path: []u8,
    store: object_store.ObjectStore,
    refs: RefStore,
    format: RepositoryFormat,
    repository_id: RepositoryIdentity,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, fsync: cfg.FsyncPolicy) !CasManager {
        var store = try object_store.ObjectStore.init(alloc, path, fsync);
        errdefer store.deinit();
        const format = try loadOrInitRepositoryFormat(alloc, store.root, fsync);
        const repository_id = try loadOrInitRepositoryId(store.root, fsync);
        var refs = try RefStore.init(alloc, path, fsync);
        refs.setBackend(format.ref_backend);
        return .{
            .alloc = alloc,
            .path = try alloc.dupe(u8, path),
            .store = store,
            .refs = refs,
            .format = format,
            .repository_id = repository_id,
        };
    }

    pub fn deinit(self: *CasManager) void {
        self.alloc.free(self.path);
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
        try self.ensureHeadSymRef();
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

    pub fn migrateToReftable(self: *CasManager, data_dir: std.fs.Dir) !void {
        _ = try self.fsck(data_dir, .{});
        try self.refs.migrateLooseToReftable();
        self.format.ref_backend = .reftable;
        self.format.version = current_repository_format_version;
        try writeRepositoryFormat(self.alloc, self.store.root, self.format, self.store.fsync);
        self.refs.setBackend(.reftable);
        try self.ensureHeadSymRef();
        try self.refreshCommitGraph();
    }

    pub fn upgradeRepository(self: *CasManager, data_dir: std.fs.Dir) !UpgradeResult {
        const fsck_before = try self.fsck(data_dir, .{});

        var migrated_reftable = false;
        if (self.format.ref_backend != .reftable or self.format.version < current_repository_format_version) {
            try self.refs.migrateLooseToReftable();
            self.refs.setBackend(.reftable);
            self.format.ref_backend = .reftable;
            self.format.version = current_repository_format_version;
            try writeRepositoryFormat(self.alloc, self.store.root, self.format, self.store.fsync);
            migrated_reftable = true;
        }

        try self.ensureHeadSymRef();
        const normalized_commits = try self.normalizeRepository(data_dir, .{});
        _ = try self.repairRepository(data_dir, .{});
        const pack_result = try self.pack();
        const fsck_after = try self.fsck(data_dir, .{});
        return .{
            .migrated_reftable = migrated_reftable,
            .format_version = self.format.version,
            .ref_backend = self.format.ref_backend,
            .reachable_objects = pack_result.reachable_objects,
            .rewritten_objects = pack_result.rewritten_objects,
            .normalized_commits = normalized_commits,
            .compatibility_debt = if (normalized_commits == 0) fsck_before.compatibility_debt else fsck_after.compatibility_debt,
        };
    }

    pub fn readHeadSymRef(self: *CasManager) !?[]u8 {
        return try self.refs.readSymRef("HEAD");
    }

    pub fn writeHeadSymRef(self: *CasManager, target: []const u8) !void {
        try self.refs.writeSymRef("HEAD", target);
    }

    pub fn repairRepository(self: *CasManager, data_dir: std.fs.Dir, options: RepairOptions) !RepairReport {
        _ = data_dir;
        var report = RepairReport{};

        if (options.rebuild_pack_sidecars) {
            report.pack_sidecars_rebuilt = try self.store.repairActivePackMetadata(self.alloc);
        }
        if (options.rebuild_reftable_metadata) {
            const rebuilt = try self.refs.rebuildReftableMetadata();
            report.reftable_state_rebuilt = rebuilt.state_rebuilt;
            report.reftable_tables_list_rebuilt = rebuilt.tables_list_rebuilt;
        }
        if (options.rebuild_side_indexes) {
            try self.refreshCommitGraph();
            report.side_indexes_rebuilt = true;
        }

        return report;
    }

    fn ensureHeadSymRef(self: *CasManager) !void {
        if (try self.refs.readHead(main_ref) == null) return;
        const head_target = try self.refs.readSymRef("HEAD");
        defer if (head_target) |target| self.alloc.free(target);
        if (head_target == null) {
            try self.refs.writeSymRef("HEAD", main_ref);
        }
    }

    pub fn normalizeRepository(self: *CasManager, data_dir: std.fs.Dir, options: NormalizeOptions) !usize {
        _ = options;
        const refs = try self.refs.listRefs(self.alloc);
        defer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }
        if (refs.len == 0) return 0;

        var normalized_map = std.AutoHashMap(object_store.ObjectId, object_store.ObjectId).init(self.alloc);
        defer normalized_map.deinit();
        var rewritten_commits: usize = 0;

        var updates = std.array_list.Managed(RefTxnUpdate).init(self.alloc);
        defer {
            for (updates.items) |update| {
                self.alloc.free(@constCast(update.ref_name));
            }
            updates.deinit();
        }

        for (refs) |entry| {
            const normalized_id = try self.normalizeCommitRecursive(data_dir, entry.id, &normalized_map, &rewritten_commits);
            if (!normalized_id.eql(entry.id)) {
                try updates.append(.{
                    .ref_name = try self.alloc.dupe(u8, entry.name),
                    .expected_old = entry.id,
                    .new_id = normalized_id,
                });
            }
        }

        if (updates.items.len != 0) {
            try self.refs.updateRefTxn(updates.items, "normalize-repository");
            try self.ensureHeadSymRef();
            try self.refreshCommitGraph();
        }
        return rewritten_commits;
    }

    pub fn expire(self: *CasManager, data_dir: std.fs.Dir, policy: MaintenancePolicy) !ExpiryReport {
        _ = data_dir;
        var report = ExpiryReport{};
        const now_ms = std.time.milliTimestamp();

        if (policy.materialize_borrowed_packs) {
            report.borrowed_packs_materialized = try self.materializeBorrowedObjects();
        }
        report.reflog_entries_expired = try self.refs.expireReflogEntries(now_ms - policy.reflog_expiry_ms);
        report.checkpoint_refs_expired = try self.expireCheckpointRefs(now_ms - policy.checkpoint_expiry_ms);

        if (report.borrowed_packs_materialized != 0 or report.reflog_entries_expired != 0 or report.checkpoint_refs_expired != 0) {
            try self.refreshCommitGraph();
        }
        return report;
    }

    pub fn prune(self: *CasManager, options: PruneOptions) !PruneResult {
        const now_ms = std.time.milliTimestamp();
        var prunable = try scanExpiredCruft(self.alloc, self.store.root, now_ms, options.grace_period_ms);
        defer prunable.deinit(self.alloc);

        var pruned_count: usize = 0;
        var pruned_bytes: u64 = 0;
        for (prunable.entries) |entry| {
            pruned_count += entry.file_count;
            pruned_bytes += entry.bytes;
            if (!options.dry_run) {
                try self.store.root.deleteTree(entry.path);
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
            .pruned_count = pruned_count,
            .pruned_bytes = pruned_bytes,
            .stale_segment_files = stale_segment_files,
            .stale_segment_bytes = stale_segment_bytes,
            .stale_wal_files = stale_wal_files,
            .stale_wal_bytes = stale_wal_bytes,
            .mirror_deleted = mirror_deleted,
        };
    }

    pub fn vacuum(self: *CasManager, data_dir: std.fs.Dir) !VacuumResult {
        return try self.vacuumWithPolicy(data_dir, .{});
    }

    pub fn vacuumWithPolicy(self: *CasManager, data_dir: std.fs.Dir, policy: MaintenancePolicy) !VacuumResult {
        const fsck_report = try self.fsck(data_dir, .{});
        const repair_report = if (policy.repair_side_indexes)
            try self.repairRepository(data_dir, .{})
        else
            RepairReport{};
        const expiry_report = try self.expire(data_dir, policy);
        const pack_result = try self.pack();
        const gc_result = try self.gc(.{
            .dry_run = false,
            .grace_period_ms = policy.prune_grace_ms,
        });
        return .{
            .fsck = fsck_report,
            .repair = repair_report,
            .expiry = expiry_report,
            .pack = pack_result,
            .gc = gc_result,
        };
    }

    fn materializeBorrowedObjects(self: *CasManager) !usize {
        const borrowed_count = self.store.alternates.repo_paths.len;
        if (borrowed_count == 0) return 0;

        const refs = try self.refs.listRefs(self.alloc);
        defer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }
        var reachable = try self.collectReachable(refs);
        defer reachable.deinit();

        var it = reachable.keyIterator();
        while (it.next()) |id_ptr| {
            if (try self.store.hasLocalObject(self.alloc, id_ptr.*)) continue;
            const loaded = try self.store.get(self.alloc, id_ptr.*);
            defer self.alloc.free(loaded.payload);
            const written = try self.store.put(loaded.obj_type, loaded.payload);
            if (!written.eql(id_ptr.*)) return error.ObjectHashMismatch;
        }

        try self.store.configureAlternates(self.alloc, &[_][]const u8{});
        return borrowed_count;
    }

    fn expireCheckpointRefs(self: *CasManager, cutoff_ms: i64) !usize {
        const refs = try self.refs.listRefs(self.alloc);
        defer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }

        var expired: usize = 0;
        for (refs) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "checkpoints/")) continue;
            const created_at_ms = parseCheckpointRefTimestamp(entry.name) orelse continue;
            if (created_at_ms >= cutoff_ms) continue;
            try self.refs.deleteRef(entry.name, "expire-checkpoint");
            expired += 1;
        }
        return expired;
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

    pub fn deleteRef(self: *CasManager, ref_name: []const u8) !void {
        try self.refs.deleteRef(ref_name, "delete-ref");
        try self.refreshCommitGraph();
    }

    pub fn renameRef(self: *CasManager, old_ref_name: []const u8, new_ref_name: []const u8) !void {
        try self.refs.renameRef(old_ref_name, new_ref_name, "rename-ref");
        try self.refreshCommitGraph();
    }

    pub fn loadReflog(self: *CasManager, ref_name: []const u8, max_entries: usize) ![]ReflogEntry {
        return try self.refs.loadReflog(self.alloc, ref_name, max_entries);
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
        var unreachable_loose_ids = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer unreachable_loose_ids.deinit();

        var unreachable_bytes: u64 = 0;
        for (all) |id| {
            if (reachable.contains(id)) continue;
            try unreachable_ids.append(id);
            if (try self.store.hasLooseObject(id)) {
                try unreachable_loose_ids.append(id);
            }
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

            if (unreachable_loose_ids.items.len > 0) {
                var cruft_pack = try self.store.writeCruftPack(self.alloc, unreachable_loose_ids.items, stamp_ms);
                defer cruft_pack.deinit(self.alloc);
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
        try self.store.verifyActivePackMetadata(self.alloc);

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

        if (loadReachabilityBitmap(self.alloc, self.store.root)) |bitmap| {
            defer bitmap.deinit(self.alloc);
            if (!refEntriesEql(bitmap.refs, inputs.refs)) return error.CorruptReachabilityBitmap;
            if (bitmap.reachable_ids.len != direct_reachable.count()) return error.CorruptReachabilityBitmap;
            for (bitmap.reachable_ids) |id| {
                if (!direct_reachable.contains(id)) return error.CorruptReachabilityBitmap;
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        var refs_index = loadObjectRefsIndex(self.alloc, self.store.root) catch |err| switch (err) {
            error.FileNotFound, error.CorruptObjectRefsIndex, error.UnsupportedObjectRefsIndexVersion => null,
            else => return err,
        };
        defer if (refs_index) |*index| index.deinit(self.alloc);

        var it = direct_reachable.keyIterator();
        while (it.next()) |id_ptr| {
            const loaded = try self.store.get(self.alloc, id_ptr.*);
            defer self.alloc.free(loaded.payload);
            switch (loaded.obj_type) {
                .commit => report.commit_objects += 1,
                .tree => report.tree_objects += 1,
                .blob => {
                    report.blob_objects += 1;
                    if (refs_index) |index| {
                        if (index.lookup(id_ptr.*)) |record| {
                            switch (record.role) {
                                .segment_descriptor => {
                                    var descriptor = try decodeSegmentDescriptor(self.alloc, loaded.payload);
                                    defer descriptor.deinit(self.alloc);
                                    if (descriptor.segmentRoot() == null) report.compatibility_debt.legacy_segment_descriptors += 1;
                                },
                                .wal_index => {
                                    var wal_index = try decodeWalIndex(self.alloc, loaded.payload);
                                    defer wal_index.deinit(self.alloc);
                                    for (wal_index.entries) |entry| {
                                        if (entry.journalRoot() == null) report.compatibility_debt.legacy_wal_descriptors += 1;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                },
                else => return error.UnsupportedCasObjectType,
            }
        }

        if (self.format.version >= current_repository_format_version and self.format.ref_backend == .reftable) {
            const loose_refs = try self.refs.listLooseRefs(self.alloc);
            defer {
                for (loose_refs) |*entry| entry.deinit(self.alloc);
                self.alloc.free(loose_refs);
            }
            report.compatibility_debt.loose_refs_present = loose_refs.len;
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
                if (graph.changed_path_bloom_bytes > 0) {
                    const expected_bloom = try self.alloc.alloc(u8, graph.changed_path_bloom_bytes);
                    defer self.alloc.free(expected_bloom);
                    @memset(expected_bloom, 0);
                    if (commit.parents.len == 0) {
                        try collectChangedPathsForTree(self.alloc, &self.store, commit.root, "", expected_bloom);
                    } else {
                        const first_parent_pos: usize = @intCast(graph.parent_positions[parent_start]);
                        try diffChangedPathsForTrees(
                            self.alloc,
                            &self.store,
                            graph.roots[first_parent_pos],
                            commit.root,
                            "",
                            expected_bloom,
                        );
                    }
                    if (!std.mem.eql(u8, expected_bloom, graph.changedPathBloom(idx))) return error.CorruptCommitGraph;
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
                if (descriptor.contentRef() != null or descriptor.segmentRoot() != null or descriptor.mirrorPath().len != 0) {
                    try segment_mod.validateDescriptorContent(self.alloc, data_dir, &self.store, descriptor);
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
                        .blob => |content_id| try wal_mod.replayBlobObject(self.alloc, &self.store, content_id, &noop_ctx),
                        .extent_tree => |tree| try wal_mod.replayExtentTree(self.alloc, &self.store, tree, &noop_ctx),
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

        const reflog_report = try self.refs.validateReflogs(self.alloc, inputs.refs);
        report.reflog_files_checked = reflog_report.checked;
        report.stale_reflog_files = reflog_report.stale;

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
            if (try self.store.hasLooseObject(id_ptr.*)) {
                try ids.append(id_ptr.*);
            }
        }

        var rewritten_objects: usize = 0;
        if (ids.items.len > 0) {
            var pack_write = try self.store.writePack(self.alloc, ids.items);
            defer pack_write.deinit(self.alloc);
            rewritten_objects = pack_write.object_count;
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

        var starts = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer starts.deinit();
        for (refs) |entry| try starts.append(entry.id);
        var reachable = try self.collectReachableFromIds(starts.items);
        defer reachable.deinit();
        const reachable_ids = try reachableMapToSortedIds(self.alloc, &reachable);
        defer self.alloc.free(reachable_ids);
        try writeReachabilityBitmap(self.alloc, self.store.root, refs, reachable_ids, self.store.fsync);

        var refs_index = try buildObjectRefsIndex(self.alloc, &self.store);
        defer refs_index.deinit(self.alloc);
        try writeObjectRefsIndex(self.alloc, self.store.root, refs_index, self.store.fsync);
    }

    fn collectReachabilityInputs(self: *CasManager, include_reflogs: bool) !ReachabilityInputs {
        const refs = try self.refs.listRefs(self.alloc);
        errdefer {
            for (refs) |*entry| entry.deinit(self.alloc);
            self.alloc.free(refs);
        }

        const reflog_ids = if (include_reflogs)
            try self.refs.collectReflogObjectIds(self.alloc)
        else
            try self.alloc.alloc(object_store.ObjectId, 0);
        errdefer self.alloc.free(reflog_ids);

        return .{
            .refs = refs,
            .reflog_ids = reflog_ids,
        };
    }

    fn collectReachableFromInputs(self: *CasManager, inputs: ReachabilityInputs) !std.AutoHashMap(object_store.ObjectId, void) {
        if (inputs.reflog_ids.len == 0) {
            return try self.collectReachable(inputs.refs);
        }
        var starts = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer starts.deinit();
        for (inputs.refs) |entry| try starts.append(entry.id);
        try starts.appendSlice(inputs.reflog_ids);
        return try self.collectReachableFromIds(starts.items);
    }

    fn collectReachable(self: *CasManager, refs: []const RefEntry) !std.AutoHashMap(object_store.ObjectId, void) {
        if (loadReachabilityBitmap(self.alloc, self.store.root)) |bitmap| {
            defer bitmap.deinit(self.alloc);
            if (refEntriesEql(bitmap.refs, refs)) {
                var reachable = std.AutoHashMap(object_store.ObjectId, void).init(self.alloc);
                errdefer reachable.deinit();
                for (bitmap.reachable_ids) |id| try reachable.put(id, {});
                return reachable;
            }
        } else |err| switch (err) {
            error.FileNotFound, error.CorruptReachabilityBitmap, error.UnsupportedReachabilityBitmapVersion => {},
            else => return err,
        }

        var starts = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer starts.deinit();
        for (refs) |entry| try starts.append(entry.id);
        var reachable = try self.collectReachableFromIds(starts.items);
        errdefer reachable.deinit();
        const reachable_ids = try reachableMapToSortedIds(self.alloc, &reachable);
        defer self.alloc.free(reachable_ids);
        try writeReachabilityBitmap(self.alloc, self.store.root, refs, reachable_ids, self.store.fsync);
        return reachable;
    }

    fn collectReachableFromIds(self: *CasManager, starts: []const object_store.ObjectId) !std.AutoHashMap(object_store.ObjectId, void) {
        var seen = std.AutoHashMap(object_store.ObjectId, void).init(self.alloc);
        errdefer seen.deinit();

        var stack = std.array_list.Managed(object_store.ObjectId).init(self.alloc);
        defer stack.deinit();

        var refs_index = loadObjectRefsIndex(self.alloc, self.store.root) catch |err| switch (err) {
            error.FileNotFound, error.CorruptObjectRefsIndex, error.UnsupportedObjectRefsIndexVersion => null,
            else => return err,
        };
        defer if (refs_index) |*index| index.deinit(self.alloc);

        for (starts) |id| {
            try stack.append(id);
        }

        while (stack.pop()) |id| {
            const gop = try seen.getOrPut(id);
            if (gop.found_existing) continue;

            if (refs_index) |index| {
                if (index.lookup(id)) |record| {
                    for (record.children) |child| {
                        try stack.append(child);
                    }
                    continue;
                }
            }

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

    fn normalizeCommitRecursive(
        self: *CasManager,
        data_dir: std.fs.Dir,
        commit_id: object_store.ObjectId,
        normalized_map: *std.AutoHashMap(object_store.ObjectId, object_store.ObjectId),
        rewritten_commits: *usize,
    ) !object_store.ObjectId {
        if (normalized_map.get(commit_id)) |existing| return existing;

        const loaded = try self.store.get(self.alloc, commit_id);
        defer self.alloc.free(loaded.payload);
        if (loaded.obj_type != .commit) return error.InvalidCommitObject;
        var commit = try decodeCommit(self.alloc, loaded.payload);
        defer commit.deinit(self.alloc);

        var normalized_parents = try self.alloc.alloc(object_store.ObjectId, commit.parents.len);
        defer self.alloc.free(normalized_parents);
        var parents_changed = false;
        for (commit.parents, 0..) |parent, idx| {
            normalized_parents[idx] = try self.normalizeCommitRecursive(data_dir, parent, normalized_map, rewritten_commits);
            if (!normalized_parents[idx].eql(parent)) parents_changed = true;
        }

        var reader = CommitReader{ .alloc = self.alloc, .store = &self.store, .refs = &self.refs };
        var snapshot = try reader.loadSnapshot(commit_id);
        defer snapshot.deinit(self.alloc);

        var canonical = try self.canonicalizeSnapshot(data_dir, snapshot);
        defer canonical.snapshot.deinit(self.alloc);

        const changed = parents_changed or canonical.changed;
        if (!changed) {
            try normalized_map.put(commit_id, commit_id);
            return commit_id;
        }

        var writer = CommitWriter{ .alloc = self.alloc, .store = &self.store, .extent_chunk_bytes = self.format.extent_chunk_bytes };
        const normalized_id = try writer.writeCanonicalSnapshot(&canonical.snapshot, normalized_parents, commit.created_at_ms, commit.reason);
        try normalized_map.put(commit_id, normalized_id);
        rewritten_commits.* += 1;
        return normalized_id;
    }

    fn canonicalizeSnapshot(
        self: *CasManager,
        data_dir: std.fs.Dir,
        snapshot: Snapshot,
    ) !struct {
        snapshot: LegacySnapshot,
        changed: bool,
    } {
        var changed = false;

        const descriptors = try self.alloc.alloc(SegmentDescriptor, snapshot.segment_descriptors.len);
        errdefer {
            for (descriptors[0..]) |*descriptor| {
                if (descriptor.path.len != 0) descriptor.deinit(self.alloc);
            }
            self.alloc.free(descriptors);
        }
        for (snapshot.segment_descriptors, 0..) |descriptor, idx| {
            var next = try cloneSegmentDescriptor(self.alloc, descriptor);
            if (next.segmentRoot() == null) {
                next.segment_root = try self.canonicalSegmentRoot(data_dir, descriptor);
                changed = true;
            }
            descriptors[idx] = next;
        }

        var tag_snapshot = try cloneTagSnapshot(self.alloc, snapshot.tag_snapshot);
        errdefer tag_snapshot.deinit(self.alloc);
        var series_catalog_snapshot = try cloneSeriesCatalogSnapshot(self.alloc, snapshot.series_catalog_snapshot);
        errdefer series_catalog_snapshot.deinit(self.alloc);

        const wal_entries = try self.alloc.alloc(WalChunkDescriptor, snapshot.wal_index.entries.len);
        errdefer {
            for (wal_entries[0..]) |*entry| {
                if (entry.name.len != 0) entry.deinit(self.alloc);
            }
            self.alloc.free(wal_entries);
        }
        for (snapshot.wal_index.entries, 0..) |entry, idx| {
            var next = try cloneWalChunkDescriptor(self.alloc, entry);
            if (next.journalRoot() == null) {
                next.journal_root = try self.canonicalJournalRoot(data_dir, entry);
                changed = true;
            }
            wal_entries[idx] = next;
        }

        var wal_index = WalIndex{ .entries = wal_entries };
        errdefer wal_index.deinit(self.alloc);
        var checkpoint_state = try buildCheckpointState(self.alloc, descriptors, wal_index.entries);
        errdefer checkpoint_state.deinit(self.alloc);
        if (!checkpointStatesEql(checkpoint_state, snapshot.checkpoint_state)) changed = true;

        return .{
            .snapshot = .{
                .segment_descriptors = descriptors,
                .tag_snapshot = tag_snapshot,
                .series_catalog_snapshot = series_catalog_snapshot,
                .wal_index = wal_index,
                .checkpoint_state = checkpoint_state,
            },
            .changed = changed,
        };
    }

    fn canonicalSegmentRoot(self: *CasManager, data_dir: std.fs.Dir, descriptor: SegmentDescriptor) !object_store.ObjectId {
        if (descriptor.segmentRoot()) |root_id| return root_id;
        if (descriptor.mirrorPath().len != 0 and pathExists(data_dir, descriptor.mirrorPath()) catch false) {
            return try segment_mod.writeSegmentRootForFile(self.alloc, data_dir, &self.store, descriptor.mirrorPath(), self.format.extent_chunk_bytes);
        }
        const points = try segment_mod.readAllDescriptor(self.alloc, data_dir, &self.store, descriptor);
        defer self.alloc.free(points);
        return try segment_mod.writeSegmentRoot(self.alloc, &self.store, .{
            .series_id = descriptor.series_id,
            .hour_bucket = descriptor.hour_bucket,
            .ts_codec = descriptor.ts_codec,
            .val_codec = descriptor.val_codec,
            .selector = null,
        }, points, self.format.extent_chunk_bytes);
    }

    fn canonicalJournalRoot(self: *CasManager, data_dir: std.fs.Dir, entry: WalChunkDescriptor) !object_store.ObjectId {
        if (entry.journalRoot()) |root_id| return root_id;
        if (entry.mirrorName().len != 0) {
            const path = try std.fmt.allocPrint(self.alloc, "wal/{s}", .{entry.mirrorName()});
            defer self.alloc.free(path);
            if (pathExists(data_dir, path) catch false) {
                return try wal_mod.writeJournalRootForWalFile(self.alloc, data_dir, &self.store, entry.mirrorName());
            }
        }
        if (entry.contentRef()) |content| {
            const bytes = try readContentRefBytes(self.alloc, &self.store, content);
            defer self.alloc.free(bytes);
            return try wal_mod.writeJournalRootFromBytes(self.alloc, &self.store, bytes);
        }
        return error.MissingWalContentId;
    }
};

fn refEntriesEql(lhs: []const RefEntry, rhs: []const RefEntry) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_entry, rhs_entry| {
        if (!std.mem.eql(u8, lhs_entry.name, rhs_entry.name)) return false;
        if (!lhs_entry.id.eql(rhs_entry.id)) return false;
    }
    return true;
}

fn reachableMapToSortedIds(
    alloc: std.mem.Allocator,
    reachable: *const std.AutoHashMap(object_store.ObjectId, void),
) ![]object_store.ObjectId {
    const ids = try alloc.alloc(object_store.ObjectId, reachable.count());
    var idx: usize = 0;
    var it = reachable.keyIterator();
    while (it.next()) |id_ptr| {
        ids[idx] = id_ptr.*;
        idx += 1;
    }
    std.sort.block(object_store.ObjectId, ids, {}, struct {
        fn lessThan(_: void, lhs: object_store.ObjectId, rhs: object_store.ObjectId) bool {
            return std.mem.lessThan(u8, lhs.hash[0..], rhs.hash[0..]);
        }
    }.lessThan);
    return ids;
}

fn appendReferencedBlobObjects(
    stack: *std.array_list.Managed(object_store.ObjectId),
    payload: []const u8,
) !void {
    if (appendSegmentDescriptorBlob(stack, payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    }) return;
    if (appendCheckpointStateBlob(stack, payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    }) return;
    _ = appendWalIndexBlob(stack, payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
}

fn buildObjectRefsIndex(alloc: std.mem.Allocator, store: *object_store.ObjectStore) !ObjectRefsIndex {
    const ids = try store.listIds(alloc);
    defer alloc.free(ids);

    var records = std.array_list.Managed(ObjectRefsIndexRecord).init(alloc);
    errdefer {
        for (records.items) |*record| record.deinit(alloc);
        records.deinit();
    }

    for (ids) |id| {
        const loaded = try store.get(alloc, id);
        defer alloc.free(loaded.payload);

        var children = std.array_list.Managed(object_store.ObjectId).init(alloc);
        defer children.deinit();
        var role: ObjectLogicalRole = .generic;

        switch (loaded.obj_type) {
            .commit => {
                role = .commit;
                var commit = try decodeCommit(alloc, loaded.payload);
                defer commit.deinit(alloc);
                try children.append(commit.root);
                try children.appendSlice(commit.parents);
            },
            .tree => {
                role = .tree;
                var tree = try decodeTree(alloc, loaded.payload);
                defer tree.deinit(alloc);
                for (tree.entries) |entry| try children.append(entry.object_id);
            },
            .blob => {
                if (appendSegmentDescriptorBlob(&children, loaded.payload) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => false,
                }) {
                    role = .segment_descriptor;
                } else if (appendCheckpointStateBlob(&children, loaded.payload) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => false,
                }) {
                    role = .checkpoint_state;
                } else if (appendWalIndexBlob(&children, loaded.payload) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => false,
                }) {
                    role = .wal_index;
                }
            },
            .ref => {},
        }

        try records.append(.{
            .id = id,
            .obj_type = loaded.obj_type,
            .role = role,
            .children = try children.toOwnedSlice(),
        });
    }

    std.sort.block(ObjectRefsIndexRecord, records.items, {}, struct {
        fn lessThan(_: void, lhs: ObjectRefsIndexRecord, rhs: ObjectRefsIndexRecord) bool {
            return std.mem.lessThan(u8, lhs.id.hash[0..], rhs.id.hash[0..]);
        }
    }.lessThan);

    return .{ .records = try records.toOwnedSlice() };
}

fn writeObjectRefsIndex(alloc: std.mem.Allocator, root: std.fs.Dir, index: ObjectRefsIndex, fsync: cfg.FsyncPolicy) !void {
    const bytes = try encodeObjectRefsIndex(alloc, index);
    defer alloc.free(bytes);

    const temp_path = object_refs_index_path ++ ".tmp";
    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};
    try file.writeAll(bytes);
    if (fsync != .none) try file.sync();
    root.rename(temp_path, object_refs_index_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(object_refs_index_path) catch {};
            try root.rename(temp_path, object_refs_index_path);
        },
        else => return err,
    };
}

fn loadObjectRefsIndex(alloc: std.mem.Allocator, root: std.fs.Dir) !ObjectRefsIndex {
    const bytes = try root.readFileAlloc(alloc, object_refs_index_path, 512 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < object_refs_magic.len + @sizeOf(u16) + @sizeOf(u64) + 32) return error.CorruptObjectRefsIndex;
    if (!std.mem.eql(u8, bytes[0..object_refs_magic.len], object_refs_magic[0..])) return error.CorruptObjectRefsIndex;

    const checksum_start = bytes.len - 32;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes[0..checksum_start]);
    var expected_checksum: [32]u8 = undefined;
    hasher.final(expected_checksum[0..]);
    if (!std.mem.eql(u8, expected_checksum[0..], bytes[checksum_start..])) return error.CorruptObjectRefsIndex;

    var cursor = Cursor{ .bytes = bytes[object_refs_magic.len..checksum_start] };
    const version = try cursor.readInt(u16);
    if (version != 1) return error.UnsupportedObjectRefsIndexVersion;
    const record_count = try cursor.readInt(u64);
    var records = try alloc.alloc(ObjectRefsIndexRecord, @intCast(record_count));
    var loaded_records: usize = 0;
    errdefer {
        for (records[0..loaded_records]) |*record| record.deinit(alloc);
        alloc.free(records);
    }
    for (records) |*record| {
        const id = object_store.ObjectId{ .hash = try cursor.readHash() };
        const obj_type = std.meta.intToEnum(object_store.ObjectType, try cursor.readByte()) catch return error.CorruptObjectRefsIndex;
        const role = std.meta.intToEnum(ObjectLogicalRole, try cursor.readByte()) catch return error.CorruptObjectRefsIndex;
        const child_count = try cursor.readInt(u32);
        const children = try alloc.alloc(object_store.ObjectId, child_count);
        for (children) |*child| child.* = .{ .hash = try cursor.readHash() };
        record.* = .{
            .id = id,
            .obj_type = obj_type,
            .role = role,
            .children = children,
        };
        loaded_records += 1;
    }
    try cursor.finish();
    return .{ .records = records };
}

fn encodeObjectRefsIndex(alloc: std.mem.Allocator, index: ObjectRefsIndex) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.appendSlice(object_refs_magic[0..]);
    try appendInt(&bytes, u16, 1);
    try appendInt(&bytes, u64, @intCast(index.records.len));
    for (index.records) |record| {
        try bytes.appendSlice(record.id.hash[0..]);
        try bytes.append(@intFromEnum(record.obj_type));
        try bytes.append(@intFromEnum(record.role));
        try appendInt(&bytes, u32, @intCast(record.children.len));
        for (record.children) |child| try bytes.appendSlice(child.hash[0..]);
    }

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes.items);
    var checksum: [32]u8 = undefined;
    hasher.final(checksum[0..]);
    try bytes.appendSlice(checksum[0..]);
    return try bytes.toOwnedSlice();
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
    if (version != 1 and version != 2 and version != 3 and version != 4 and version != 5) return false;

    var segment_root: ?object_store.ObjectId = null;
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
        5 => {
            if (idx >= payload.len) return false;
            const flag = payload[idx];
            idx += 1;
            switch (flag) {
                0 => {},
                1 => segment_root = .{ .hash = try readHashAt(payload, &idx) },
                else => return false,
            }

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

    if (segment_root) |id| try stack.append(id);
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
    if (version != 1 and version != 2 and version != 3 and version != 4 and version != 5) return false;

    const entry_count = try readIntAt(payload, &idx, u32);
    var entry_idx: u32 = 0;
    while (entry_idx < entry_count) : (entry_idx += 1) {
        _ = try readStringAt(payload, &idx);

        if (version == 5) {
            if (idx >= payload.len) return false;
            const flag = payload[idx];
            idx += 1;
            switch (flag) {
                0 => {},
                1 => try stack.append(.{ .hash = try readHashAt(payload, &idx) }),
                else => return false,
            }
        }

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
            4, 5 => {
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

fn appendCheckpointStateBlob(
    stack: *std.array_list.Managed(object_store.ObjectId),
    payload: []const u8,
) !bool {
    const original_len = stack.items.len;
    errdefer stack.items.len = original_len;

    if (payload.len == 0) return false;

    var idx: usize = 0;
    const version = payload[idx];
    idx += 1;
    if (version != 1) return false;

    const highwater_count = try readIntAt(payload, &idx, u32);
    var highwater_idx: u32 = 0;
    while (highwater_idx < highwater_count) : (highwater_idx += 1) {
        _ = try readIntAt(payload, &idx, u64);
        _ = try readIntAt(payload, &idx, i64);
    }

    const wal_entry_count = try readIntAt(payload, &idx, u32);
    var wal_idx: u32 = 0;
    while (wal_idx < wal_entry_count) : (wal_idx += 1) {
        _ = try readStringAt(payload, &idx);
        if (idx >= payload.len) return false;
        const flag = payload[idx];
        idx += 1;
        switch (flag) {
            0 => {},
            1 => try stack.append(.{ .hash = try readHashAt(payload, &idx) }),
            else => return false,
        }
        if (idx >= payload.len) return false;
        idx += 1; // mutable
        _ = try readIntAt(payload, &idx, u64);
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

pub const PackDigest = struct {
    pack_path: []u8,
    pack_checksum: [32]u8,
    object_count: u64,

    fn deinit(self: *PackDigest, alloc: std.mem.Allocator) void {
        alloc.free(self.pack_path);
    }
};

const BundleManifest = struct {
    format_version: u16,
    repository_format_version: u16 = legacy_repository_format_version,
    ref_backend: RefBackend = .loose,
    repository_id: RepositoryIdentity = .{ .bytes = [_]u8{0} ** 32 },
    incremental: bool,
    refs: []BundleRef,
    prerequisites: []object_store.ObjectId,
    prerequisite_refs: []BundleRef,
    object_count: usize,
    pack_files: [][]u8,
    pack_digests: []PackDigest,
    info_files: [][]u8,
    reftable_files: [][]u8,
    loose_ref_files: [][]u8,
    reflog_files: [][]u8,
    symref_files: [][]u8,
    borrowed_repo_paths: [][]u8,

    fn deinit(self: *BundleManifest, alloc: std.mem.Allocator) void {
        for (self.refs) |*entry| entry.deinit(alloc);
        alloc.free(self.refs);
        alloc.free(self.prerequisites);
        for (self.prerequisite_refs) |*entry| entry.deinit(alloc);
        alloc.free(self.prerequisite_refs);
        freeOwnedStrings(alloc, self.pack_files);
        for (self.pack_digests) |*entry| entry.deinit(alloc);
        alloc.free(self.pack_digests);
        freeOwnedStrings(alloc, self.info_files);
        freeOwnedStrings(alloc, self.reftable_files);
        freeOwnedStrings(alloc, self.loose_ref_files);
        freeOwnedStrings(alloc, self.reflog_files);
        freeOwnedStrings(alloc, self.symref_files);
        freeOwnedStrings(alloc, self.borrowed_repo_paths);
    }
};

pub const BundleResult = struct {
    ref_count: usize,
    prerequisite_count: usize,
    object_count: usize,
    pack_count: usize = 0,
    reftable_file_count: usize = 0,
};

pub const CompatibilityDebtReport = struct {
    legacy_segment_descriptors: usize = 0,
    legacy_wal_descriptors: usize = 0,
    loose_refs_present: usize = 0,
};

pub const NormalizeOptions = struct {
    normalize_active_refs: bool = true,
};

pub const UpgradeResult = struct {
    migrated_reftable: bool,
    format_version: u16,
    ref_backend: RefBackend,
    reachable_objects: usize,
    rewritten_objects: usize,
    normalized_commits: usize = 0,
    compatibility_debt: CompatibilityDebtReport = .{},
};

pub const VacuumResult = struct {
    fsck: FsckReport,
    repair: RepairReport,
    expiry: ExpiryReport,
    pack: PackResult,
    gc: GcResult,
};

pub const RepairOptions = struct {
    rebuild_side_indexes: bool = true,
    rebuild_pack_sidecars: bool = true,
    rebuild_reftable_metadata: bool = true,
};

pub const RepairReport = struct {
    pack_sidecars_rebuilt: usize = 0,
    side_indexes_rebuilt: bool = false,
    reftable_state_rebuilt: bool = false,
    reftable_tables_list_rebuilt: bool = false,
};

pub const MaintenancePolicy = struct {
    repair_side_indexes: bool = false,
    reflog_expiry_ms: i64 = 7 * 24 * 60 * 60 * 1000,
    checkpoint_expiry_ms: i64 = 7 * 24 * 60 * 60 * 1000,
    prune_grace_ms: i64 = 24 * 60 * 60 * 1000,
    materialize_borrowed_packs: bool = false,
};

pub const ExpiryReport = struct {
    reflog_entries_expired: usize = 0,
    checkpoint_refs_expired: usize = 0,
    borrowed_packs_materialized: usize = 0,
};

pub const LocalExchangeResult = struct {
    repository_id: RepositoryIdentity,
    ref_count: usize,
    borrowed_repositories: usize,
};

pub const LocalFetchOptions = struct {
    materialize: bool = false,
};

pub const LocalPushOptions = struct {
    borrow: bool = false,
};

pub const LocalCloneOptions = struct {
    borrow: bool = false,
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

fn cloneBundleRefsSlice(alloc: std.mem.Allocator, refs: []const BundleRef) ![]BundleRef {
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

fn clonePackDigests(alloc: std.mem.Allocator, digests: []const PackDigest) ![]PackDigest {
    const cloned = try alloc.alloc(PackDigest, digests.len);
    errdefer {
        for (cloned[0..]) |*entry| {
            if (entry.pack_path.len != 0) entry.deinit(alloc);
        }
        alloc.free(cloned);
    }
    for (cloned) |*entry| entry.* = .{ .pack_path = &[_]u8{}, .pack_checksum = [_]u8{0} ** 32, .object_count = 0 };
    for (digests, 0..) |digest, idx| {
        cloned[idx] = .{
            .pack_path = try alloc.dupe(u8, digest.pack_path),
            .pack_checksum = digest.pack_checksum,
            .object_count = digest.object_count,
        };
    }
    return cloned;
}

fn findPackDigest(digests: []const object_store.PackInventoryRecord, pack_path: []const u8) ?object_store.PackInventoryRecord {
    for (digests) |digest| {
        if (std.mem.eql(u8, digest.pack_path, pack_path)) return digest;
    }
    return null;
}

fn findBundlePackDigest(digests: []const PackDigest, pack_path: []const u8) ?PackDigest {
    for (digests) |digest| {
        if (std.mem.eql(u8, digest.pack_path, pack_path)) return digest;
    }
    return null;
}

fn cloneOwnedStringsSlice(alloc: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const cloned = try alloc.alloc([]u8, values.len);
    errdefer {
        for (cloned[0..]) |value| {
            if (value.len != 0) alloc.free(value);
        }
        alloc.free(cloned);
    }
    for (cloned) |*entry| entry.* = &[_]u8{};
    for (values, 0..) |value, idx| {
        cloned[idx] = try alloc.dupe(u8, value);
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
    if (manifest.format_version >= 2) {
        try writer.print("repository_format_version {d}\n", .{manifest.repository_format_version});
        try writer.print("ref_backend {d}\n", .{@intFromEnum(manifest.ref_backend)});
    }
    if (manifest.format_version >= 3) {
        const repo_hex = manifest.repository_id.toHex();
        try writer.print("repository_id {s}\n", .{repo_hex});
    }
    try writer.print("incremental {d}\n", .{@intFromBool(manifest.incremental)});
    try writer.print("object_count {d}\n", .{manifest.object_count});
    if (manifest.format_version >= 2) {
        try writer.print("packs {d}\n", .{manifest.pack_files.len});
        for (manifest.pack_files) |path| try writer.print("{s}\n", .{path});
        if (manifest.format_version >= 4) {
            try writer.print("pack_digests {d}\n", .{manifest.pack_digests.len});
            for (manifest.pack_digests) |digest| {
                const checksum_hex = std.fmt.bytesToHex(digest.pack_checksum, .lower);
                try writer.print("{s} {s} {d}\n", .{ digest.pack_path, checksum_hex, digest.object_count });
            }
        }
        try writer.print("info_files {d}\n", .{manifest.info_files.len});
        for (manifest.info_files) |path| try writer.print("{s}\n", .{path});
        try writer.print("reftable_files {d}\n", .{manifest.reftable_files.len});
        for (manifest.reftable_files) |path| try writer.print("{s}\n", .{path});
        try writer.print("loose_ref_files {d}\n", .{manifest.loose_ref_files.len});
        for (manifest.loose_ref_files) |path| try writer.print("{s}\n", .{path});
        try writer.print("reflog_files {d}\n", .{manifest.reflog_files.len});
        for (manifest.reflog_files) |path| try writer.print("{s}\n", .{path});
        if (manifest.format_version >= 4) {
            try writer.print("symref_files {d}\n", .{manifest.symref_files.len});
            for (manifest.symref_files) |path| try writer.print("{s}\n", .{path});
        }
        if (manifest.format_version >= 3) {
            try writer.print("borrowed_repositories {d}\n", .{manifest.borrowed_repo_paths.len});
            for (manifest.borrowed_repo_paths) |path| try writer.print("{s}\n", .{path});
        }
    }
    try writer.print("prerequisites {d}\n", .{manifest.prerequisites.len});
    for (manifest.prerequisites) |prerequisite| {
        const hex = prerequisite.toHex();
        try writer.print("{s}\n", .{hex});
    }
    if (manifest.format_version >= 4) {
        try writer.print("prerequisite_refs {d}\n", .{manifest.prerequisite_refs.len});
        for (manifest.prerequisite_refs) |entry| {
            const hex = entry.id.toHex();
            try writer.print("{s} {s}\n", .{ entry.name, hex });
        }
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
    if (format_version != 1 and format_version != 2 and format_version != 3 and format_version != 4) return error.UnsupportedBundleFormatVersion;
    const repository_format_version = if (format_version >= 2)
        try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "repository_format_version")
    else
        legacy_repository_format_version;
    const ref_backend = if (format_version >= 2)
        std.meta.intToEnum(RefBackend, @as(u8, @intCast(try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "ref_backend")))) catch return error.InvalidBundle
    else
        RefBackend.loose;
    const repository_id = if (format_version >= 3)
        try parseBundleRepositoryId(line_it.next() orelse return error.InvalidBundle)
    else
        RepositoryIdentity{ .bytes = [_]u8{0} ** 32 };
    const incremental_value = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "incremental");
    const object_count = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "object_count");

    const pack_files = if (format_version >= 2)
        try readBundlePathList(alloc, &line_it, "packs")
    else
        try alloc.alloc([]u8, 0);
    errdefer freeOwnedStrings(alloc, pack_files);
    const pack_digests = if (format_version >= 4)
        try readBundlePackDigests(alloc, &line_it)
    else
        try alloc.alloc(PackDigest, 0);
    errdefer {
        for (pack_digests) |*entry| entry.deinit(alloc);
        alloc.free(pack_digests);
    }
    const info_files = if (format_version >= 2)
        try readBundlePathList(alloc, &line_it, "info_files")
    else
        try alloc.alloc([]u8, 0);
    errdefer freeOwnedStrings(alloc, info_files);
    const reftable_files = if (format_version >= 2)
        try readBundlePathList(alloc, &line_it, "reftable_files")
    else
        try alloc.alloc([]u8, 0);
    errdefer freeOwnedStrings(alloc, reftable_files);
    const loose_ref_files = if (format_version >= 2)
        try readBundlePathList(alloc, &line_it, "loose_ref_files")
    else
        try alloc.alloc([]u8, 0);
    errdefer freeOwnedStrings(alloc, loose_ref_files);
    const reflog_files = if (format_version >= 2)
        try readBundlePathList(alloc, &line_it, "reflog_files")
    else
        try alloc.alloc([]u8, 0);
    errdefer freeOwnedStrings(alloc, reflog_files);
    const symref_files = if (format_version >= 4)
        try readBundlePathList(alloc, &line_it, "symref_files")
    else
        try alloc.alloc([]u8, 0);
    errdefer freeOwnedStrings(alloc, symref_files);
    const borrowed_repo_paths = if (format_version >= 3)
        try readBundlePathList(alloc, &line_it, "borrowed_repositories")
    else
        try alloc.alloc([]u8, 0);
    errdefer freeOwnedStrings(alloc, borrowed_repo_paths);

    const prerequisite_count = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "prerequisites");

    const prerequisites = try alloc.alloc(object_store.ObjectId, prerequisite_count);
    errdefer alloc.free(prerequisites);
    for (prerequisites) |*entry| {
        const line = line_it.next() orelse return error.InvalidBundle;
        entry.* = try object_store.ObjectId.fromHex(line);
    }
    const prerequisite_refs = if (format_version >= 4)
        try readBundleRefs(alloc, &line_it, "prerequisite_refs")
    else
        try alloc.alloc(BundleRef, 0);
    errdefer {
        for (prerequisite_refs) |*entry| entry.deinit(alloc);
        alloc.free(prerequisite_refs);
    }

    const refs = try readBundleRefs(alloc, &line_it, "refs");

    return .{
        .format_version = @intCast(format_version),
        .repository_format_version = @intCast(repository_format_version),
        .ref_backend = ref_backend,
        .repository_id = repository_id,
        .incremental = incremental_value != 0,
        .refs = refs,
        .prerequisites = prerequisites,
        .prerequisite_refs = prerequisite_refs,
        .object_count = object_count,
        .pack_files = pack_files,
        .pack_digests = pack_digests,
        .info_files = info_files,
        .reftable_files = reftable_files,
        .loose_ref_files = loose_ref_files,
        .reflog_files = reflog_files,
        .symref_files = symref_files,
        .borrowed_repo_paths = borrowed_repo_paths,
    };
}

fn parseBundleCountLine(line: []const u8, key: []const u8) !usize {
    if (line.len <= key.len or !std.mem.eql(u8, line[0..key.len], key) or line[key.len] != ' ') {
        return error.InvalidBundle;
    }
    return try std.fmt.parseInt(usize, line[key.len + 1 ..], 10);
}

fn parseBundleRepositoryId(line: []const u8) !RepositoryIdentity {
    if (!std.mem.startsWith(u8, line, "repository_id ")) return error.InvalidBundle;
    const raw = line["repository_id ".len..];
    if (raw.len != 64) return error.InvalidBundle;
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(out[0..], raw);
    return .{ .bytes = out };
}

fn readBundlePathList(alloc: std.mem.Allocator, line_it: *std.mem.TokenIterator(u8, .any), key: []const u8) ![][]u8 {
    const count = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, key);
    const paths = try alloc.alloc([]u8, count);
    errdefer {
        for (paths[0..]) |path| {
            if (path.len != 0) alloc.free(path);
        }
        alloc.free(paths);
    }
    for (paths) |*path| path.* = &[_]u8{};
    for (paths) |*path| {
        const line = line_it.next() orelse return error.InvalidBundle;
        path.* = try alloc.dupe(u8, line);
    }
    return paths;
}

fn readBundleRefs(alloc: std.mem.Allocator, line_it: *std.mem.TokenIterator(u8, .any), key: []const u8) ![]BundleRef {
    const count = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, key);
    const refs = try alloc.alloc(BundleRef, count);
    errdefer {
        for (refs[0..]) |*entry| {
            if (entry.name.len != 0) entry.deinit(alloc);
        }
        alloc.free(refs);
    }
    for (refs) |*entry| entry.* = .{ .name = &[_]u8{}, .id = undefined };
    for (refs) |*entry| {
        const line = line_it.next() orelse return error.InvalidBundle;
        const sep = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.InvalidBundle;
        entry.* = .{
            .name = try alloc.dupe(u8, line[0..sep]),
            .id = try object_store.ObjectId.fromHex(line[sep + 1 ..]),
        };
    }
    return refs;
}

fn readBundlePackDigests(alloc: std.mem.Allocator, line_it: *std.mem.TokenIterator(u8, .any)) ![]PackDigest {
    const count = try parseBundleCountLine(line_it.next() orelse return error.InvalidBundle, "pack_digests");
    const digests = try alloc.alloc(PackDigest, count);
    errdefer {
        for (digests[0..]) |*entry| {
            if (entry.pack_path.len != 0) entry.deinit(alloc);
        }
        alloc.free(digests);
    }
    for (digests) |*entry| entry.* = .{ .pack_path = &[_]u8{}, .pack_checksum = [_]u8{0} ** 32, .object_count = 0 };
    for (digests) |*entry| {
        const line = line_it.next() orelse return error.InvalidBundle;
        const first_sep = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidBundle;
        const second_sep_rel = std.mem.indexOfScalar(u8, line[first_sep + 1 ..], ' ') orelse return error.InvalidBundle;
        const second_sep = first_sep + 1 + second_sep_rel;
        entry.pack_path = try alloc.dupe(u8, line[0..first_sep]);
        var checksum: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(checksum[0..], line[first_sep + 1 .. second_sep]);
        entry.pack_checksum = checksum;
        entry.object_count = try std.fmt.parseInt(u64, line[second_sep + 1 ..], 10);
    }
    return digests;
}

fn copyRelativeFile(src_root: std.fs.Dir, dst_root: std.fs.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |dirname| try dst_root.makePath(dirname);
    dst_root.deleteFile(rel_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try src_root.copyFile(rel_path, dst_root, rel_path, .{});
}

fn copyRelativeFiles(src_root: std.fs.Dir, dst_root: std.fs.Dir, rel_paths: []const []const u8) !void {
    for (rel_paths) |path| try copyRelativeFile(src_root, dst_root, path);
}

fn looseObjectPath(alloc: std.mem.Allocator, id: object_store.ObjectId) ![]u8 {
    const hex = id.toHex();
    return try std.fmt.allocPrint(alloc, "objects/{s}/{s}", .{ hex[0..2], hex[0..] });
}

fn copyPackCompanionFiles(alloc: std.mem.Allocator, src_root: std.fs.Dir, dst_root: std.fs.Dir, pack_path: []const u8) !void {
    try copyRelativeFile(src_root, dst_root, pack_path);
    const base = pack_path[0 .. pack_path.len - ".pack".len];
    const idx_path = try std.fmt.allocPrint(alloc, "{s}.idx", .{base});
    defer alloc.free(idx_path);
    const manifest_path = try std.fmt.allocPrint(alloc, "{s}.manifest", .{base});
    defer alloc.free(manifest_path);
    const rev_path = try std.fmt.allocPrint(alloc, "{s}.rev", .{base});
    defer alloc.free(rev_path);
    try copyRelativeFile(src_root, dst_root, idx_path);
    try copyRelativeFile(src_root, dst_root, manifest_path);
    try copyRelativeFile(src_root, dst_root, rev_path);
}

fn packFileMatchesDigest(root: std.fs.Dir, alloc: std.mem.Allocator, digest: PackDigest) !bool {
    _ = root.statFile(digest.pack_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    const checksum = try hashRelativePath(root, alloc, digest.pack_path);
    return std.mem.eql(u8, checksum[0..], digest.pack_checksum[0..]);
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

    const pack_inventory = try source.store.loadPackInventory(alloc);
    defer object_store.freePackInventoryRecords(alloc, pack_inventory);
    var copied_pack_files = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (copied_pack_files.items) |path| alloc.free(path);
        copied_pack_files.deinit();
    }
    var copied_pack_digests = std.array_list.Managed(PackDigest).init(alloc);
    defer {
        for (copied_pack_digests.items) |*entry| entry.deinit(alloc);
        copied_pack_digests.deinit();
    }

    const info_candidates = [_][]const u8{
        store_format_path,
        repository_id_path,
    };
    var copied_info_files = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (copied_info_files.items) |path| alloc.free(path);
        copied_info_files.deinit();
    }
    for (info_candidates) |path| {
        if (!(try pathExists(source.store.root, path))) continue;
        try copyRelativeFile(source.store.root, bundle_store.root, path);
        try copied_info_files.append(try alloc.dupe(u8, path));
    }

    const reftable_files = try listFilesRecursive(alloc, source.refs.root, "reftable");
    defer freeOwnedStrings(alloc, reftable_files);
    try copyRelativeFiles(source.refs.root, bundle_store.root, reftable_files);

    const loose_ref_files_all = try listFilesRecursive(alloc, source.refs.root, "refs");
    defer freeOwnedStrings(alloc, loose_ref_files_all);
    var copied_loose_ref_files = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (copied_loose_ref_files.items) |path| alloc.free(path);
        copied_loose_ref_files.deinit();
    }
    for (loose_ref_files_all) |path| {
        if (std.mem.startsWith(u8, path, "refs/txn/")) continue;
        try copyRelativeFile(source.refs.root, bundle_store.root, path);
        try copied_loose_ref_files.append(try alloc.dupe(u8, path));
    }

    const reflog_files = try listFilesRecursive(alloc, source.refs.root, "logs/refs");
    defer freeOwnedStrings(alloc, reflog_files);
    try copyRelativeFiles(source.refs.root, bundle_store.root, reflog_files);

    const symref_files = try listFilesRecursive(alloc, source.refs.root, "symrefs");
    defer freeOwnedStrings(alloc, symref_files);
    try copyRelativeFiles(source.refs.root, bundle_store.root, symref_files);

    var selected = std.array_list.Managed(object_store.ObjectId).init(alloc);
    defer selected.deinit();
    var selected_pack_paths = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (selected_pack_paths.items) |path| alloc.free(path);
        selected_pack_paths.deinit();
    }
    var prerequisite_refs = std.array_list.Managed(BundleRef).init(alloc);
    defer {
        for (prerequisite_refs.items) |*entry| entry.deinit(alloc);
        prerequisite_refs.deinit();
    }
    if (since_spec) |spec| {
        if (prerequisite_ids.items.len == 1) {
            try prerequisite_refs.append(.{
                .name = try alloc.dupe(u8, spec),
                .id = prerequisite_ids.items[0],
            });
        }
    }
    var it = reachable.keyIterator();
    while (it.next()) |id_ptr| {
        if (base_reachable) |*base| {
            if (base.contains(id_ptr.*)) continue;
        }
        if (try source.store.findLocalPackPathForObject(alloc, id_ptr.*)) |pack_path| {
            defer alloc.free(pack_path);
            if (!containsString(selected_pack_paths.items, pack_path)) {
                try copyPackCompanionFiles(alloc, source.store.root, bundle_store.root, pack_path);
                try copied_pack_files.append(try alloc.dupe(u8, pack_path));
                try selected_pack_paths.append(try alloc.dupe(u8, pack_path));
                const digest = findPackDigest(pack_inventory, pack_path) orelse return error.MissingPackManifest;
                try copied_pack_digests.append(.{
                    .pack_path = try alloc.dupe(u8, digest.pack_path),
                    .pack_checksum = digest.pack_checksum,
                    .object_count = digest.object_count,
                });
            }
        } else if (try source.store.hasLooseObject(id_ptr.*)) {
            const path = try looseObjectPath(alloc, id_ptr.*);
            defer alloc.free(path);
            try copyRelativeFile(source.store.root, bundle_store.root, path);
        }
        try selected.append(id_ptr.*);
    }

    try bundle_store.rebuildPackInventory(alloc);
    const bundle_ids = try bundle_store.listIds(alloc);
    defer alloc.free(bundle_ids);

    const manifest = BundleManifest{
        .format_version = 4,
        .repository_format_version = source.format.version,
        .ref_backend = source.format.ref_backend,
        .repository_id = source.repository_id,
        .incremental = since_spec != null,
        .refs = try cloneBundleRefs(alloc, refs),
        .prerequisites = try alloc.dupe(object_store.ObjectId, prerequisite_ids.items),
        .prerequisite_refs = try cloneBundleRefsSlice(alloc, prerequisite_refs.items),
        .object_count = bundle_ids.len,
        .pack_files = try cloneOwnedStringsSlice(alloc, copied_pack_files.items),
        .pack_digests = try clonePackDigests(alloc, copied_pack_digests.items),
        .info_files = try cloneOwnedStringsSlice(alloc, copied_info_files.items),
        .reftable_files = try cloneOwnedStringsSlice(alloc, reftable_files),
        .loose_ref_files = try cloneOwnedStringsSlice(alloc, copied_loose_ref_files.items),
        .reflog_files = try cloneOwnedStringsSlice(alloc, reflog_files),
        .symref_files = try cloneOwnedStringsSlice(alloc, symref_files),
        .borrowed_repo_paths = try cloneOwnedStringsSlice(alloc, source.store.alternates.repo_paths),
    };
    defer {
        var owned = manifest;
        owned.deinit(alloc);
    }
    try writeBundleManifest(alloc, dst_path, manifest);
    return .{
        .ref_count = refs.len,
        .prerequisite_count = prerequisite_ids.items.len,
        .object_count = bundle_ids.len,
        .pack_count = copied_pack_files.items.len,
        .reftable_file_count = reftable_files.len,
    };
}

pub fn verifyBundle(alloc: std.mem.Allocator, bundle_path: []const u8) !BundleResult {
    var manifest = try readBundleManifest(alloc, bundle_path);
    defer manifest.deinit(alloc);

    var root = try std.fs.cwd().openDir(bundle_path, .{ .iterate = true });
    defer root.close();
    var store = object_store.ObjectStore{
        .allocator = alloc,
        .root = root,
        .fsync = .none,
        .alternates = .{ .repo_paths = try alloc.alloc([]u8, 0) },
    };
    defer store.alternates.deinit(alloc);

    const ids = try store.listIds(alloc);
    defer alloc.free(ids);
    if (ids.len != manifest.object_count) return error.InvalidBundle;

    for (manifest.pack_files) |path| {
        _ = try root.statFile(path);
        const base = path[0 .. path.len - ".pack".len];
        const idx_path = try std.fmt.allocPrint(alloc, "{s}.idx", .{base});
        defer alloc.free(idx_path);
        const manifest_path = try std.fmt.allocPrint(alloc, "{s}.manifest", .{base});
        defer alloc.free(manifest_path);
        const rev_path = try std.fmt.allocPrint(alloc, "{s}.rev", .{base});
        defer alloc.free(rev_path);
        _ = try root.statFile(idx_path);
        _ = try root.statFile(manifest_path);
        _ = try root.statFile(rev_path);
        if (manifest.format_version >= 4) {
            const digest = findBundlePackDigest(manifest.pack_digests, path) orelse return error.InvalidBundle;
            if (!try packFileMatchesDigest(root, alloc, digest)) return error.InvalidBundle;
        }
    }
    for (manifest.info_files) |path| _ = try root.statFile(path);
    for (manifest.reftable_files) |path| _ = try root.statFile(path);
    for (manifest.loose_ref_files) |path| _ = try root.statFile(path);
    for (manifest.reflog_files) |path| _ = try root.statFile(path);
    for (manifest.symref_files) |path| _ = try root.statFile(path);

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
        .pack_count = manifest.pack_files.len,
        .reftable_file_count = manifest.reftable_files.len,
    };
}

pub fn applyBundle(alloc: std.mem.Allocator, bundle_path: []const u8, dst_path: []const u8, fsync: cfg.FsyncPolicy) !BundleResult {
    var manifest = try readBundleManifest(alloc, bundle_path);
    defer manifest.deinit(alloc);

    const verify = try verifyBundle(alloc, bundle_path);
    _ = verify;

    var bundle_root = try std.fs.cwd().openDir(bundle_path, .{ .iterate = true });
    defer bundle_root.close();
    var bundle_store = object_store.ObjectStore{
        .allocator = alloc,
        .root = bundle_root,
        .fsync = .none,
        .alternates = .{ .repo_paths = try alloc.alloc([]u8, 0) },
    };
    defer bundle_store.alternates.deinit(alloc);

    var dest = try CasManager.init(alloc, dst_path, fsync);
    defer dest.deinit();

    for (manifest.prerequisites) |prereq| {
        const loaded = dest.store.get(alloc, prereq) catch return error.BundlePrerequisiteMissing;
        alloc.free(loaded.payload);
    }

    for (manifest.pack_files) |path| {
        if (manifest.format_version >= 4) {
            const digest = findBundlePackDigest(manifest.pack_digests, path) orelse return error.InvalidBundle;
            if (try packFileMatchesDigest(dest.store.root, alloc, digest)) continue;
        }
        try copyPackCompanionFiles(alloc, bundle_root, dest.store.root, path);
    }
    for (manifest.info_files) |path| {
        if (std.mem.eql(u8, path, "objects/info/multi-pack-index") or
            std.mem.eql(u8, path, commit_graph_path) or
            std.mem.eql(u8, path, reachability_bitmap_path) or
            std.mem.eql(u8, path, object_refs_index_path) or
            std.mem.eql(u8, path, "objects/info/pack-inventory"))
        {
            continue;
        }
        try copyRelativeFile(bundle_root, dest.store.root, path);
    }

    const ids = try bundle_store.listIds(alloc);
    defer alloc.free(ids);
    for (ids) |id| {
        if (!try bundle_store.hasLooseObject(id)) continue;
        const path = try looseObjectPath(alloc, id);
        defer alloc.free(path);
        try copyRelativeFile(bundle_root, dest.store.root, path);
    }

    if (manifest.reftable_files.len > 0) {
        dest.refs.root.access("reftable", .{}) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (dest.refs.root.access("reftable", .{})) |_| {
            try dest.refs.root.deleteTree("reftable");
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try dest.refs.root.makePath("reftable");
        try copyRelativeFiles(bundle_root, dest.refs.root, manifest.reftable_files);
    }
    if (manifest.loose_ref_files.len > 0) {
        if (dest.refs.root.access("refs", .{})) |_| {
            try dest.refs.root.deleteTree("refs");
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try dest.refs.root.makePath("refs");
        try dest.refs.root.makePath("refs/heads");
        try dest.refs.root.makePath("refs/txn");
        try copyRelativeFiles(bundle_root, dest.refs.root, manifest.loose_ref_files);
    }
    if (manifest.reflog_files.len > 0) {
        if (dest.refs.root.access("logs/refs", .{})) |_| {
            try dest.refs.root.deleteTree("logs/refs");
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try dest.refs.root.makePath("logs/refs");
        try dest.refs.root.makePath("logs/refs/heads");
        try copyRelativeFiles(bundle_root, dest.refs.root, manifest.reflog_files);
    }
    if (manifest.symref_files.len > 0) {
        if (dest.refs.root.access("symrefs", .{})) |_| {
            try dest.refs.root.deleteTree("symrefs");
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try dest.refs.root.makePath("symrefs");
        try copyRelativeFiles(bundle_root, dest.refs.root, manifest.symref_files);
    }

    if (manifest.format_version >= 2) {
        dest.format.version = manifest.repository_format_version;
        dest.format.ref_backend = manifest.ref_backend;
        try writeRepositoryFormat(alloc, dest.store.root, dest.format, dest.store.fsync);
        dest.refs.setBackend(manifest.ref_backend);
    }
    if (manifest.format_version >= 3 and !isZeroRepositoryId(manifest.repository_id)) {
        dest.repository_id = manifest.repository_id;
        try writeRepositoryId(dest.store.root, dest.repository_id, dest.store.fsync);
    }
    if (manifest.borrowed_repo_paths.len != 0) {
        try dest.store.configureAlternates(alloc, manifest.borrowed_repo_paths);
    }

    if (manifest.reftable_files.len == 0 and manifest.loose_ref_files.len == 0 and manifest.refs.len > 0) {
        var updates = try alloc.alloc(RefTxnUpdate, manifest.refs.len);
        defer alloc.free(updates);
        for (manifest.refs, 0..) |entry, idx| {
            updates[idx] = .{
                .ref_name = entry.name,
                .new_id = entry.id,
            };
        }
        try dest.refs.updateRefTxn(updates, "bundle-apply");
    }
    try dest.store.rebuildPackInventory(alloc);
    try dest.refreshCommitGraph();

    return .{
        .ref_count = manifest.refs.len,
        .prerequisite_count = manifest.prerequisites.len,
        .object_count = ids.len,
        .pack_count = manifest.pack_files.len,
        .reftable_file_count = manifest.reftable_files.len,
    };
}

pub fn cloneLocalRepository(alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, fsync: cfg.FsyncPolicy) !BundleResult {
    return try cloneLocalRepositoryWithOptions(alloc, src_path, dst_path, fsync, .{});
}

pub fn cloneLocalRepositoryWithOptions(
    alloc: std.mem.Allocator,
    src_path: []const u8,
    dst_path: []const u8,
    fsync: cfg.FsyncPolicy,
    options: LocalCloneOptions,
) !BundleResult {
    if (options.borrow) {
        var source = try CasManager.init(alloc, src_path, fsync);
        defer source.deinit();
        var dest = try CasManager.init(alloc, dst_path, fsync);
        defer dest.deinit();

        const refs = try source.refs.listRefs(alloc);
        defer {
            for (refs) |*entry| entry.deinit(alloc);
            alloc.free(refs);
        }
        var updates = try alloc.alloc(RefTxnUpdate, refs.len);
        defer alloc.free(updates);
        for (refs, 0..) |entry, idx| {
            updates[idx] = .{
                .ref_name = entry.name,
                .new_id = entry.id,
            };
        }
        if (updates.len != 0) try dest.refs.updateRefTxn(updates, "clone-local");
        try dest.store.configureAlternates(alloc, &[_][]const u8{src_path});
        dest.format = source.format;
        try writeRepositoryFormat(alloc, dest.store.root, dest.format, dest.store.fsync);
        if (!isZeroRepositoryId(source.repository_id)) {
            dest.repository_id = source.repository_id;
            try writeRepositoryId(dest.store.root, dest.repository_id, dest.store.fsync);
        }
        if (try source.readHeadSymRef()) |head_target| {
            defer alloc.free(head_target);
            try dest.writeHeadSymRef(head_target);
        } else {
            try dest.ensureHeadSymRef();
        }
        try dest.refreshCommitGraph();
        return .{
            .ref_count = refs.len,
            .prerequisite_count = 0,
            .object_count = 0,
            .pack_count = 0,
            .reftable_file_count = 0,
        };
    }

    const temp_bundle_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/local-clone-{d}", .{std.time.nanoTimestamp()});
    defer alloc.free(temp_bundle_path);
    std.fs.cwd().deleteTree(temp_bundle_path) catch {};
    defer std.fs.cwd().deleteTree(temp_bundle_path) catch {};

    _ = try createBundle(alloc, src_path, temp_bundle_path, fsync, null);
    return try applyBundle(alloc, temp_bundle_path, dst_path, fsync);
}

pub fn fetchLocalRepository(alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, fsync: cfg.FsyncPolicy) !LocalExchangeResult {
    return try fetchLocalRepositoryWithOptions(alloc, src_path, dst_path, fsync, .{});
}

pub fn fetchLocalRepositoryWithOptions(
    alloc: std.mem.Allocator,
    src_path: []const u8,
    dst_path: []const u8,
    fsync: cfg.FsyncPolicy,
    options: LocalFetchOptions,
) !LocalExchangeResult {
    var source = try CasManager.init(alloc, src_path, fsync);
    defer source.deinit();
    var dest = try CasManager.init(alloc, dst_path, fsync);
    defer dest.deinit();

    const merged_paths = try mergeRepositoryPaths(alloc, dest.store.alternates.repo_paths, src_path);
    defer freeOwnedStrings(alloc, merged_paths);
    try dest.store.configureAlternates(alloc, merged_paths);

    const refs = try source.refs.listRefs(alloc);
    defer {
        for (refs) |*entry| entry.deinit(alloc);
        alloc.free(refs);
    }
    var updates = try alloc.alloc(RefTxnUpdate, refs.len);
    defer alloc.free(updates);
    var update_names = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (update_names.items) |name| alloc.free(name);
        update_names.deinit();
    }
    for (refs, 0..) |entry, idx| {
        const tracking_name = try trackingRefName(alloc, source.repository_id, entry.name);
        defer alloc.free(tracking_name);
        const owned_name = try alloc.dupe(u8, tracking_name);
        try update_names.append(owned_name);
        updates[idx] = .{
            .ref_name = owned_name,
            .new_id = entry.id,
        };
    }
    if (updates.len != 0) try dest.refs.updateRefTxn(updates, "fetch-local");
    if (try source.readHeadSymRef()) |source_head_target| {
        defer alloc.free(source_head_target);
        const remote_head_name = try trackingHeadSymRefName(alloc, source.repository_id);
        defer alloc.free(remote_head_name);
        const remote_head_target = try trackingRefName(alloc, source.repository_id, source_head_target);
        defer alloc.free(remote_head_target);
        try dest.refs.writeSymRef(remote_head_name, remote_head_target);
    }
    if (options.materialize) {
        _ = try dest.materializeBorrowedObjects();
    }
    try dest.refreshCommitGraph();

    return .{
        .repository_id = source.repository_id,
        .ref_count = refs.len,
        .borrowed_repositories = dest.store.alternates.repo_paths.len,
    };
}

pub fn pushLocalRepository(alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, fsync: cfg.FsyncPolicy) !LocalExchangeResult {
    return try pushLocalRepositoryWithOptions(alloc, src_path, dst_path, fsync, .{});
}

pub fn pushLocalRepositoryWithOptions(
    alloc: std.mem.Allocator,
    src_path: []const u8,
    dst_path: []const u8,
    fsync: cfg.FsyncPolicy,
    options: LocalPushOptions,
) !LocalExchangeResult {
    var source = try CasManager.init(alloc, src_path, fsync);
    defer source.deinit();
    var dest = try CasManager.init(alloc, dst_path, fsync);
    defer dest.deinit();

    const src_head = try source.refs.readHead(main_ref) orelse return error.MissingCasHead;
    const dst_head = try dest.refs.readHead(main_ref);
    if (dst_head) |current_dst_head| {
        if (!try isAncestorInStore(alloc, &source.store, current_dst_head, src_head)) return error.NonFastForwardPush;
    }

    const merged_paths = try mergeRepositoryPaths(alloc, dest.store.alternates.repo_paths, src_path);
    defer freeOwnedStrings(alloc, merged_paths);
    try dest.store.configureAlternates(alloc, merged_paths);

    try dest.refs.compareAndSwapRef(main_ref, dst_head, src_head, "push-local");
    if (!options.borrow) {
        _ = try dest.materializeBorrowedObjects();
    }
    try dest.refreshCommitGraph();

    return .{
        .repository_id = source.repository_id,
        .ref_count = 1,
        .borrowed_repositories = dest.store.alternates.repo_paths.len,
    };
}

fn mergeRepositoryPaths(alloc: std.mem.Allocator, existing: []const []const u8, additional: []const u8) ![][]u8 {
    var merged = std.array_list.Managed([]u8).init(alloc);
    errdefer {
        for (merged.items) |path| alloc.free(path);
        merged.deinit();
    }
    for (existing) |path| {
        try merged.append(try alloc.dupe(u8, path));
    }
    for (merged.items) |path| {
        if (std.mem.eql(u8, path, additional)) return try merged.toOwnedSlice();
    }
    try merged.append(try alloc.dupe(u8, additional));
    return try merged.toOwnedSlice();
}

fn trackingRefName(alloc: std.mem.Allocator, repository_id: RepositoryIdentity, ref_name: []const u8) ![]u8 {
    const repo_hex = repository_id.toHex();
    return try std.fmt.allocPrint(alloc, "remotes/{s}/{s}", .{ repo_hex[0..], ref_name });
}

fn trackingHeadSymRefName(alloc: std.mem.Allocator, repository_id: RepositoryIdentity) ![]u8 {
    const repo_hex = repository_id.toHex();
    return try std.fmt.allocPrint(alloc, "remotes/{s}/HEAD", .{repo_hex[0..]});
}

fn isZeroRepositoryId(identity: RepositoryIdentity) bool {
    for (identity.bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn isAncestorInStore(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    ancestor: object_store.ObjectId,
    tip: object_store.ObjectId,
) !bool {
    if (ancestor.eql(tip)) return true;
    var stack = std.array_list.Managed(object_store.ObjectId).init(alloc);
    defer stack.deinit();
    var seen = std.AutoHashMap(object_store.ObjectId, void).init(alloc);
    defer seen.deinit();
    try stack.append(tip);
    while (stack.pop()) |id| {
        const gop = try seen.getOrPut(id);
        if (gop.found_existing) continue;
        if (id.eql(ancestor)) return true;

        const loaded = store.get(alloc, id) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer alloc.free(loaded.payload);
        if (loaded.obj_type != .commit) continue;

        var commit = try decodeCommit(alloc, loaded.payload);
        defer commit.deinit(alloc);
        for (commit.parents) |parent| try stack.append(parent);
    }
    return false;
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

fn containsString(entries: []const []const u8, needle: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

fn parseCheckpointRefTimestamp(ref_name: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, ref_name, "checkpoints/")) return null;
    const dash_idx = std.mem.lastIndexOfScalar(u8, ref_name, '-') orelse return null;
    return std.fmt.parseInt(i64, ref_name[dash_idx + 1 ..], 10) catch null;
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

fn parseLooseReflogEntry(alloc: std.mem.Allocator, ref_name: []const u8, line: []const u8) !ReflogEntry {
    var field_it = std.mem.tokenizeScalar(u8, line, ' ');
    const timestamp_raw = field_it.next() orelse return error.InvalidReflog;
    const old_hex = field_it.next() orelse return error.InvalidReflog;
    const new_hex = field_it.next() orelse return error.InvalidReflog;
    const reason = std.mem.trimLeft(u8, line[(timestamp_raw.len + 1 + old_hex.len + 1 + new_hex.len)..], " ");
    return .{
        .ref_name = try alloc.dupe(u8, ref_name),
        .old_id = if (isZeroHex(old_hex)) null else try object_store.ObjectId.fromHex(old_hex),
        .new_id = try object_store.ObjectId.fromHex(new_hex),
        .timestamp_ms = try std.fmt.parseInt(i64, timestamp_raw, 10),
        .reason = try alloc.dupe(u8, reason),
    };
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

fn collectLooseReflogObjectIds(alloc: std.mem.Allocator, root: std.fs.Dir) ![]object_store.ObjectId {
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
    const changed_path_blooms = try alloc.alloc(u8, entries.items.len * changed_path_bloom_bytes);
    errdefer alloc.free(changed_path_blooms);
    @memset(changed_path_blooms, 0);

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
        const bloom = changed_path_blooms[idx * changed_path_bloom_bytes .. (idx + 1) * changed_path_bloom_bytes];
        if (entries.items[idx].parents.len == 0) {
            try collectChangedPathsForTree(alloc, store, entries.items[idx].root, "", bloom);
            continue;
        }

        const parent_idx = positions.get(entries.items[idx].parents[0]) orelse return error.CorruptCommitGraph;
        try diffChangedPathsForTrees(
            alloc,
            store,
            entries.items[parent_idx].root,
            entries.items[idx].root,
            "",
            bloom,
        );
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
        .changed_path_bloom_bytes = changed_path_bloom_bytes,
        .changed_path_blooms = changed_path_blooms,
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

fn insertChangedPath(bloom: []u8, path: []const u8) void {
    if (bloom.len == 0 or path.len == 0) return;
    var seed: u64 = 0x9e3779b97f4a7c15;
    var iter: usize = 0;
    while (iter < 4) : (iter += 1) {
        const hash_value = std.hash.Wyhash.hash(seed, path);
        const bit_count = bloom.len * 8;
        const bit_index: usize = @intCast(hash_value % bit_count);
        bloom[bit_index / 8] |= (@as(u8, 1) << @intCast(bit_index % 8));
        seed +%= 0x517cc1b727220a95;
    }
}

fn shouldRecurseChangedPath(path: []const u8) bool {
    if (path.len == 0) return true;
    if (std.mem.eql(u8, path, "metadata")) return true;
    if (std.mem.eql(u8, path, "metadata/segments")) return true;
    if (std.mem.eql(u8, path, "wal")) return true;
    if (!std.mem.startsWith(u8, path, "metadata/segments/")) return false;

    var slash_count: usize = 0;
    for (path) |ch| {
        if (ch == '/') slash_count += 1;
    }
    return slash_count < 4;
}

fn joinChangedPath(alloc: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return try alloc.dupe(u8, name);
    return try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, name });
}

fn loadTreeObjectFromStore(alloc: std.mem.Allocator, store: *object_store.ObjectStore, tree_id: object_store.ObjectId) !Tree {
    const loaded = try store.get(alloc, tree_id);
    defer alloc.free(loaded.payload);
    if (loaded.obj_type != .tree) return error.InvalidTreeObject;
    return try decodeTree(alloc, loaded.payload);
}

fn collectChangedPathsForTree(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    tree_id: object_store.ObjectId,
    prefix: []const u8,
    bloom: []u8,
) !void {
    var tree = try loadTreeObjectFromStore(alloc, store, tree_id);
    defer tree.deinit(alloc);
    for (tree.entries) |entry| {
        const path = try joinChangedPath(alloc, prefix, entry.name);
        defer alloc.free(path);
        insertChangedPath(bloom, path);
        if (entry.object_type == .tree and shouldRecurseChangedPath(path)) {
            try collectChangedPathsForTree(alloc, store, entry.object_id, path, bloom);
        }
    }
}

fn diffChangedPathsForTrees(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    lhs_tree_id: object_store.ObjectId,
    rhs_tree_id: object_store.ObjectId,
    prefix: []const u8,
    bloom: []u8,
) !void {
    var lhs_tree = try loadTreeObjectFromStore(alloc, store, lhs_tree_id);
    defer lhs_tree.deinit(alloc);
    var rhs_tree = try loadTreeObjectFromStore(alloc, store, rhs_tree_id);
    defer rhs_tree.deinit(alloc);

    var lhs_idx: usize = 0;
    var rhs_idx: usize = 0;
    while (lhs_idx < lhs_tree.entries.len or rhs_idx < rhs_tree.entries.len) {
        if (lhs_idx >= lhs_tree.entries.len) {
            const rhs_entry = rhs_tree.entries[rhs_idx];
            rhs_idx += 1;
            const rhs_path = try joinChangedPath(alloc, prefix, rhs_entry.name);
            defer alloc.free(rhs_path);
            insertChangedPath(bloom, rhs_path);
            if (rhs_entry.object_type == .tree and shouldRecurseChangedPath(rhs_path)) {
                try collectChangedPathsForTree(alloc, store, rhs_entry.object_id, rhs_path, bloom);
            }
            continue;
        }
        if (rhs_idx >= rhs_tree.entries.len) {
            const lhs_entry = lhs_tree.entries[lhs_idx];
            lhs_idx += 1;
            const lhs_path = try joinChangedPath(alloc, prefix, lhs_entry.name);
            defer alloc.free(lhs_path);
            insertChangedPath(bloom, lhs_path);
            if (lhs_entry.object_type == .tree and shouldRecurseChangedPath(lhs_path)) {
                try collectChangedPathsForTree(alloc, store, lhs_entry.object_id, lhs_path, bloom);
            }
            continue;
        }

        const lhs_entry = lhs_tree.entries[lhs_idx];
        const rhs_entry = rhs_tree.entries[rhs_idx];
        const ordering = std.mem.order(u8, lhs_entry.name, rhs_entry.name);
        switch (ordering) {
            .lt => {
                lhs_idx += 1;
                const lhs_path = try joinChangedPath(alloc, prefix, lhs_entry.name);
                defer alloc.free(lhs_path);
                insertChangedPath(bloom, lhs_path);
                if (lhs_entry.object_type == .tree and shouldRecurseChangedPath(lhs_path)) {
                    try collectChangedPathsForTree(alloc, store, lhs_entry.object_id, lhs_path, bloom);
                }
            },
            .gt => {
                rhs_idx += 1;
                const rhs_path = try joinChangedPath(alloc, prefix, rhs_entry.name);
                defer alloc.free(rhs_path);
                insertChangedPath(bloom, rhs_path);
                if (rhs_entry.object_type == .tree and shouldRecurseChangedPath(rhs_path)) {
                    try collectChangedPathsForTree(alloc, store, rhs_entry.object_id, rhs_path, bloom);
                }
            },
            .eq => {
                lhs_idx += 1;
                rhs_idx += 1;
                if (lhs_entry.object_type == rhs_entry.object_type and lhs_entry.object_id.eql(rhs_entry.object_id)) {
                    continue;
                }
                const path = try joinChangedPath(alloc, prefix, lhs_entry.name);
                defer alloc.free(path);
                insertChangedPath(bloom, path);
                if (lhs_entry.object_type == .tree and rhs_entry.object_type == .tree and shouldRecurseChangedPath(path)) {
                    try diffChangedPathsForTrees(alloc, store, lhs_entry.object_id, rhs_entry.object_id, path, bloom);
                } else {
                    if (lhs_entry.object_type == .tree and shouldRecurseChangedPath(path)) {
                        try collectChangedPathsForTree(alloc, store, lhs_entry.object_id, path, bloom);
                    }
                    if (rhs_entry.object_type == .tree and shouldRecurseChangedPath(path)) {
                        try collectChangedPathsForTree(alloc, store, rhs_entry.object_id, path, bloom);
                    }
                }
            },
        }
    }
}

fn writeCommitGraph(alloc: std.mem.Allocator, root: std.fs.Dir, graph: CommitGraph, fsync: cfg.FsyncPolicy) !void {
    var bytes = std.array_list.Managed(u8).init(alloc);
    defer bytes.deinit();

    try bytes.appendSlice(commit_graph_magic[0..]);
    try appendInt(&bytes, u16, 2);
    try appendInt(&bytes, u64, @intCast(graph.object_ids.len));
    for (graph.object_ids) |id| try bytes.appendSlice(id.hash[0..]);
    for (graph.roots) |root_id| try bytes.appendSlice(root_id.hash[0..]);
    for (graph.created_at_ms) |created| try appendInt(&bytes, i64, created);
    for (graph.generations) |generation| try appendInt(&bytes, u32, generation);
    for (graph.parent_offsets) |offset| try appendInt(&bytes, u64, offset);
    for (graph.parent_positions) |position| try appendInt(&bytes, u64, position);
    for (graph.reason_offsets) |offset| try appendInt(&bytes, u64, offset);
    try bytes.appendSlice(graph.reasons);
    try appendInt(&bytes, u16, graph.changed_path_bloom_bytes);
    try bytes.appendSlice(graph.changed_path_blooms);

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
    if (version != 1 and version != 2) return error.UnsupportedCommitGraphVersion;
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

    var bloom_width: u16 = 0;
    var changed_path_blooms: []u8 = &.{};
    if (version >= 2) {
        bloom_width = try cursor.readInt(u16);
        const bloom_len = @as(usize, @intCast(commit_count)) * @as(usize, bloom_width);
        changed_path_blooms = try alloc.alloc(u8, bloom_len);
        errdefer alloc.free(changed_path_blooms);
        if (cursor.index + bloom_len > cursor.bytes.len) return error.CorruptCommitGraph;
        @memcpy(changed_path_blooms, cursor.bytes[cursor.index .. cursor.index + bloom_len]);
        cursor.index += bloom_len;
    } else {
        changed_path_blooms = try alloc.alloc(u8, 0);
        errdefer alloc.free(changed_path_blooms);
    }
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
        .changed_path_bloom_bytes = bloom_width,
        .changed_path_blooms = changed_path_blooms,
    };
}

fn writeReachabilityBitmap(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    refs: []const RefEntry,
    reachable_ids: []const object_store.ObjectId,
    fsync: cfg.FsyncPolicy,
) !void {
    var bytes = std.array_list.Managed(u8).init(alloc);
    defer bytes.deinit();

    try bytes.appendSlice(reachability_bitmap_magic[0..]);
    try appendInt(&bytes, u16, 1);
    try appendInt(&bytes, u64, @intCast(refs.len));
    try appendInt(&bytes, u64, @intCast(reachable_ids.len));
    for (refs) |entry| {
        try appendInt(&bytes, u16, @intCast(entry.name.len));
        try bytes.appendSlice(entry.name);
        try bytes.appendSlice(entry.id.hash[0..]);
    }
    for (reachable_ids) |id| try bytes.appendSlice(id.hash[0..]);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes.items);
    var checksum: [32]u8 = undefined;
    hasher.final(checksum[0..]);
    try bytes.appendSlice(checksum[0..]);

    const temp_path = reachability_bitmap_path ++ ".tmp";
    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};
    try file.writeAll(bytes.items);
    if (fsync != .none) {
        try file.sync();
    }
    root.rename(temp_path, reachability_bitmap_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(reachability_bitmap_path) catch {};
            try root.rename(temp_path, reachability_bitmap_path);
        },
        else => return err,
    };
    if (fsync != .none) {
        var root_for_sync = root;
        try syncDir(&root_for_sync);
    }
}

fn loadReachabilityBitmap(alloc: std.mem.Allocator, root: std.fs.Dir) !ReachabilityBitmap {
    const bytes = try root.readFileAlloc(alloc, reachability_bitmap_path, 256 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < reachability_bitmap_magic.len + @sizeOf(u16) + @sizeOf(u64) * 2 + 32) return error.CorruptReachabilityBitmap;
    if (!std.mem.eql(u8, bytes[0..reachability_bitmap_magic.len], reachability_bitmap_magic[0..])) return error.CorruptReachabilityBitmap;

    const checksum_start = bytes.len - 32;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes[0..checksum_start]);
    var expected_checksum: [32]u8 = undefined;
    hasher.final(expected_checksum[0..]);
    if (!std.mem.eql(u8, expected_checksum[0..], bytes[checksum_start..])) return error.CorruptReachabilityBitmap;

    var cursor = Cursor{ .bytes = bytes[0..checksum_start], .index = reachability_bitmap_magic.len };
    const version = try cursor.readInt(u16);
    if (version != 1) return error.UnsupportedReachabilityBitmapVersion;
    const ref_count = try cursor.readInt(u64);
    const object_count = try cursor.readInt(u64);

    const refs = try alloc.alloc(RefEntry, @intCast(ref_count));
    var refs_loaded: usize = 0;
    errdefer {
        for (refs[0..refs_loaded]) |*entry| entry.deinit(alloc);
        alloc.free(refs);
    }
    for (refs) |*entry| {
        const name_len = try cursor.readInt(u16);
        const name = try cursor.readBytes(alloc, name_len);
        errdefer alloc.free(name);
        entry.* = .{
            .name = name,
            .id = .{ .hash = try cursor.readHash() },
        };
        refs_loaded += 1;
    }

    const reachable_ids = try alloc.alloc(object_store.ObjectId, @intCast(object_count));
    errdefer alloc.free(reachable_ids);
    for (reachable_ids) |*id| id.* = .{ .hash = try cursor.readHash() };
    try cursor.finish();

    return .{
        .refs = refs,
        .reachable_ids = reachable_ids,
    };
}

fn loadOrInitRepositoryFormat(alloc: std.mem.Allocator, root: std.fs.Dir, fsync: cfg.FsyncPolicy) !RepositoryFormat {
    return loadRepositoryFormat(root) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const format = if (try hasLegacyCompatibilityState(root))
                legacyCompatibleRepositoryFormat()
            else
                RepositoryFormat{};
            try writeRepositoryFormat(alloc, root, format, fsync);
            break :blk format;
        },
        else => return err,
    };
}

fn loadOrInitRepositoryId(root: std.fs.Dir, fsync: cfg.FsyncPolicy) !RepositoryIdentity {
    return loadRepositoryId(root) catch |err| switch (err) {
        error.FileNotFound => blk: {
            var bytes: [32]u8 = undefined;
            std.crypto.random.bytes(bytes[0..]);
            const identity = RepositoryIdentity{ .bytes = bytes };
            try writeRepositoryId(root, identity, fsync);
            break :blk identity;
        },
        else => return err,
    };
}

pub fn recommendedStartupDefaults(root: std.fs.Dir, data_dir_path: []const u8) !StartupDefaults {
    var data_dir = root.openDir(data_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return primary_startup_defaults,
        else => return err,
    };
    defer data_dir.close();

    if (loadRepositoryFormat(data_dir)) |format| {
        return if (repositoryFormatDefaultsToPrimary(format))
            primary_startup_defaults
        else
            legacy_startup_defaults;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    return if (try hasLegacyCompatibilityState(data_dir))
        legacy_startup_defaults
    else
        primary_startup_defaults;
}

fn repositoryFormatDefaultsToPrimary(format: RepositoryFormat) bool {
    return format.version >= current_repository_format_version and format.ref_backend == .reftable;
}

fn legacyCompatibleRepositoryFormat() RepositoryFormat {
    return .{
        .version = legacy_repository_format_version,
        .ref_backend = .loose,
        .extent_chunk_bytes = default_extent_chunk_bytes,
    };
}

fn hasLegacyCompatibilityState(root: std.fs.Dir) !bool {
    if (try pathExists(root, "MANIFEST")) return true;
    if (try pathExists(root, "tags.json")) return true;
    if (try pathExists(root, "series_catalog.jsonl")) return true;
    if (try directoryHasEntries(root, "wal")) return true;
    if (try directoryHasEntries(root, "segments")) return true;
    return false;
}

fn pathExists(root: std.fs.Dir, path: []const u8) !bool {
    root.access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn directoryHasEntries(root: std.fs.Dir, path: []const u8) !bool {
    var dir = root.openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close();
    var it = dir.iterate();
    return (try it.next()) != null;
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

fn loadRepositoryId(root: std.fs.Dir) !RepositoryIdentity {
    const bytes = try root.readFileAlloc(std.heap.page_allocator, repository_id_path, 1024);
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len < repository_id_magic.len + 64) return error.CorruptRepositoryId;
    if (!std.mem.eql(u8, bytes[0..repository_id_magic.len], repository_id_magic)) return error.CorruptRepositoryId;
    const trimmed = std.mem.trim(u8, bytes[repository_id_magic.len..], " \t\r\n");
    if (trimmed.len != 64) return error.CorruptRepositoryId;
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(out[0..], trimmed);
    return .{ .bytes = out };
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
        const segment_root = if (store) |object_store_ref|
            try segment_mod.writeSegmentRootForFile(alloc, data_dir, object_store_ref, entry.path, extent_chunk_bytes)
        else
            null;
        const content = try ensureContentRefForFile(alloc, store, data_dir, entry.path, extent_chunk_bytes);
        try descriptors.append(.{
            .path = try alloc.dupe(u8, entry.path),
            .mirror_path = &[_]u8{},
            .segment_root = segment_root,
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

    const segment_descriptors = try descriptors.toOwnedSlice();
    errdefer {
        for (segment_descriptors) |*descriptor| descriptor.deinit(alloc);
        alloc.free(segment_descriptors);
    }

    var tag_snapshot = try buildTagSnapshot(alloc, tags);
    errdefer tag_snapshot.deinit(alloc);

    var series_catalog_snapshot = try buildSeriesCatalogSnapshot(alloc, series_catalog);
    errdefer series_catalog_snapshot.deinit(alloc);

    var wal_index = try buildWalIndex(alloc, data_dir, store, extent_chunk_bytes);
    errdefer wal_index.deinit(alloc);

    var checkpoint_state = try buildCheckpointState(alloc, segment_descriptors, wal_index.entries);
    errdefer checkpoint_state.deinit(alloc);

    return .{
        .segment_descriptors = segment_descriptors,
        .tag_snapshot = tag_snapshot,
        .series_catalog_snapshot = series_catalog_snapshot,
        .wal_index = wal_index,
        .checkpoint_state = checkpoint_state,
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
        const journal_root = if (store) |object_store_ref|
            try wal_mod.writeJournalRootForWalFile(alloc, data_dir, object_store_ref, info.name)
        else
            null;
        const content = try ensureContentRefForWalFile(alloc, store, data_dir, info.name, extent_chunk_bytes);
        try entries.append(.{
            .name = try alloc.dupe(u8, info.name),
            .mirror_name = &[_]u8{},
            .journal_root = journal_root,
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

fn buildCheckpointState(
    alloc: std.mem.Allocator,
    descriptors: []const SegmentDescriptor,
    wal_entries: []const WalChunkDescriptor,
) !CheckpointState {
    var highwaters = std.array_list.Managed(CheckpointSeriesHighwater).init(alloc);
    errdefer highwaters.deinit();

    for (descriptors) |descriptor| {
        if (highwaters.items.len != 0 and highwaters.items[highwaters.items.len - 1].series_id == descriptor.series_id) {
            if (descriptor.end_ts > highwaters.items[highwaters.items.len - 1].highwater_ts) {
                highwaters.items[highwaters.items.len - 1].highwater_ts = descriptor.end_ts;
            }
            continue;
        }
        try highwaters.append(.{
            .series_id = descriptor.series_id,
            .highwater_ts = descriptor.end_ts,
        });
    }

    var checkpoint_wal_entries = std.array_list.Managed(CheckpointWalEntry).init(alloc);
    errdefer {
        for (checkpoint_wal_entries.items) |*entry| entry.deinit(alloc);
        checkpoint_wal_entries.deinit();
    }
    for (wal_entries) |entry| {
        try checkpoint_wal_entries.append(.{
            .name = try alloc.dupe(u8, entry.mirrorName()),
            .journal_root = entry.journalRoot(),
            .mutable = entry.mutable,
            .captured_bytes = entry.captured_bytes,
        });
    }

    return .{
        .highwaters = try highwaters.toOwnedSlice(),
        .wal_entries = try checkpoint_wal_entries.toOwnedSlice(),
    };
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
                    if (!try wal_mod.ContentPrefixComparator.blobObjectMatchesFile(alloc, data_dir, store, path, content_id)) {
                        return error.CasVerificationFailed;
                    }
                },
                .extent_tree => |tree| {
                    if (!try wal_mod.ContentPrefixComparator.extentTreeMatchesFile(alloc, data_dir, store, path, tree)) {
                        return error.CasVerificationFailed;
                    }
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

fn hashRelativePath(root: std.fs.Dir, alloc: std.mem.Allocator, path: []const u8) ![32]u8 {
    _ = alloc;
    var file = try root.openFile(path, .{ .mode = .read_only });
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

    if (descriptor.segmentRoot() == null and descriptor.contentRef() == null) return error.MissingSegmentContentId;

    try bytes.append(5);
    try appendOptionalObjectId(&bytes, descriptor.segmentRoot());
    if (descriptor.contentRef()) |content| {
        try encodeContentRef(&bytes, content);
    } else {
        try bytes.append(0);
    }
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
    if (version != 1 and version != 2 and version != 3 and version != 4 and version != 5) return error.UnsupportedSegmentDescriptorVersion;

    const segment_root = if (version == 5) try cursor.readOptionalObjectId() else null;
    const content = if (version == 5 or version == 4)
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
        .segment_root = segment_root,
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

fn encodeCheckpointState(alloc: std.mem.Allocator, checkpoint: CheckpointState) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(1);
    try appendInt(&bytes, u32, @intCast(checkpoint.highwaters.len));
    for (checkpoint.highwaters) |entry| {
        try appendInt(&bytes, u64, entry.series_id);
        try appendInt(&bytes, i64, entry.highwater_ts);
    }
    try appendInt(&bytes, u32, @intCast(checkpoint.wal_entries.len));
    for (checkpoint.wal_entries) |entry| {
        try appendString(&bytes, entry.name);
        try appendOptionalObjectId(&bytes, entry.journal_root);
        try bytes.append(if (entry.mutable) 1 else 0);
        try appendInt(&bytes, u64, entry.captured_bytes);
    }
    return try bytes.toOwnedSlice();
}

fn decodeCheckpointState(alloc: std.mem.Allocator, payload: []const u8) !CheckpointState {
    var cursor = Cursor{ .bytes = payload };
    const version = try cursor.readByte();
    if (version != 1) return error.UnsupportedCheckpointStateVersion;

    const highwater_count = try cursor.readInt(u32);
    const highwaters = try alloc.alloc(CheckpointSeriesHighwater, highwater_count);
    errdefer alloc.free(highwaters);
    for (highwaters) |*entry| {
        entry.* = .{
            .series_id = try cursor.readInt(u64),
            .highwater_ts = try cursor.readInt(i64),
        };
    }

    const wal_entry_count = try cursor.readInt(u32);
    var wal_entries = try alloc.alloc(CheckpointWalEntry, wal_entry_count);
    errdefer {
        for (wal_entries[0..@min(wal_entries.len, cursor.objects_read)]) |*entry| entry.deinit(alloc);
        alloc.free(wal_entries);
    }
    var decoded_wal_entries: usize = 0;
    while (decoded_wal_entries < wal_entry_count) : (decoded_wal_entries += 1) {
        wal_entries[decoded_wal_entries] = .{
            .name = try cursor.readOwnedString(alloc),
            .journal_root = try cursor.readOptionalObjectId(),
            .mutable = (try cursor.readByte()) != 0,
            .captured_bytes = try cursor.readInt(u64),
        };
        cursor.objects_read += 1;
    }
    try cursor.finish();

    return .{
        .highwaters = highwaters,
        .wal_entries = wal_entries,
    };
}

fn encodeWalIndex(alloc: std.mem.Allocator, wal_index: WalIndex) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(5);
    try appendInt(&bytes, u32, @intCast(wal_index.entries.len));
    for (wal_index.entries) |entry| {
        const content = entry.contentRef() orelse return error.MissingWalContentId;
        try appendString(&bytes, entry.mirrorName());
        try appendOptionalObjectId(&bytes, entry.journalRoot());
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
    if (version != 1 and version != 2 and version != 3 and version != 4 and version != 5) return error.UnsupportedWalIndexVersion;

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
        const journal_root = if (version == 5) try cursor.readOptionalObjectId() else null;
        const content = if (version == 5 or version == 4)
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
            .journal_root = journal_root,
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

    fn readBytes(self: *Cursor, alloc: std.mem.Allocator, len: usize) ![]u8 {
        if (self.index + len > self.bytes.len) return error.TruncatedObject;
        const out = try alloc.dupe(u8, self.bytes[self.index .. self.index + len]);
        self.index += len;
        return out;
    }

    fn readOwnedString(self: *Cursor, alloc: std.mem.Allocator) ![]u8 {
        const len = try self.readInt(u32);
        return try self.readBytes(alloc, len);
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

fn checkpointStatesEql(lhs: CheckpointState, rhs: CheckpointState) bool {
    if (lhs.highwaters.len != rhs.highwaters.len) return false;
    for (lhs.highwaters, rhs.highwaters) |lhs_entry, rhs_entry| {
        if (!lhs_entry.eql(rhs_entry)) return false;
    }
    if (lhs.wal_entries.len != rhs.wal_entries.len) return false;
    for (lhs.wal_entries, rhs.wal_entries) |lhs_entry, rhs_entry| {
        if (!lhs_entry.eql(rhs_entry)) return false;
    }
    return true;
}

fn cloneSegmentDescriptor(alloc: std.mem.Allocator, descriptor: SegmentDescriptor) !SegmentDescriptor {
    return .{
        .path = try alloc.dupe(u8, descriptor.path),
        .mirror_path = &[_]u8{},
        .segment_root = descriptor.segment_root,
        .content_id = descriptor.content_id,
        .content = descriptor.content,
        .file_hash = descriptor.file_hash,
        .file_size = descriptor.file_size,
        .series_id = descriptor.series_id,
        .hour_bucket = descriptor.hour_bucket,
        .start_ts = descriptor.start_ts,
        .end_ts = descriptor.end_ts,
        .count = descriptor.count,
        .ts_codec = descriptor.ts_codec,
        .val_codec = descriptor.val_codec,
    };
}

fn cloneWalChunkDescriptor(alloc: std.mem.Allocator, entry: WalChunkDescriptor) !WalChunkDescriptor {
    return .{
        .name = try alloc.dupe(u8, entry.name),
        .mirror_name = &[_]u8{},
        .journal_root = entry.journal_root,
        .content_id = entry.content_id,
        .content = entry.content,
        .file_size = entry.file_size,
        .file_hash = entry.file_hash,
        .mutable = entry.mutable,
        .captured_bytes = entry.captured_bytes,
    };
}

fn cloneTagSnapshot(alloc: std.mem.Allocator, snapshot: TagSnapshot) !TagSnapshot {
    const entries = try alloc.alloc(TagSnapshotEntry, snapshot.entries.len);
    errdefer {
        for (entries[0..]) |*entry| {
            if (entry.key.len != 0) entry.deinit(alloc);
        }
        alloc.free(entries);
    }
    for (entries) |*entry| entry.* = .{ .key = &[_]u8{}, .series_ids = &[_]types.SeriesId{} };
    for (snapshot.entries, 0..) |entry, idx| {
        entries[idx] = .{
            .key = try alloc.dupe(u8, entry.key),
            .series_ids = try alloc.dupe(types.SeriesId, entry.series_ids),
        };
    }
    return .{ .entries = entries };
}

fn cloneSeriesCatalogSnapshot(alloc: std.mem.Allocator, snapshot: SeriesCatalogSnapshot) !SeriesCatalogSnapshot {
    const entries = try alloc.alloc(SeriesCatalogSnapshotEntry, snapshot.entries.len);
    errdefer {
        for (entries[0..]) |*entry| {
            if (entry.series.len != 0) entry.deinit(alloc);
        }
        alloc.free(entries);
    }
    for (entries) |*entry| entry.* = .{ .series = &[_]u8{}, .canonical_tags = &[_]u8{}, .series_id = 0 };
    for (snapshot.entries, 0..) |entry, idx| {
        entries[idx] = .{
            .series = try alloc.dupe(u8, entry.series),
            .canonical_tags = try alloc.dupe(u8, entry.canonical_tags),
            .series_id = entry.series_id,
        };
    }
    return .{ .entries = entries };
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

const reftable_magic = "SYDRTBL1";
const reftable_tables_list_path = "reftable/tables.list";
const reftable_state_path = "reftable/state";
const reftable_state_magic = "SYDRTST1";
const reftable_summary_path = "reftable/info/summary";
const reftable_summary_magic = "SYDRSUM1";
const reftable_current_version: u16 = 3;
const reftable_ref_block_entries: usize = 128;
const reftable_reflog_block_entries: usize = 64;

const ReftableSpan = struct {
    min_update_index: u64,
    max_update_index: u64,

    fn width(self: ReftableSpan) u64 {
        return if (self.max_update_index >= self.min_update_index)
            self.max_update_index - self.min_update_index + 1
        else
            0;
    }
};

const ReftableState = struct {
    next_update_index: u64,
};

pub const SymRef = struct {
    name: []u8,
    target: []u8,

    pub fn deinit(self: *SymRef, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.target);
    }
};

const ReftableRefRecord = struct {
    name: []u8,
    id: ?object_store.ObjectId,

    fn deinit(self: *ReftableRefRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub const ReftableSummaryRecord = struct {
    table_name: []u8,
    min_update_index: u64,
    max_update_index: u64,
    min_ref_name: []u8,
    max_ref_name: []u8,
    min_reflog_ref_name: []u8,
    max_reflog_ref_name: []u8,
    min_reflog_ts: i64,
    max_reflog_ts: i64,
    has_tombstones: bool,

    fn deinit(self: *ReftableSummaryRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.table_name);
        alloc.free(self.min_ref_name);
        alloc.free(self.max_ref_name);
        alloc.free(self.min_reflog_ref_name);
        alloc.free(self.max_reflog_ref_name);
    }
};

pub const ReftableSummaryIndex = struct {
    records: []ReftableSummaryRecord,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.records) |*record| record.deinit(alloc);
        alloc.free(self.records);
    }
};

const ReftableTable = struct {
    refs: []ReftableRefRecord,
    reflogs: []ReflogEntry,
    min_update_index: u64,
    max_update_index: u64,
    size_bytes: u64,

    fn deinit(self: *ReftableTable, alloc: std.mem.Allocator) void {
        for (self.refs) |*entry| entry.deinit(alloc);
        alloc.free(self.refs);
        for (self.reflogs) |*entry| entry.deinit(alloc);
        alloc.free(self.reflogs);
    }
};

const ReftableBlockIndexEntry = struct {
    first_key: []u8,
    block_offset: u64,

    fn deinit(self: *ReftableBlockIndexEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.first_key);
    }
};

const ReftableHeaderV3 = struct {
    span: ReftableSpan,
    ref_block_count: u32,
    reflog_block_count: u32,
    ref_entry_count: u64,
    reflog_entry_count: u64,
    ref_index_offset: u64,
    reflog_index_offset: u64,
    checksum_start: usize,
};

fn lookupReftableRefRecord(entries: []const ReftableRefRecord, ref_name: []const u8) ?ReftableRefRecord {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, ref_name)) return entry;
    }
    return null;
}

fn loadOrInitReftableState(alloc: std.mem.Allocator, root: std.fs.Dir) !ReftableState {
    return loadReftableState(alloc, root) catch |err| switch (err) {
        error.FileNotFound => .{ .next_update_index = try inferNextReftableUpdateIndex(alloc, root) },
        else => return err,
    };
}

fn loadReftableState(alloc: std.mem.Allocator, root: std.fs.Dir) !ReftableState {
    const bytes = try root.readFileAlloc(alloc, reftable_state_path, 4096);
    defer alloc.free(bytes);
    if (bytes.len < reftable_state_magic.len + @sizeOf(u16) + @sizeOf(u64) + 32) return error.CorruptReftableState;
    if (!std.mem.eql(u8, bytes[0..reftable_state_magic.len], reftable_state_magic)) return error.CorruptReftableState;

    const checksum_start = bytes.len - 32;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes[0..checksum_start]);
    var expected_checksum: [32]u8 = undefined;
    hasher.final(expected_checksum[0..]);
    if (!std.mem.eql(u8, expected_checksum[0..], bytes[checksum_start..])) return error.CorruptReftableState;

    var cursor = Cursor{ .bytes = bytes[reftable_state_magic.len..checksum_start] };
    const version = try cursor.readInt(u16);
    if (version != 1) return error.UnsupportedReftableStateVersion;
    const next_update_index = try cursor.readInt(u64);
    try cursor.finish();
    return .{ .next_update_index = next_update_index };
}

fn writeReftableState(alloc: std.mem.Allocator, root: std.fs.Dir, state: ReftableState, fsync: cfg.FsyncPolicy) !void {
    var bytes = std.array_list.Managed(u8).init(alloc);
    defer bytes.deinit();
    try bytes.appendSlice(reftable_state_magic);
    try appendInt(&bytes, u16, 1);
    try appendInt(&bytes, u64, state.next_update_index);
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes.items);
    var checksum: [32]u8 = undefined;
    hasher.final(checksum[0..]);
    try bytes.appendSlice(checksum[0..]);

    const temp_path = reftable_state_path ++ ".tmp";
    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};
    try file.writeAll(bytes.items);
    if (fsync != .none) try file.sync();
    root.rename(temp_path, reftable_state_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(reftable_state_path) catch {};
            try root.rename(temp_path, reftable_state_path);
        },
        else => return err,
    };
    if (fsync != .none) {
        var root_for_sync = root;
        try syncDir(&root_for_sync);
    }
}

fn writeRepositoryId(root: std.fs.Dir, identity: RepositoryIdentity, fsync: cfg.FsyncPolicy) !void {
    const temp_path = repository_id_path ++ ".tmp";
    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};

    const hex = identity.toHex();
    try file.writeAll(repository_id_magic);
    try file.writeAll(hex[0..]);
    try file.writeAll("\n");
    if (fsync != .none) try file.sync();
    root.rename(temp_path, repository_id_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(repository_id_path) catch {};
            try root.rename(temp_path, repository_id_path);
        },
        else => return err,
    };
    if (fsync != .none) {
        var root_for_sync = root;
        try syncDir(&root_for_sync);
    }
}

fn inferNextReftableUpdateIndex(alloc: std.mem.Allocator, root: std.fs.Dir) !u64 {
    const table_names = try loadReftableTableNames(alloc, root);
    defer freeOwnedStrings(alloc, table_names);

    var next_update_index: u64 = 1;
    for (table_names) |name| {
        const span = parseReftableSpanFromName(name) orelse continue;
        next_update_index = @max(next_update_index, span.max_update_index + 1);
    }
    return next_update_index;
}

fn parseReftableSpanFromName(path: []const u8) ?ReftableSpan {
    const base = std.fs.path.basename(path);
    if (!std.mem.endsWith(u8, base, ".table")) return null;
    const stem = base[0 .. base.len - ".table".len];
    const dash_idx = std.mem.indexOfScalar(u8, stem, '-') orelse return null;
    const min_update_index = std.fmt.parseInt(u64, stem[0..dash_idx], 10) catch return null;
    const max_update_index = std.fmt.parseInt(u64, stem[dash_idx + 1 ..], 10) catch return null;
    return .{
        .min_update_index = min_update_index,
        .max_update_index = max_update_index,
    };
}

fn reftableTablePathForSpan(alloc: std.mem.Allocator, span: ReftableSpan) ![]u8 {
    return try std.fmt.allocPrint(alloc, "reftable/{d}-{d}.table", .{ span.min_update_index, span.max_update_index });
}

fn loadReftableTableNames(alloc: std.mem.Allocator, root: std.fs.Dir) ![][]u8 {
    const body = root.readFileAlloc(alloc, reftable_tables_list_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc([]u8, 0),
        else => return err,
    };
    defer alloc.free(body);

    var names = std.array_list.Managed([]u8).init(alloc);
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit();
    }

    var line_it = std.mem.tokenizeScalar(u8, body, '\n');
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        try names.append(try alloc.dupe(u8, line));
    }
    return try names.toOwnedSlice();
}

fn scanReftableTableFiles(alloc: std.mem.Allocator, root: std.fs.Dir) ![][]u8 {
    var reftable_dir = root.openDir("reftable", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc([]u8, 0),
        else => return err,
    };
    defer reftable_dir.close();

    var names = std.array_list.Managed([]u8).init(alloc);
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit();
    }

    var it = reftable_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".table")) continue;
        try names.append(try std.fmt.allocPrint(alloc, "reftable/{s}", .{entry.name}));
    }

    std.sort.block([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            const lhs_span = parseReftableSpanFromName(lhs) orelse return std.mem.lessThan(u8, lhs, rhs);
            const rhs_span = parseReftableSpanFromName(rhs) orelse return std.mem.lessThan(u8, lhs, rhs);
            if (lhs_span.min_update_index != rhs_span.min_update_index) {
                return lhs_span.min_update_index < rhs_span.min_update_index;
            }
            return lhs_span.max_update_index < rhs_span.max_update_index;
        }
    }.lessThan);
    return try names.toOwnedSlice();
}

fn inferNextReftableUpdateIndexFromNames(table_names: []const []const u8) !u64 {
    var next_update_index: u64 = 1;
    for (table_names) |name| {
        const span = parseReftableSpanFromName(name) orelse return error.InvalidReftableTableName;
        next_update_index = @max(next_update_index, span.max_update_index + 1);
    }
    return next_update_index;
}

fn writeReftableTablesList(alloc: std.mem.Allocator, root: std.fs.Dir, names: []const []const u8, fsync: cfg.FsyncPolicy) !void {
    _ = alloc;
    const temp_path = reftable_tables_list_path ++ ".tmp";
    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer_state = file.writer(&write_buf);
    const writer = &writer_state.interface;
    for (names) |name| {
        try writer.writeAll(name);
        try writer.writeAll("\n");
    }
    try writer_state.end();
    if (fsync != .none) {
        try file.sync();
    }
    root.rename(temp_path, reftable_tables_list_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(reftable_tables_list_path) catch {};
            try root.rename(temp_path, reftable_tables_list_path);
        },
        else => return err,
    };
    if (fsync != .none) {
        var root_for_sync = root;
        try syncDir(&root_for_sync);
    }
}

fn rebuildReftableSummaryIndex(alloc: std.mem.Allocator, root: std.fs.Dir, fsync: cfg.FsyncPolicy) !void {
    var summary = try scanReftableSummaryIndex(alloc, root);
    defer summary.deinit(alloc);
    try writeReftableSummaryIndex(alloc, root, summary, fsync);
}

fn scanReftableSummaryIndex(alloc: std.mem.Allocator, root: std.fs.Dir) !ReftableSummaryIndex {
    const table_names = try loadReftableTableNames(alloc, root);
    defer freeOwnedStrings(alloc, table_names);

    const records = try alloc.alloc(ReftableSummaryRecord, table_names.len);
    var loaded_count: usize = 0;
    errdefer {
        for (records[0..loaded_count]) |*record| record.deinit(alloc);
        alloc.free(records);
    }

    for (table_names, 0..) |table_name, idx| {
        var table = try loadReftableTable(alloc, root, table_name);
        defer table.deinit(alloc);

        var min_ref_name: []u8 = try alloc.dupe(u8, "");
        errdefer alloc.free(min_ref_name);
        var max_ref_name: []u8 = try alloc.dupe(u8, "");
        errdefer alloc.free(max_ref_name);
        var min_reflog_ref_name: []u8 = try alloc.dupe(u8, "");
        errdefer alloc.free(min_reflog_ref_name);
        var max_reflog_ref_name: []u8 = try alloc.dupe(u8, "");
        errdefer alloc.free(max_reflog_ref_name);
        var min_reflog_ts: i64 = 0;
        var max_reflog_ts: i64 = 0;
        var has_tombstones = false;

        if (table.refs.len != 0) {
            alloc.free(min_ref_name);
            alloc.free(max_ref_name);
            min_ref_name = try alloc.dupe(u8, table.refs[0].name);
            max_ref_name = try alloc.dupe(u8, table.refs[table.refs.len - 1].name);
            for (table.refs) |record| {
                if (record.id == null) has_tombstones = true;
            }
        }
        if (table.reflogs.len != 0) {
            alloc.free(min_reflog_ref_name);
            alloc.free(max_reflog_ref_name);
            min_reflog_ref_name = try alloc.dupe(u8, table.reflogs[0].ref_name);
            max_reflog_ref_name = try alloc.dupe(u8, table.reflogs[table.reflogs.len - 1].ref_name);
            min_reflog_ts = table.reflogs[0].timestamp_ms;
            max_reflog_ts = table.reflogs[0].timestamp_ms;
            for (table.reflogs) |entry| {
                min_reflog_ts = @min(min_reflog_ts, entry.timestamp_ms);
                max_reflog_ts = @max(max_reflog_ts, entry.timestamp_ms);
            }
        }

        records[idx] = .{
            .table_name = try alloc.dupe(u8, table_name),
            .min_update_index = table.min_update_index,
            .max_update_index = table.max_update_index,
            .min_ref_name = min_ref_name,
            .max_ref_name = max_ref_name,
            .min_reflog_ref_name = min_reflog_ref_name,
            .max_reflog_ref_name = max_reflog_ref_name,
            .min_reflog_ts = min_reflog_ts,
            .max_reflog_ts = max_reflog_ts,
            .has_tombstones = has_tombstones,
        };
        loaded_count += 1;
    }

    return .{ .records = records };
}

fn writeReftableSummaryIndex(alloc: std.mem.Allocator, root: std.fs.Dir, summary: ReftableSummaryIndex, fsync: cfg.FsyncPolicy) !void {
    var bytes = std.array_list.Managed(u8).init(alloc);
    defer bytes.deinit();

    try bytes.appendSlice(reftable_summary_magic);
    try appendInt(&bytes, u16, 1);
    try appendInt(&bytes, u32, @intCast(summary.records.len));
    for (summary.records) |record| {
        try appendString(&bytes, record.table_name);
        try appendInt(&bytes, u64, record.min_update_index);
        try appendInt(&bytes, u64, record.max_update_index);
        try appendString(&bytes, record.min_ref_name);
        try appendString(&bytes, record.max_ref_name);
        try appendString(&bytes, record.min_reflog_ref_name);
        try appendString(&bytes, record.max_reflog_ref_name);
        try appendInt(&bytes, i64, record.min_reflog_ts);
        try appendInt(&bytes, i64, record.max_reflog_ts);
        try bytes.append(if (record.has_tombstones) 1 else 0);
    }

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes.items);
    var checksum: [32]u8 = undefined;
    hasher.final(checksum[0..]);
    try bytes.appendSlice(checksum[0..]);

    try root.makePath("reftable/info");
    const temp_path = reftable_summary_path ++ ".tmp";
    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};
    try file.writeAll(bytes.items);
    if (fsync != .none) try file.sync();
    root.rename(temp_path, reftable_summary_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(reftable_summary_path) catch {};
            try root.rename(temp_path, reftable_summary_path);
        },
        else => return err,
    };
    if (fsync != .none) {
        var root_for_sync = root;
        try syncDir(&root_for_sync);
    }
}

fn loadReftableSummaryIndex(alloc: std.mem.Allocator, root: std.fs.Dir) !ReftableSummaryIndex {
    const bytes = try root.readFileAlloc(alloc, reftable_summary_path, 16 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < reftable_summary_magic.len + @sizeOf(u16) + @sizeOf(u32) + 32) return error.CorruptReftableSummary;
    if (!std.mem.eql(u8, bytes[0..reftable_summary_magic.len], reftable_summary_magic)) return error.CorruptReftableSummary;

    const checksum_start = bytes.len - 32;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes[0..checksum_start]);
    var expected_checksum: [32]u8 = undefined;
    hasher.final(expected_checksum[0..]);
    if (!std.mem.eql(u8, expected_checksum[0..], bytes[checksum_start..])) return error.CorruptReftableSummary;

    var cursor = Cursor{ .bytes = bytes[reftable_summary_magic.len..checksum_start] };
    const version = try cursor.readInt(u16);
    if (version != 1) return error.UnsupportedReftableSummaryVersion;
    const record_count = try cursor.readInt(u32);
    const records = try alloc.alloc(ReftableSummaryRecord, record_count);
    var loaded_count: usize = 0;
    errdefer {
        for (records[0..loaded_count]) |*record| record.deinit(alloc);
        alloc.free(records);
    }
    for (records) |*record| {
        record.* = .{
            .table_name = try cursor.readOwnedString(alloc),
            .min_update_index = try cursor.readInt(u64),
            .max_update_index = try cursor.readInt(u64),
            .min_ref_name = try cursor.readOwnedString(alloc),
            .max_ref_name = try cursor.readOwnedString(alloc),
            .min_reflog_ref_name = try cursor.readOwnedString(alloc),
            .max_reflog_ref_name = try cursor.readOwnedString(alloc),
            .min_reflog_ts = try cursor.readInt(i64),
            .max_reflog_ts = try cursor.readInt(i64),
            .has_tombstones = (try cursor.readByte()) != 0,
        };
        loaded_count += 1;
    }
    try cursor.finish();
    return .{ .records = records };
}

fn loadOrScanReftableSummaryIndex(alloc: std.mem.Allocator, root: std.fs.Dir) !ReftableSummaryIndex {
    return loadReftableSummaryIndex(alloc, root) catch |err| switch (err) {
        error.FileNotFound,
        error.CorruptReftableSummary,
        error.UnsupportedReftableSummaryVersion,
        => try scanReftableSummaryIndex(alloc, root),
        else => return err,
    };
}

fn summaryContainsRef(record: ReftableSummaryRecord, ref_name: []const u8) bool {
    if (record.min_ref_name.len == 0 and record.max_ref_name.len == 0) return true;
    return std.mem.order(u8, ref_name, record.min_ref_name) != .lt and
        std.mem.order(u8, ref_name, record.max_ref_name) != .gt;
}

fn summaryContainsReflog(record: ReftableSummaryRecord, ref_name: []const u8) bool {
    if (record.min_reflog_ref_name.len == 0 and record.max_reflog_ref_name.len == 0) return true;
    return std.mem.order(u8, ref_name, record.min_reflog_ref_name) != .lt and
        std.mem.order(u8, ref_name, record.max_reflog_ref_name) != .gt;
}

fn writeReftableTable(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    table_path: []const u8,
    span: ReftableSpan,
    refs: []const ReftableRefRecord,
    reflogs: []const ReflogEntry,
    fsync: cfg.FsyncPolicy,
) !void {
    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{table_path});
    defer alloc.free(temp_path);

    const sorted_refs = try alloc.dupe(ReftableRefRecord, refs);
    defer alloc.free(sorted_refs);
    std.sort.block(ReftableRefRecord, sorted_refs, {}, struct {
        fn lessThan(_: void, lhs: ReftableRefRecord, rhs: ReftableRefRecord) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    const sorted_reflogs = try alloc.dupe(ReflogEntry, reflogs);
    defer alloc.free(sorted_reflogs);
    std.sort.block(ReflogEntry, sorted_reflogs, {}, struct {
        fn lessThan(_: void, lhs: ReflogEntry, rhs: ReflogEntry) bool {
            const by_name = std.mem.order(u8, lhs.ref_name, rhs.ref_name);
            if (by_name != .eq) return by_name == .lt;
            if (lhs.timestamp_ms != rhs.timestamp_ms) return lhs.timestamp_ms < rhs.timestamp_ms;
            return std.mem.lessThan(u8, lhs.reason, rhs.reason);
        }
    }.lessThan);

    var ref_index = std.array_list.Managed(ReftableBlockIndexEntry).init(alloc);
    defer {
        for (ref_index.items) |*entry| entry.deinit(alloc);
        ref_index.deinit();
    }
    var reflog_index = std.array_list.Managed(ReftableBlockIndexEntry).init(alloc);
    defer {
        for (reflog_index.items) |*entry| entry.deinit(alloc);
        reflog_index.deinit();
    }

    var bytes = std.array_list.Managed(u8).init(alloc);
    defer bytes.deinit();

    try bytes.appendSlice(reftable_magic);
    try appendInt(&bytes, u16, reftable_current_version);
    try appendInt(&bytes, u64, span.min_update_index);
    try appendInt(&bytes, u64, span.max_update_index);
    try appendInt(&bytes, u32, 0); // ref block count placeholder
    try appendInt(&bytes, u32, 0); // reflog block count placeholder
    try appendInt(&bytes, u64, @intCast(sorted_refs.len));
    try appendInt(&bytes, u64, @intCast(sorted_reflogs.len));
    const ref_index_offset_pos = bytes.items.len;
    try appendInt(&bytes, u64, 0);
    const reflog_index_offset_pos = bytes.items.len;
    try appendInt(&bytes, u64, 0);

    var ref_start: usize = 0;
    while (ref_start < sorted_refs.len) : (ref_start += reftable_ref_block_entries) {
        const ref_end = @min(sorted_refs.len, ref_start + reftable_ref_block_entries);
        try ref_index.append(.{
            .first_key = try alloc.dupe(u8, sorted_refs[ref_start].name),
            .block_offset = bytes.items.len,
        });
        try appendInt(&bytes, u16, @intCast(ref_end - ref_start));
        for (sorted_refs[ref_start..ref_end]) |entry| {
            try appendString(&bytes, entry.name);
            try bytes.append(if (entry.id != null) 1 else 0);
            if (entry.id) |id| try bytes.appendSlice(id.hash[0..]);
        }
    }

    var reflog_start: usize = 0;
    while (reflog_start < sorted_reflogs.len) : (reflog_start += reftable_reflog_block_entries) {
        const reflog_end = @min(sorted_reflogs.len, reflog_start + reftable_reflog_block_entries);
        try reflog_index.append(.{
            .first_key = try alloc.dupe(u8, sorted_reflogs[reflog_start].ref_name),
            .block_offset = bytes.items.len,
        });
        try appendInt(&bytes, u16, @intCast(reflog_end - reflog_start));
        for (sorted_reflogs[reflog_start..reflog_end]) |entry| {
            try appendString(&bytes, entry.ref_name);
            try bytes.append(if (entry.old_id != null) 1 else 0);
            if (entry.old_id) |old_id| try bytes.appendSlice(old_id.hash[0..]);
            try bytes.appendSlice(entry.new_id.hash[0..]);
            try appendInt(&bytes, i64, entry.timestamp_ms);
            try appendString(&bytes, entry.reason);
        }
    }

    const ref_index_offset = bytes.items.len;
    try appendInt(&bytes, u32, @intCast(ref_index.items.len));
    for (ref_index.items) |entry| {
        try appendString(&bytes, entry.first_key);
        try appendInt(&bytes, u64, entry.block_offset);
    }

    const reflog_index_offset = bytes.items.len;
    try appendInt(&bytes, u32, @intCast(reflog_index.items.len));
    for (reflog_index.items) |entry| {
        try appendString(&bytes, entry.first_key);
        try appendInt(&bytes, u64, entry.block_offset);
    }

    std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(bytes.items[(reftable_magic.len + @sizeOf(u16) + @sizeOf(u64) * 2)..][0..4].ptr)), @intCast(ref_index.items.len), .little);
    std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(bytes.items[(reftable_magic.len + @sizeOf(u16) + @sizeOf(u64) * 2 + @sizeOf(u32))..][0..4].ptr)), @intCast(reflog_index.items.len), .little);
    std.mem.writeInt(u64, @as(*[8]u8, @ptrCast(bytes.items[ref_index_offset_pos .. ref_index_offset_pos + @sizeOf(u64)].ptr)), @intCast(ref_index_offset), .little);
    std.mem.writeInt(u64, @as(*[8]u8, @ptrCast(bytes.items[reflog_index_offset_pos .. reflog_index_offset_pos + @sizeOf(u64)].ptr)), @intCast(reflog_index_offset), .little);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes.items);
    var checksum: [32]u8 = undefined;
    hasher.final(checksum[0..]);
    try bytes.appendSlice(checksum[0..]);

    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};
    try file.writeAll(bytes.items);
    if (fsync != .none) {
        try file.sync();
    }
    root.rename(temp_path, table_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(table_path) catch {};
            try root.rename(temp_path, table_path);
        },
        else => return err,
    };
    if (fsync != .none) {
        var root_for_sync = root;
        try syncDir(&root_for_sync);
    }
}

fn loadReftableHeaderV3(bytes: []const u8) !ReftableHeaderV3 {
    if (bytes.len < reftable_magic.len + @sizeOf(u16) + @sizeOf(u64) * 6 + @sizeOf(u32) * 2 + 32) return error.CorruptReftable;
    const checksum_start = bytes.len - 32;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes[0..checksum_start]);
    var expected_checksum: [32]u8 = undefined;
    hasher.final(expected_checksum[0..]);
    if (!std.mem.eql(u8, expected_checksum[0..], bytes[checksum_start..])) return error.CorruptReftable;

    var cursor = Cursor{ .bytes = bytes, .index = reftable_magic.len + @sizeOf(u16) };
    return .{
        .span = .{
            .min_update_index = try cursor.readInt(u64),
            .max_update_index = try cursor.readInt(u64),
        },
        .ref_block_count = try cursor.readInt(u32),
        .reflog_block_count = try cursor.readInt(u32),
        .ref_entry_count = try cursor.readInt(u64),
        .reflog_entry_count = try cursor.readInt(u64),
        .ref_index_offset = try cursor.readInt(u64),
        .reflog_index_offset = try cursor.readInt(u64),
        .checksum_start = checksum_start,
    };
}

fn loadReftableBlockIndex(
    alloc: std.mem.Allocator,
    _: []const u8,
    cursor: *Cursor,
    count: u32,
) ![]ReftableBlockIndexEntry {
    const entries = try alloc.alloc(ReftableBlockIndexEntry, count);
    var loaded_count: usize = 0;
    errdefer {
        for (entries[0..loaded_count]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    for (entries) |*entry| {
        entry.* = .{
            .first_key = try cursor.readOwnedString(alloc),
            .block_offset = try cursor.readInt(u64),
        };
        loaded_count += 1;
    }
    return entries;
}

fn decodeReftableRefBlockAt(alloc: std.mem.Allocator, bytes: []const u8, block_offset: u64) ![]ReftableRefRecord {
    var cursor = Cursor{ .bytes = bytes, .index = @intCast(block_offset) };
    const entry_count = try cursor.readInt(u16);
    const entries = try alloc.alloc(ReftableRefRecord, entry_count);
    var loaded_count: usize = 0;
    errdefer {
        for (entries[0..loaded_count]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    for (entries) |*entry| {
        const name = try cursor.readOwnedString(alloc);
        errdefer alloc.free(name);
        entry.* = .{
            .name = name,
            .id = switch (try cursor.readByte()) {
                0 => null,
                1 => .{ .hash = try cursor.readHash() },
                else => return error.CorruptReftable,
            },
        };
        loaded_count += 1;
    }
    return entries;
}

fn decodeReftableReflogBlockAt(alloc: std.mem.Allocator, bytes: []const u8, block_offset: u64) ![]ReflogEntry {
    var cursor = Cursor{ .bytes = bytes, .index = @intCast(block_offset) };
    const entry_count = try cursor.readInt(u16);
    const entries = try alloc.alloc(ReflogEntry, entry_count);
    var loaded_count: usize = 0;
    errdefer {
        for (entries[0..loaded_count]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    for (entries) |*entry| {
        const ref_name = try cursor.readOwnedString(alloc);
        errdefer alloc.free(ref_name);
        const old_id = switch (try cursor.readByte()) {
            0 => null,
            1 => object_store.ObjectId{ .hash = try cursor.readHash() },
            else => return error.CorruptReftable,
        };
        const new_id: object_store.ObjectId = .{ .hash = try cursor.readHash() };
        const timestamp_ms = try cursor.readInt(i64);
        const reason = try cursor.readOwnedString(alloc);
        errdefer alloc.free(reason);
        entry.* = .{
            .ref_name = ref_name,
            .old_id = old_id,
            .new_id = new_id,
            .timestamp_ms = timestamp_ms,
            .reason = reason,
        };
        loaded_count += 1;
    }
    return entries;
}

fn loadReftableTable(alloc: std.mem.Allocator, root: std.fs.Dir, table_path: []const u8) !ReftableTable {
    const bytes = try root.readFileAlloc(alloc, table_path, 16 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < reftable_magic.len + @sizeOf(u16) + @sizeOf(u64) * 2) return error.CorruptReftable;
    if (!std.mem.eql(u8, bytes[0..reftable_magic.len], reftable_magic)) return error.CorruptReftable;

    var cursor = Cursor{ .bytes = bytes, .index = reftable_magic.len };
    const version = try cursor.readInt(u16);
    if (version != 1 and version != 2 and version != 3) return error.UnsupportedReftableVersion;
    if (version == reftable_current_version) {
        const header = try loadReftableHeaderV3(bytes);

        cursor.index = @intCast(header.ref_index_offset);
        const ref_block_count = try cursor.readInt(u32);
        if (ref_block_count != header.ref_block_count) return error.CorruptReftable;
        const ref_index = try loadReftableBlockIndex(alloc, bytes[0..header.checksum_start], &cursor, ref_block_count);
        defer {
            for (ref_index) |*entry| entry.deinit(alloc);
            alloc.free(ref_index);
        }

        cursor.index = @intCast(header.reflog_index_offset);
        const reflog_block_count = try cursor.readInt(u32);
        if (reflog_block_count != header.reflog_block_count) return error.CorruptReftable;
        const reflog_index = try loadReftableBlockIndex(alloc, bytes[0..header.checksum_start], &cursor, reflog_block_count);
        defer {
            for (reflog_index) |*entry| entry.deinit(alloc);
            alloc.free(reflog_index);
        }

        var refs = std.array_list.Managed(ReftableRefRecord).init(alloc);
        errdefer {
            for (refs.items) |*entry| entry.deinit(alloc);
            refs.deinit();
        }
        for (ref_index) |entry| {
            const block_entries = try decodeReftableRefBlockAt(alloc, bytes[0..header.checksum_start], entry.block_offset);
            defer {
                for (block_entries) |*record| record.deinit(alloc);
                alloc.free(block_entries);
            }
            for (block_entries) |record| {
                try refs.append(.{
                    .name = try alloc.dupe(u8, record.name),
                    .id = record.id,
                });
            }
        }

        var reflogs = std.array_list.Managed(ReflogEntry).init(alloc);
        errdefer {
            for (reflogs.items) |*entry| entry.deinit(alloc);
            reflogs.deinit();
        }
        for (reflog_index) |entry| {
            const block_entries = try decodeReftableReflogBlockAt(alloc, bytes[0..header.checksum_start], entry.block_offset);
            defer {
                for (block_entries) |*record| record.deinit(alloc);
                alloc.free(block_entries);
            }
            for (block_entries) |record| {
                try reflogs.append(.{
                    .ref_name = try alloc.dupe(u8, record.ref_name),
                    .old_id = record.old_id,
                    .new_id = record.new_id,
                    .timestamp_ms = record.timestamp_ms,
                    .reason = try alloc.dupe(u8, record.reason),
                });
            }
        }

        return .{
            .refs = try refs.toOwnedSlice(),
            .reflogs = try reflogs.toOwnedSlice(),
            .min_update_index = header.span.min_update_index,
            .max_update_index = header.span.max_update_index,
            .size_bytes = header.checksum_start,
        };
    }

    const span = if (version == 2)
        ReftableSpan{
            .min_update_index = try cursor.readInt(u64),
            .max_update_index = try cursor.readInt(u64),
        }
    else
        parseReftableSpanFromName(table_path) orelse ReftableSpan{
            .min_update_index = 0,
            .max_update_index = 0,
        };
    const ref_count = try cursor.readInt(u64);
    const reflog_count = try cursor.readInt(u64);

    const refs = try alloc.alloc(ReftableRefRecord, @intCast(ref_count));
    var refs_loaded: usize = 0;
    errdefer {
        for (refs[0..refs_loaded]) |*entry| entry.deinit(alloc);
        alloc.free(refs);
    }
    for (refs) |*entry| {
        const name_len = try cursor.readInt(u16);
        const name = try cursor.readBytes(alloc, name_len);
        errdefer alloc.free(name);
        const id = if (version == 2)
            switch (try cursor.readByte()) {
                0 => null,
                1 => object_store.ObjectId{ .hash = try cursor.readHash() },
                else => return error.CorruptReftable,
            }
        else
            object_store.ObjectId{ .hash = try cursor.readHash() };
        entry.* = .{ .name = name, .id = id };
        refs_loaded += 1;
    }

    const reflogs = try alloc.alloc(ReflogEntry, @intCast(reflog_count));
    var reflogs_loaded: usize = 0;
    errdefer {
        for (reflogs[0..reflogs_loaded]) |*entry| entry.deinit(alloc);
        alloc.free(reflogs);
    }
    for (reflogs) |*entry| {
        const name_len = try cursor.readInt(u16);
        const ref_name = try cursor.readBytes(alloc, name_len);
        errdefer alloc.free(ref_name);
        const has_old = try cursor.readByte();
        const old_id: ?object_store.ObjectId = if (has_old == 1) .{ .hash = try cursor.readHash() } else null;
        const new_id: object_store.ObjectId = .{ .hash = try cursor.readHash() };
        const timestamp_ms = try cursor.readInt(i64);
        const reason_len = try cursor.readInt(u16);
        const reason = try cursor.readBytes(alloc, reason_len);
        errdefer alloc.free(reason);
        entry.* = .{
            .ref_name = ref_name,
            .old_id = old_id,
            .new_id = new_id,
            .timestamp_ms = timestamp_ms,
            .reason = reason,
        };
        reflogs_loaded += 1;
    }
    try cursor.finish();
    return .{
        .refs = refs,
        .reflogs = reflogs,
        .min_update_index = span.min_update_index,
        .max_update_index = span.max_update_index,
        .size_bytes = bytes.len,
    };
}

fn readReftableRefWithCursor(alloc: std.mem.Allocator, root: std.fs.Dir, ref_name: []const u8) !?object_store.ObjectId {
    var summary = try loadOrScanReftableSummaryIndex(alloc, root);
    defer summary.deinit(alloc);

    var idx = summary.records.len;
    while (idx > 0) {
        idx -= 1;
        const record = summary.records[idx];
        if (!summaryContainsRef(record, ref_name)) continue;
        switch (try readReftableRefFromTable(alloc, root, record.table_name, ref_name)) {
            .present => |id| return id,
            .tombstone => return null,
            .absent => {},
        }
    }
    return null;
}

fn listReftableRefsWithCursor(alloc: std.mem.Allocator, root: std.fs.Dir) ![]RefEntry {
    var summary = try loadOrScanReftableSummaryIndex(alloc, root);
    defer summary.deinit(alloc);

    var refs = std.array_list.Managed(RefEntry).init(alloc);
    errdefer {
        for (refs.items) |*entry| entry.deinit(alloc);
        refs.deinit();
    }
    var seen_names = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (seen_names.items) |name| alloc.free(name);
        seen_names.deinit();
    }

    var idx = summary.records.len;
    while (idx > 0) {
        idx -= 1;
        const records = try loadReftableRefRecordsForTable(alloc, root, summary.records[idx].table_name);
        defer {
            for (records) |*entry| entry.deinit(alloc);
            alloc.free(records);
        }
        for (records) |record| {
            if (containsString(seen_names.items, record.name)) continue;
            try seen_names.append(try alloc.dupe(u8, record.name));
            if (record.id) |id| {
                try refs.append(.{
                    .name = try alloc.dupe(u8, record.name),
                    .id = id,
                });
            }
        }
    }

    std.sort.block(RefEntry, refs.items, {}, struct {
        fn lessThan(_: void, lhs: RefEntry, rhs: RefEntry) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);
    return try refs.toOwnedSlice();
}

fn loadReftableReflogEntriesForRef(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    ref_name: []const u8,
    max_entries: usize,
) ![]ReflogEntry {
    var summary = try loadOrScanReftableSummaryIndex(alloc, root);
    defer summary.deinit(alloc);

    var entries = std.array_list.Managed(ReflogEntry).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    var idx = summary.records.len;
    while (idx > 0 and entries.items.len < max_entries) {
        idx -= 1;
        const record = summary.records[idx];
        if (!summaryContainsReflog(record, ref_name)) continue;
        const table_entries = try loadReftableReflogEntriesForRefInTable(alloc, root, record.table_name, ref_name);
        defer {
            for (table_entries) |*entry| entry.deinit(alloc);
            alloc.free(table_entries);
        }

        var entry_idx = table_entries.len;
        while (entry_idx > 0 and entries.items.len < max_entries) {
            entry_idx -= 1;
            const entry = table_entries[entry_idx];
            try entries.append(.{
                .ref_name = try alloc.dupe(u8, entry.ref_name),
                .old_id = entry.old_id,
                .new_id = entry.new_id,
                .timestamp_ms = entry.timestamp_ms,
                .reason = try alloc.dupe(u8, entry.reason),
            });
        }
    }
    return try entries.toOwnedSlice();
}

fn loadReftableRefRecordsForTable(alloc: std.mem.Allocator, root: std.fs.Dir, table_path: []const u8) ![]ReftableRefRecord {
    const bytes = try root.readFileAlloc(alloc, table_path, 16 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < reftable_magic.len + @sizeOf(u16) + @sizeOf(u64) * 2) return error.CorruptReftable;
    if (!std.mem.eql(u8, bytes[0..reftable_magic.len], reftable_magic)) return error.CorruptReftable;

    const version = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(bytes[reftable_magic.len .. reftable_magic.len + 2].ptr)), .little);
    if (version != reftable_current_version) {
        var table = try loadReftableTable(alloc, root, table_path);
        defer table.deinit(alloc);
        return try cloneReftableRefRecords(alloc, table.refs);
    }

    const header = try loadReftableHeaderV3(bytes);
    var cursor = Cursor{ .bytes = bytes, .index = @intCast(header.ref_index_offset) };
    const ref_block_count = try cursor.readInt(u32);
    const ref_index = try loadReftableBlockIndex(alloc, bytes[0..header.checksum_start], &cursor, ref_block_count);
    defer {
        for (ref_index) |*entry| entry.deinit(alloc);
        alloc.free(ref_index);
    }

    var refs = std.array_list.Managed(ReftableRefRecord).init(alloc);
    errdefer {
        for (refs.items) |*entry| entry.deinit(alloc);
        refs.deinit();
    }
    for (ref_index) |entry| {
        const block_entries = try decodeReftableRefBlockAt(alloc, bytes[0..header.checksum_start], entry.block_offset);
        defer {
            for (block_entries) |*record| record.deinit(alloc);
            alloc.free(block_entries);
        }
        for (block_entries) |record| {
            try refs.append(.{
                .name = try alloc.dupe(u8, record.name),
                .id = record.id,
            });
        }
    }
    return try refs.toOwnedSlice();
}

const ReftableLookup = union(enum) {
    absent,
    tombstone,
    present: object_store.ObjectId,
};

fn readReftableRefRecordState(records: []const ReftableRefRecord, ref_name: []const u8) ReftableLookup {
    for (records) |record| {
        if (!std.mem.eql(u8, record.name, ref_name)) continue;
        return if (record.id) |id|
            .{ .present = id }
        else
            .tombstone;
    }
    return .absent;
}

fn readReftableRefFromTable(alloc: std.mem.Allocator, root: std.fs.Dir, table_path: []const u8, ref_name: []const u8) !ReftableLookup {
    const bytes = try root.readFileAlloc(alloc, table_path, 16 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < reftable_magic.len + @sizeOf(u16) + @sizeOf(u64) * 2) return error.CorruptReftable;
    if (!std.mem.eql(u8, bytes[0..reftable_magic.len], reftable_magic)) return error.CorruptReftable;

    const version = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(bytes[reftable_magic.len .. reftable_magic.len + 2].ptr)), .little);
    if (version != reftable_current_version) {
        var table = try loadReftableTable(alloc, root, table_path);
        defer table.deinit(alloc);
        return readReftableRefRecordState(table.refs, ref_name);
    }

    const header = try loadReftableHeaderV3(bytes);
    var cursor = Cursor{ .bytes = bytes, .index = @intCast(header.ref_index_offset) };
    const ref_block_count = try cursor.readInt(u32);
    const ref_index = try loadReftableBlockIndex(alloc, bytes[0..header.checksum_start], &cursor, ref_block_count);
    defer {
        for (ref_index) |*entry| entry.deinit(alloc);
        alloc.free(ref_index);
    }

    var candidate_idx: ?usize = null;
    for (ref_index, 0..) |entry, idx| {
        if (std.mem.order(u8, entry.first_key, ref_name) == .gt) break;
        candidate_idx = idx;
    }
    if (candidate_idx == null) return .absent;

    const block_entries = try decodeReftableRefBlockAt(alloc, bytes[0..header.checksum_start], ref_index[candidate_idx.?].block_offset);
    defer {
        for (block_entries) |*record| record.deinit(alloc);
        alloc.free(block_entries);
    }
    return readReftableRefRecordState(block_entries, ref_name);
}

fn loadReftableReflogEntriesForRefInTable(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    table_path: []const u8,
    ref_name: []const u8,
) ![]ReflogEntry {
    const bytes = try root.readFileAlloc(alloc, table_path, 16 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < reftable_magic.len + @sizeOf(u16) + @sizeOf(u64) * 2) return error.CorruptReftable;
    if (!std.mem.eql(u8, bytes[0..reftable_magic.len], reftable_magic)) return error.CorruptReftable;

    const version = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(bytes[reftable_magic.len .. reftable_magic.len + 2].ptr)), .little);
    if (version != reftable_current_version) {
        var table = try loadReftableTable(alloc, root, table_path);
        defer table.deinit(alloc);
        var filtered = std.array_list.Managed(ReflogEntry).init(alloc);
        errdefer {
            for (filtered.items) |*entry| entry.deinit(alloc);
            filtered.deinit();
        }
        for (table.reflogs) |entry| {
            if (!std.mem.eql(u8, entry.ref_name, ref_name)) continue;
            try filtered.append(.{
                .ref_name = try alloc.dupe(u8, entry.ref_name),
                .old_id = entry.old_id,
                .new_id = entry.new_id,
                .timestamp_ms = entry.timestamp_ms,
                .reason = try alloc.dupe(u8, entry.reason),
            });
        }
        return try filtered.toOwnedSlice();
    }

    const header = try loadReftableHeaderV3(bytes);
    var cursor = Cursor{ .bytes = bytes, .index = @intCast(header.reflog_index_offset) };
    const reflog_block_count = try cursor.readInt(u32);
    const reflog_index = try loadReftableBlockIndex(alloc, bytes[0..header.checksum_start], &cursor, reflog_block_count);
    defer {
        for (reflog_index) |*entry| entry.deinit(alloc);
        alloc.free(reflog_index);
    }

    var filtered = std.array_list.Managed(ReflogEntry).init(alloc);
    errdefer {
        for (filtered.items) |*entry| entry.deinit(alloc);
        filtered.deinit();
    }
    for (reflog_index) |entry| {
        if (std.mem.order(u8, entry.first_key, ref_name) == .gt) break;
        const block_entries = try decodeReftableReflogBlockAt(alloc, bytes[0..header.checksum_start], entry.block_offset);
        defer {
            for (block_entries) |*record| record.deinit(alloc);
            alloc.free(block_entries);
        }
        for (block_entries) |record| {
            if (!std.mem.eql(u8, record.ref_name, ref_name)) continue;
            try filtered.append(.{
                .ref_name = try alloc.dupe(u8, record.ref_name),
                .old_id = record.old_id,
                .new_id = record.new_id,
                .timestamp_ms = record.timestamp_ms,
                .reason = try alloc.dupe(u8, record.reason),
            });
        }
    }
    return try filtered.toOwnedSlice();
}

fn cloneReftableRefRecords(alloc: std.mem.Allocator, records: []const ReftableRefRecord) ![]ReftableRefRecord {
    const cloned = try alloc.alloc(ReftableRefRecord, records.len);
    errdefer {
        for (cloned[0..]) |*entry| {
            if (entry.name.len != 0) entry.deinit(alloc);
        }
        alloc.free(cloned);
    }
    for (cloned) |*entry| entry.* = .{ .name = &[_]u8{}, .id = null };
    for (records, 0..) |record, idx| {
        cloned[idx] = .{
            .name = try alloc.dupe(u8, record.name),
            .id = record.id,
        };
    }
    return cloned;
}

fn loadReftableReflogEntries(alloc: std.mem.Allocator, root: std.fs.Dir) ![]ReflogEntry {
    const table_names = try loadReftableTableNames(alloc, root);
    defer freeOwnedStrings(alloc, table_names);

    var entries = std.array_list.Managed(ReflogEntry).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    for (table_names) |table_name| {
        var table = try loadReftableTable(alloc, root, table_name);
        defer table.deinit(alloc);
        for (table.reflogs) |entry| {
            try entries.append(.{
                .ref_name = try alloc.dupe(u8, entry.ref_name),
                .old_id = entry.old_id,
                .new_id = entry.new_id,
                .timestamp_ms = entry.timestamp_ms,
                .reason = try alloc.dupe(u8, entry.reason),
            });
        }
    }
    return try entries.toOwnedSlice();
}

fn loadLooseReflogEntries(alloc: std.mem.Allocator, root: std.fs.Dir) ![]ReflogEntry {
    const reflog_files = try listFilesRecursive(alloc, root, "logs/refs");
    defer freeOwnedStrings(alloc, reflog_files);

    var entries = std.array_list.Managed(ReflogEntry).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    for (reflog_files) |path| {
        const body = try root.readFileAlloc(alloc, path, 1024 * 1024);
        defer alloc.free(body);
        const ref_name = path["logs/refs/".len..];
        var line_it = std.mem.tokenizeScalar(u8, body, '\n');
        while (line_it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            const parsed = try parseLooseReflogEntry(alloc, ref_name, line);
            try entries.append(parsed);
        }
    }
    return try entries.toOwnedSlice();
}

fn loadLooseReflogEntriesForRef(alloc: std.mem.Allocator, root: std.fs.Dir, ref_name: []const u8) ![]ReflogEntry {
    const path = try std.fmt.allocPrint(alloc, "logs/refs/{s}", .{ref_name});
    defer alloc.free(path);

    const body = root.readFileAlloc(alloc, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc(ReflogEntry, 0),
        else => return err,
    };
    defer alloc.free(body);

    var entries = std.array_list.Managed(ReflogEntry).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    var line_it = std.mem.tokenizeScalar(u8, body, '\n');
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = try parseLooseReflogEntry(alloc, ref_name, line);
        try entries.append(parsed);
    }
    return try entries.toOwnedSlice();
}

fn selectReftableCompactionStart(alloc: std.mem.Allocator, root: std.fs.Dir, table_names: []const []const u8) !?usize {
    if (table_names.len <= 1) return null;

    var tables = try alloc.alloc(ReftableTable, table_names.len);
    defer {
        for (tables) |*table| table.deinit(alloc);
        alloc.free(tables);
    }

    for (table_names, 0..) |name, idx| {
        tables[idx] = try loadReftableTable(alloc, root, name);
    }

    var start = table_names.len - 1;
    var combined_span = effectiveReftableSpan(tables[start], @intCast(start));
    var combined_size = tables[start].size_bytes;

    while (start > 0) {
        const prev_idx = start - 1;
        const prev_span = effectiveReftableSpan(tables[prev_idx], @intCast(prev_idx));
        const should_merge = table_names.len > 8 or combined_size <= prev_span.size_bytes * 2 or combined_span.width() <= prev_span.width() * 2;
        if (!should_merge) break;
        start = prev_idx;
        combined_size += tables[prev_idx].size_bytes;
        combined_span = .{
            .min_update_index = @min(prev_span.min_update_index, combined_span.min_update_index),
            .max_update_index = @max(prev_span.max_update_index, combined_span.max_update_index),
            .size_bytes = combined_size,
        };
    }

    if (start == table_names.len - 1) return null;
    return start;
}

fn effectiveReftableSpan(table: ReftableTable, ordinal: u64) struct {
    min_update_index: u64,
    max_update_index: u64,
    size_bytes: u64,

    fn width(self: @This()) u64 {
        return if (self.max_update_index >= self.min_update_index)
            self.max_update_index - self.min_update_index + 1
        else
            0;
    }
} {
    const fallback = ordinal + 1;
    return .{
        .min_update_index = if (table.min_update_index == 0) fallback else table.min_update_index,
        .max_update_index = if (table.max_update_index == 0) fallback else table.max_update_index,
        .size_bytes = table.size_bytes,
    };
}

fn mergeReftableTables(alloc: std.mem.Allocator, root: std.fs.Dir, table_names: []const []const u8) !ReftableTable {
    var merged_refs = std.array_list.Managed(ReftableRefRecord).init(alloc);
    errdefer {
        for (merged_refs.items) |*record| record.deinit(alloc);
        merged_refs.deinit();
    }
    var merged_reflogs = std.array_list.Managed(ReflogEntry).init(alloc);
    errdefer {
        for (merged_reflogs.items) |*entry| entry.deinit(alloc);
        merged_reflogs.deinit();
    }
    var seen_names = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (seen_names.items) |name| alloc.free(name);
        seen_names.deinit();
    }

    var min_update_index: ?u64 = null;
    var max_update_index: u64 = 0;
    var total_size: u64 = 0;

    var idx = table_names.len;
    while (idx > 0) {
        idx -= 1;
        var table = try loadReftableTable(alloc, root, table_names[idx]);
        defer table.deinit(alloc);

        const span = effectiveReftableSpan(table, @intCast(idx));
        min_update_index = if (min_update_index) |current| @min(current, span.min_update_index) else span.min_update_index;
        max_update_index = @max(max_update_index, span.max_update_index);
        total_size += table.size_bytes;

        for (table.refs) |record| {
            if (containsString(seen_names.items, record.name)) continue;
            try seen_names.append(try alloc.dupe(u8, record.name));
            try merged_refs.append(.{
                .name = try alloc.dupe(u8, record.name),
                .id = record.id,
            });
        }
    }

    std.sort.block(ReftableRefRecord, merged_refs.items, {}, struct {
        fn lessThan(_: void, lhs: ReftableRefRecord, rhs: ReftableRefRecord) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    for (table_names) |name| {
        var table = try loadReftableTable(alloc, root, name);
        defer table.deinit(alloc);
        for (table.reflogs) |entry| {
            try merged_reflogs.append(.{
                .ref_name = try alloc.dupe(u8, entry.ref_name),
                .old_id = entry.old_id,
                .new_id = entry.new_id,
                .timestamp_ms = entry.timestamp_ms,
                .reason = try alloc.dupe(u8, entry.reason),
            });
        }
    }

    return .{
        .refs = try merged_refs.toOwnedSlice(),
        .reflogs = try merged_reflogs.toOwnedSlice(),
        .min_update_index = min_update_index orelse 0,
        .max_update_index = max_update_index,
        .size_bytes = total_size,
    };
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

fn readContentRefBytes(alloc: std.mem.Allocator, store: *object_store.ObjectStore, content: ContentRef) ![]u8 {
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

fn writeContentRefToPath(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    path: []const u8,
    content: ContentRef,
) !void {
    if (std.fs.path.dirname(path)) |dirname| try data_dir.makePath(dirname);
    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(temp_path);

    var file = try data_dir.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer data_dir.deleteFile(temp_path) catch {};
    var write_buf: [4096]u8 = undefined;
    var writer_state = file.writer(&write_buf);
    const writer = &writer_state.interface;
    switch (content) {
        .blob => |content_id| {
            if (try store.openPackedBlobReader(alloc, content_id)) |packed_reader| {
                var reader = packed_reader;
                defer reader.deinit();
                var scratch: [8192]u8 = undefined;
                while (true) {
                    const read_len = try reader.read(scratch[0..]);
                    if (read_len == 0) break;
                    try writer.writeAll(scratch[0..read_len]);
                }
                try reader.finish();
            } else {
                const loaded = try store.get(alloc, content_id);
                defer alloc.free(loaded.payload);
                if (loaded.obj_type != .blob) return error.InvalidContentBlobObject;
                try writer.writeAll(loaded.payload);
            }
        },
        .extent_tree => |tree| {
            var reader = try extents.openReader(alloc, store, tree);
            defer reader.deinit();
            var scratch: [8192]u8 = undefined;
            while (true) {
                const read_len = try reader.read(scratch[0..]);
                if (read_len == 0) break;
                try writer.writeAll(scratch[0..read_len]);
            }
            try reader.finish();
        },
    }
    try writer_state.end();
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

test "cas manager initializes a repository format marker for fresh repositories" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/repo-format", .{tmp_dir.sub_path});
    defer alloc.free(data_path);

    var cas_manager = try CasManager.init(alloc, data_path, .none);
    defer cas_manager.deinit();

    try std.testing.expectEqual(current_repository_format_version, cas_manager.format.version);
    try std.testing.expectEqual(RefBackend.reftable, cas_manager.format.ref_backend);
    try std.testing.expectEqual(default_extent_chunk_bytes, cas_manager.format.extent_chunk_bytes);

    const loaded = try loadRepositoryFormat(cas_manager.store.root);
    try std.testing.expectEqual(cas_manager.format.version, loaded.version);
    try std.testing.expectEqual(cas_manager.format.ref_backend, loaded.ref_backend);
    try std.testing.expectEqual(cas_manager.format.extent_chunk_bytes, loaded.extent_chunk_bytes);
}

test "cas manager persists repository identities across reopen" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/repo-id", .{tmp_dir.sub_path});
    defer alloc.free(data_path);

    var first = try CasManager.init(alloc, data_path, .none);
    const initial_id = first.repository_id;
    first.deinit();

    var reopened = try CasManager.init(alloc, data_path, .none);
    defer reopened.deinit();
    try std.testing.expect(initial_id.eql(reopened.repository_id));
}

test "cas manager keeps legacy-compatible repository format defaults for existing legacy data" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/legacy-repo-format", .{tmp_dir.sub_path});
    defer alloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();
    try data_dir.writeFile(.{ .sub_path = "MANIFEST", .data = "", .flags = .{} });

    var cas_manager = try CasManager.init(alloc, data_path, .none);
    defer cas_manager.deinit();

    try std.testing.expectEqual(legacy_repository_format_version, cas_manager.format.version);
    try std.testing.expectEqual(RefBackend.loose, cas_manager.format.ref_backend);
}

test "startup defaults prefer primary only for fresh or migrated repositories" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const fresh_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/startup-fresh", .{tmp_dir.sub_path});
    defer alloc.free(fresh_path);
    const fresh_defaults = try recommendedStartupDefaults(std.fs.cwd(), fresh_path);
    try std.testing.expectEqual(primary_startup_defaults.cas_mode, fresh_defaults.cas_mode);
    try std.testing.expectEqual(primary_startup_defaults.metadata_read_mode, fresh_defaults.metadata_read_mode);

    const legacy_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/startup-legacy", .{tmp_dir.sub_path});
    defer alloc.free(legacy_path);
    try std.fs.cwd().makePath(legacy_path);
    var legacy_dir = try std.fs.cwd().openDir(legacy_path, .{ .iterate = true });
    defer legacy_dir.close();
    try legacy_dir.writeFile(.{ .sub_path = "MANIFEST", .data = "", .flags = .{} });
    const legacy_defaults = try recommendedStartupDefaults(std.fs.cwd(), legacy_path);
    try std.testing.expectEqual(legacy_startup_defaults.cas_mode, legacy_defaults.cas_mode);
    try std.testing.expectEqual(legacy_startup_defaults.metadata_read_mode, legacy_defaults.metadata_read_mode);

    const migrated_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/startup-migrated", .{tmp_dir.sub_path});
    defer alloc.free(migrated_path);
    var cas_manager = try CasManager.init(alloc, migrated_path, .none);
    defer cas_manager.deinit();
    const migrated_defaults = try recommendedStartupDefaults(std.fs.cwd(), migrated_path);
    try std.testing.expectEqual(primary_startup_defaults.cas_mode, migrated_defaults.cas_mode);
    try std.testing.expectEqual(primary_startup_defaults.metadata_read_mode, migrated_defaults.metadata_read_mode);
}

test "upgrade repository migrates legacy refs to reftable and refreshes format" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/upgrade-repo", .{tmp.sub_path});
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

    const sid = types.hash64("upgrade.series");
    _ = try series_catalog.register("upgrade.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 1.5 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const head = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);

    cas_manager.refs.root.deleteTree("reftable") catch {};
    try cas_manager.refs.root.makePath("reftable");
    try cas_manager.refs.writeRefFileAtomic(main_ref, head);
    cas_manager.refs.setBackend(.loose);
    cas_manager.format = legacyCompatibleRepositoryFormat();
    try writeRepositoryFormat(talloc, cas_manager.store.root, cas_manager.format, .none);

    const result = try cas_manager.upgradeRepository(data_dir);
    try std.testing.expect(result.migrated_reftable);
    try std.testing.expectEqual(current_repository_format_version, result.format_version);
    try std.testing.expectEqual(RefBackend.reftable, result.ref_backend);

    const upgraded_head = try cas_manager.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(upgraded_head.eql(head));
    const state = try loadReftableState(talloc, cas_manager.refs.root);
    try std.testing.expect(state.next_update_index >= 2);
}

test "upgrade normalizes active commits to canonical roots and clears compatibility debt" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/upgrade-normalize", .{tmp.sub_path});
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

    const sid = types.hash64("upgrade.normalize.series");
    _ = try series_catalog.register("upgrade.normalize.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 9.5 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const current_head = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);

    var reader = CommitReader{ .alloc = talloc, .store = &cas_manager.store, .refs = &cas_manager.refs };
    var snapshot = try reader.loadHeadSnapshot();
    defer snapshot.deinit(talloc);

    const legacy_descriptors = try talloc.alloc(SegmentDescriptor, snapshot.segment_descriptors.len);
    var initialized_legacy_descriptors: usize = 0;
    var legacy_descriptors_adopted = false;
    errdefer if (!legacy_descriptors_adopted) {
        for (legacy_descriptors[0..initialized_legacy_descriptors]) |*descriptor| {
            descriptor.deinit(talloc);
        }
        talloc.free(legacy_descriptors);
    };
    for (snapshot.segment_descriptors, 0..) |descriptor, idx| {
        legacy_descriptors[idx] = try cloneSegmentDescriptor(talloc, descriptor);
        legacy_descriptors[idx].segment_root = null;
        initialized_legacy_descriptors = idx + 1;
    }

    const legacy_wal_entries = try talloc.alloc(WalChunkDescriptor, snapshot.wal_index.entries.len);
    var initialized_legacy_wal_entries: usize = 0;
    var legacy_wal_entries_adopted = false;
    errdefer if (!legacy_wal_entries_adopted) {
        for (legacy_wal_entries[0..initialized_legacy_wal_entries]) |*entry| {
            entry.deinit(talloc);
        }
        talloc.free(legacy_wal_entries);
    };
    for (snapshot.wal_index.entries, 0..) |entry, idx| {
        legacy_wal_entries[idx] = try cloneWalChunkDescriptor(talloc, entry);
        legacy_wal_entries[idx].journal_root = null;
        initialized_legacy_wal_entries = idx + 1;
    }

    var legacy_snapshot = LegacySnapshot{
        .segment_descriptors = legacy_descriptors,
        .tag_snapshot = try cloneTagSnapshot(talloc, snapshot.tag_snapshot),
        .series_catalog_snapshot = try cloneSeriesCatalogSnapshot(talloc, snapshot.series_catalog_snapshot),
        .wal_index = .{ .entries = legacy_wal_entries },
        .checkpoint_state = try buildCheckpointState(talloc, legacy_descriptors, legacy_wal_entries),
    };
    legacy_descriptors_adopted = true;
    legacy_wal_entries_adopted = true;
    defer legacy_snapshot.deinit(talloc);

    var writer = CommitWriter{ .alloc = talloc, .store = &cas_manager.store, .extent_chunk_bytes = cas_manager.format.extent_chunk_bytes };
    const legacy_like_head = try writer.writeCanonicalSnapshot(&legacy_snapshot, snapshot.commit.parents, snapshot.commit.created_at_ms, "legacy-like");
    try cas_manager.refs.compareAndSwapRef(main_ref, current_head, legacy_like_head, "legacy-like");
    try cas_manager.refreshCommitGraph();

    const before = try cas_manager.fsck(data_dir, .{});
    try std.testing.expect(before.compatibility_debt.legacy_segment_descriptors > 0);
    if (legacy_snapshot.wal_index.entries.len != 0) {
        try std.testing.expect(before.compatibility_debt.legacy_wal_descriptors > 0);
    } else {
        try std.testing.expectEqual(@as(usize, 0), before.compatibility_debt.legacy_wal_descriptors);
    }

    const upgraded = try cas_manager.upgradeRepository(data_dir);
    try std.testing.expect(upgraded.normalized_commits > 0);
    try std.testing.expectEqual(current_repository_format_version, upgraded.format_version);

    const after = try cas_manager.fsck(data_dir, .{});
    try std.testing.expectEqual(@as(usize, 0), after.compatibility_debt.legacy_segment_descriptors);
    try std.testing.expectEqual(@as(usize, 0), after.compatibility_debt.legacy_wal_descriptors);
}

test "repair rebuilds pack sidecars side indexes and reftable metadata" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/repair-repo", .{tmp.sub_path});
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

    const sid = types.hash64("repair.series");
    _ = try series_catalog.register("repair.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 6.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    _ = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    _ = try cas_manager.pack();
    try cas_manager.migrateToReftable(data_dir);

    cas_manager.store.root.deleteFile(commit_graph_path) catch {};
    cas_manager.store.root.deleteFile(reachability_bitmap_path) catch {};
    cas_manager.store.root.deleteFile(object_refs_index_path) catch {};
    cas_manager.store.root.deleteFile("objects/info/multi-pack-index") catch {};
    cas_manager.refs.root.deleteFile(reftable_tables_list_path) catch {};
    cas_manager.refs.root.deleteFile(reftable_state_path) catch {};

    var pack_dir = try cas_manager.store.root.openDir("objects/packs", .{ .iterate = true });
    defer pack_dir.close();
    var pack_it = pack_dir.iterate();
    while (try pack_it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".rev") or std.mem.endsWith(u8, entry.name, ".manifest")) {
            try pack_dir.deleteFile(entry.name);
        }
    }

    const report = try cas_manager.repairRepository(data_dir, .{});
    try std.testing.expect(report.pack_sidecars_rebuilt > 0);
    try std.testing.expect(report.side_indexes_rebuilt);
    try std.testing.expect(report.reftable_state_rebuilt);
    try std.testing.expect(report.reftable_tables_list_rebuilt);

    _ = try cas_manager.store.root.statFile(commit_graph_path);
    _ = try cas_manager.store.root.statFile(reachability_bitmap_path);
    _ = try cas_manager.store.root.statFile(object_refs_index_path);
    _ = try cas_manager.store.root.statFile("objects/info/multi-pack-index");
    _ = try cas_manager.refs.root.statFile(reftable_tables_list_path);
    _ = try cas_manager.refs.root.statFile(reftable_state_path);
    _ = try cas_manager.fsck(data_dir, .{});
}

test "expire trims loose reflogs checkpoints and borrowed alternates" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/expire-source", .{tmp.sub_path});
    defer talloc.free(source_path);
    const dest_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/expire-dest", .{tmp.sub_path});
    defer talloc.free(dest_path);
    try std.fs.cwd().makePath(source_path);
    try std.fs.cwd().makePath(dest_path);

    var source_dir = try std.fs.cwd().openDir(source_path, .{ .iterate = true });
    defer source_dir.close();
    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, source_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("expire.series");
    _ = try series_catalog.register("expire.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 4.25 }};
    const seg_path = try segment_mod.writeSegment(talloc, source_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(source_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var source_cas = try CasManager.init(talloc, source_path, .none);
    defer source_cas.deinit();
    const head = try source_cas.bootstrapIfMissing(source_dir, &manifest, &tags, &series_catalog);

    var dest_dir = try std.fs.cwd().openDir(dest_path, .{ .iterate = true });
    defer dest_dir.close();
    var dest_cas = try CasManager.init(talloc, dest_path, .none);
    defer dest_cas.deinit();

    dest_cas.format = legacyCompatibleRepositoryFormat();
    try writeRepositoryFormat(talloc, dest_cas.store.root, dest_cas.format, .none);
    dest_cas.refs.setBackend(.loose);
    try dest_cas.refs.root.deleteTree("reftable");
    try dest_cas.store.configureAlternates(talloc, &[_][]const u8{source_path});
    try dest_cas.refs.updateHeadAtomic(main_ref, head);

    const now_ms = std.time.milliTimestamp();
    const old_ms = now_ms - (10 * 60 * 1000);
    const zero_hex = [_]u8{'0'} ** 64;
    const head_hex = head.toHex();
    const loose_reflog = try std.fmt.allocPrint(
        talloc,
        "{d} {s} {s} old-main\n{d} {s} {s} recent-main\n",
        .{ old_ms, zero_hex, head_hex, now_ms, head_hex, head_hex },
    );
    defer talloc.free(loose_reflog);
    try dest_cas.refs.root.makePath("logs/refs/heads");
    try dest_cas.refs.root.writeFile(.{
        .sub_path = "logs/refs/heads/main",
        .data = loose_reflog,
        .flags = .{},
    });

    const old_checkpoint = try std.fmt.allocPrint(talloc, "checkpoints/old-{d}", .{old_ms});
    defer talloc.free(old_checkpoint);
    const recent_checkpoint = try std.fmt.allocPrint(talloc, "checkpoints/recent-{d}", .{now_ms});
    defer talloc.free(recent_checkpoint);
    try dest_cas.refs.updateRefAtomic(old_checkpoint, head);
    try dest_cas.refs.updateRefAtomic(recent_checkpoint, head);

    const expiry = try dest_cas.expire(dest_dir, .{
        .reflog_expiry_ms = 60 * 1000,
        .checkpoint_expiry_ms = 60 * 1000,
        .materialize_borrowed_packs = true,
    });
    try std.testing.expectEqual(@as(usize, 1), expiry.borrowed_packs_materialized);
    try std.testing.expectEqual(@as(usize, 1), expiry.reflog_entries_expired);
    try std.testing.expectEqual(@as(usize, 1), expiry.checkpoint_refs_expired);
    try std.testing.expectEqual(@as(usize, 0), dest_cas.store.alternates.repo_paths.len);
    try std.testing.expect(try dest_cas.store.hasLocalObject(talloc, head));
    try std.testing.expect((try dest_cas.refs.readRef(old_checkpoint)) == null);
    try std.testing.expect((try dest_cas.refs.readRef(recent_checkpoint)) != null);

    const reflog_entries = try dest_cas.loadReflog(main_ref, 8);
    defer {
        for (reflog_entries) |*entry| entry.deinit(talloc);
        talloc.free(reflog_entries);
    }
    try std.testing.expectEqual(@as(usize, 1), reflog_entries.len);
    try std.testing.expect(reflog_entries[0].timestamp_ms >= now_ms - 1_000);
}

test "prune only deletes expired cruft" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/prune-repo", .{tmp.sub_path});
    defer talloc.free(data_path);
    try std.fs.cwd().makePath(data_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();

    const now_ms = std.time.milliTimestamp();
    const old_stamp = now_ms - 10_000;
    const fresh_stamp = now_ms;
    const old_file = try std.fmt.allocPrint(talloc, "objects/cruft/{d}/packs/old.pack", .{old_stamp});
    defer talloc.free(old_file);
    const fresh_file = try std.fmt.allocPrint(talloc, "objects/cruft/{d}/packs/new.pack", .{fresh_stamp});
    defer talloc.free(fresh_file);
    try cas_manager.store.root.makePath(std.fs.path.dirname(old_file).?);
    try cas_manager.store.root.makePath(std.fs.path.dirname(fresh_file).?);
    try cas_manager.store.root.writeFile(.{ .sub_path = old_file, .data = "old-pack", .flags = .{} });
    try cas_manager.store.root.writeFile(.{ .sub_path = fresh_file, .data = "fresh-pack", .flags = .{} });

    const dry_run = try cas_manager.prune(.{
        .dry_run = true,
        .grace_period_ms = 1_000,
    });
    try std.testing.expect(dry_run.pruned_count > 0);
    _ = try cas_manager.store.root.statFile(old_file);

    const applied = try cas_manager.prune(.{ .grace_period_ms = 1_000 });
    try std.testing.expect(applied.pruned_count > 0);
    try std.testing.expectError(error.FileNotFound, cas_manager.store.root.statFile(old_file));
    _ = try cas_manager.store.root.statFile(fresh_file);
}

test "vacuum with policy preserves the active head and is idempotent" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/vacuum-repo", .{tmp.sub_path});
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

    const sid = types.hash64("vacuum.series");
    _ = try series_catalog.register("vacuum.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 3.5 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const initial = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    const orphan = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "vacuum-orphan");
    try std.testing.expect(!initial.eql(orphan));
    try cas_manager.refs.updateHeadAtomic(main_ref, initial);

    cas_manager.store.root.deleteFile(commit_graph_path) catch {};

    const first = try cas_manager.vacuumWithPolicy(data_dir, .{
        .repair_side_indexes = true,
        .prune_grace_ms = 0,
    });
    try std.testing.expect(first.pack.reachable_objects > 0);
    try std.testing.expect(first.repair.side_indexes_rebuilt);
    try std.testing.expect(first.gc.quarantined_count > 0 or first.gc.pruned_count > 0 or first.gc.deleted > 0);

    const second = try cas_manager.vacuumWithPolicy(data_dir, .{
        .repair_side_indexes = true,
        .prune_grace_ms = 0,
    });
    try std.testing.expectEqual(first.pack.reachable_objects, second.pack.reachable_objects);

    const head = try cas_manager.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(head.eql(initial));
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
    try std.testing.expect(snapshot.segment_descriptors[0].segment_root != null);
    try std.testing.expect(snapshot.segment_descriptors[0].contentRef() != null);
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

fn writeLegacyFlatReftableV2(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    table_path: []const u8,
    span: ReftableSpan,
    refs: []const RefEntry,
) !void {
    var bytes = std.array_list.Managed(u8).init(alloc);
    defer bytes.deinit();
    try bytes.appendSlice(reftable_magic);
    try appendInt(&bytes, u16, 2);
    try appendInt(&bytes, u64, span.min_update_index);
    try appendInt(&bytes, u64, span.max_update_index);
    try appendInt(&bytes, u64, @intCast(refs.len));
    try appendInt(&bytes, u64, 0);
    for (refs) |entry| {
        try appendInt(&bytes, u16, @intCast(entry.name.len));
        try bytes.appendSlice(entry.name);
        try bytes.append(1);
        try bytes.appendSlice(entry.id.hash[0..]);
    }

    var file = try root.createFile(table_path, .{ .truncate = true, .read = true });
    defer file.close();
    try file.writeAll(bytes.items);
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

test "reftable transactions assign update spans and compact older tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/reftable-spans", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var refs = try RefStore.init(std.testing.allocator, path, .none);
    defer refs.deinit();
    refs.setBackend(.reftable);

    var previous: ?object_store.ObjectId = null;
    var idx: usize = 0;
    while (idx < 12) : (idx += 1) {
        const payload = try std.fmt.allocPrint(std.testing.allocator, "reftable-span-{d}", .{idx});
        defer std.testing.allocator.free(payload);
        const next_id = object_store.computeId(.commit, payload);
        if (previous) |expected_old| {
            try refs.compareAndSwapRef(main_ref, expected_old, next_id, "advance-reftable");
        } else {
            try refs.updateRefAtomic(main_ref, next_id);
        }
        previous = next_id;
    }

    const state = try loadReftableState(std.testing.allocator, refs.root);
    try std.testing.expectEqual(@as(u64, 13), state.next_update_index);

    const table_names = try loadReftableTableNames(std.testing.allocator, refs.root);
    defer freeOwnedStrings(std.testing.allocator, table_names);
    try std.testing.expect(table_names.len < 12);

    var saw_compacted_span = false;
    for (table_names) |name| {
        const span = parseReftableSpanFromName(name) orelse continue;
        if (span.max_update_index > span.min_update_index) {
            saw_compacted_span = true;
            break;
        }
    }
    try std.testing.expect(saw_compacted_span);

    const sample_bytes = try refs.root.readFileAlloc(std.testing.allocator, table_names[0], 1024 * 1024);
    defer std.testing.allocator.free(sample_bytes);
    try std.testing.expect(sample_bytes.len > reftable_magic.len + 2);
    try std.testing.expect(std.mem.eql(u8, sample_bytes[0..reftable_magic.len], reftable_magic));
    try std.testing.expectEqual(reftable_current_version, std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(sample_bytes[reftable_magic.len .. reftable_magic.len + 2].ptr)), .little));
    _ = try refs.root.statFile(reftable_summary_path);

    const head = try refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(head.eql(previous.?));
}

test "legacy flat reftable tables remain readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/reftable-legacy-v2", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var refs = try RefStore.init(std.testing.allocator, path, .none);
    defer refs.deinit();
    refs.setBackend(.reftable);

    const legacy_id = object_store.computeId(.commit, "legacy-v2-head");
    const table_name = "reftable/1-1.table";
    var entries = [_]RefEntry{.{
        .name = try std.testing.allocator.dupe(u8, main_ref),
        .id = legacy_id,
    }};
    defer entries[0].deinit(std.testing.allocator);
    try writeLegacyFlatReftableV2(std.testing.allocator, refs.root, table_name, .{
        .min_update_index = 1,
        .max_update_index = 1,
    }, entries[0..]);
    try writeReftableTablesList(std.testing.allocator, refs.root, &[_][]const u8{table_name}, .none);

    const head = try refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(head.eql(legacy_id));
    const listed = try refs.listRefs(std.testing.allocator);
    defer {
        for (listed) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 1), listed.len);
}

test "reftable tombstones suppress older refs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/reftable-tombstone", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var refs = try RefStore.init(std.testing.allocator, path, .none);
    defer refs.deinit();
    refs.setBackend(.reftable);

    const first = object_store.computeId(.commit, "tombstone-first");
    try refs.updateRefAtomic(main_ref, first);

    var tombstones = [_]ReftableRefRecord{.{
        .name = try std.testing.allocator.dupe(u8, main_ref),
        .id = null,
    }};
    defer tombstones[0].deinit(std.testing.allocator);

    try refs.appendReftableRecords(tombstones[0..], &[_]ReflogEntry{});

    try std.testing.expect((try refs.readHead(main_ref)) == null);
    const listed = try refs.listRefs(std.testing.allocator);
    defer {
        for (listed) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 0), listed.len);
}

test "reftable delete rename and reflog views work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/reftable-ref-ops", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var refs = try RefStore.init(std.testing.allocator, path, .none);
    defer refs.deinit();
    refs.setBackend(.reftable);

    const first = object_store.computeId(.commit, "rename-first");
    try refs.updateRefAtomic(main_ref, first);
    try refs.renameRef(main_ref, "heads/renamed", "rename-ref");
    try std.testing.expect((try refs.readHead(main_ref)) == null);
    const renamed = try refs.readHead("heads/renamed") orelse return error.MissingCasHead;
    try std.testing.expect(renamed.eql(first));

    try refs.deleteRef("heads/renamed", "delete-ref");
    try std.testing.expect((try refs.readHead("heads/renamed")) == null);

    const reflog = try refs.loadReflog(std.testing.allocator, "heads/renamed", 8);
    defer {
        for (reflog) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(reflog);
    }
    try std.testing.expect(reflog.len >= 2);
    try std.testing.expect(std.mem.eql(u8, reflog[0].reason, "delete-ref") or std.mem.eql(u8, reflog[1].reason, "delete-ref"));
}

test "symrefs persist head targets alongside reftable refs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/symref-head", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var refs = try RefStore.init(std.testing.allocator, path, .none);
    defer refs.deinit();
    refs.setBackend(.reftable);

    const head_id = object_store.computeId(.commit, "symref-head");
    try refs.updateHeadAtomic(main_ref, head_id);
    try refs.writeSymRef("HEAD", main_ref);

    const restored = try refs.readSymRef("HEAD") orelse return error.MissingCasHead;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(main_ref, restored);
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
    try std.testing.expectEqual(@as(u16, changed_path_bloom_bytes), graph.changed_path_bloom_bytes);

    const advanced_idx = graph.lookup(advanced) orelse return error.CommitGraphMissingCommit;
    const initial_idx = graph.lookup(initial) orelse return error.CommitGraphMissingCommit;
    try std.testing.expect(graph.generations[advanced_idx] > graph.generations[initial_idx]);
    try std.testing.expectEqual(@as(usize, 1), @as(usize, @intCast(graph.parent_offsets[advanced_idx + 1] - graph.parent_offsets[advanced_idx])));
    try std.testing.expect(graph.object_ids[@intCast(graph.parent_positions[@intCast(graph.parent_offsets[advanced_idx])])].eql(initial));
    try std.testing.expect(graph.changedPathMayMatch(advanced, "metadata/segments"));

    const log_entries = try cas_manager.loadLog(main_ref, 8);
    defer {
        for (log_entries) |*entry| entry.deinit(talloc);
        talloc.free(log_entries);
    }
    try std.testing.expectEqual(@as(usize, 2), log_entries.len);
    try std.testing.expect(log_entries[0].commit_id.eql(advanced));
    try std.testing.expectEqualStrings("advance", log_entries[0].reason);
}

test "reachability bitmap falls back to graph walks when corrupt" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/reachability-bitmap", .{tmp.sub_path});
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

    const sid = types.hash64("bitmap.series");
    _ = try series_catalog.register("bitmap.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 5.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();

    _ = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    var bitmap = try loadReachabilityBitmap(talloc, cas_manager.store.root);
    bitmap.deinit(talloc);

    var file = try cas_manager.store.root.openFile(reachability_bitmap_path, .{ .mode = .read_write });
    defer file.close();
    try file.seekTo(0);
    try file.writeAll("BROKEN!!");

    const result = try cas_manager.pack();
    try std.testing.expect(result.reachable_objects > 0);

    bitmap = try loadReachabilityBitmap(talloc, cas_manager.store.root);
    defer bitmap.deinit(talloc);
    try std.testing.expect(bitmap.reachable_ids.len >= result.reachable_objects);
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

test "gc writes loose unreachable objects into cruft packs" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/gc-cruft-pack", .{tmp.sub_path});
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

    const sid = types.hash64("gc.cruft.pack");
    _ = try series_catalog.register("gc.cruft.pack", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 2.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    const initial = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    const orphan = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "cruft-pack-orphan");
    try std.testing.expect(!initial.eql(orphan));
    try cas_manager.refs.updateHeadAtomic(main_ref, initial);

    const applied = try cas_manager.gc(.{
        .dry_run = false,
        .include_reflogs = false,
        .grace_period_ms = std.time.ms_per_hour,
    });
    try std.testing.expect(applied.quarantined_count > 0);

    const cruft_files = try listFilesRecursive(talloc, cas_manager.store.root, "objects/cruft");
    defer freeOwnedStrings(talloc, cruft_files);

    var saw_pack = false;
    var saw_idx = false;
    var saw_manifest = false;
    for (cruft_files) |path| {
        if (std.mem.endsWith(u8, path, ".pack")) saw_pack = true;
        if (std.mem.endsWith(u8, path, ".idx")) saw_idx = true;
        if (std.mem.endsWith(u8, path, ".manifest")) saw_manifest = true;
        try std.testing.expect(std.mem.indexOf(u8, path, "/loose/") == null);
    }
    try std.testing.expect(saw_pack);
    try std.testing.expect(saw_idx);
    try std.testing.expect(saw_manifest);
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

test "fsck validates active pack manifests" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/fsck-pack-manifest", .{tmp.sub_path});
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

    const sid = types.hash64("fsck.pack.manifest");
    _ = try series_catalog.register("fsck.pack.manifest", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 8.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    _ = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    _ = try cas_manager.pack();

    var pack_dir = try cas_manager.store.root.openDir("objects/packs", .{ .iterate = true });
    defer pack_dir.close();

    var manifest_path: ?[]u8 = null;
    defer if (manifest_path) |path| talloc.free(path);
    var it = pack_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".manifest")) {
            manifest_path = try std.fmt.allocPrint(talloc, "objects/packs/{s}", .{entry.name});
            break;
        }
    }
    const path = manifest_path orelse return error.MissingPackManifest;

    var file = try cas_manager.store.root.openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.seekTo(0);
    try file.writeAll("BROKEN!!");

    try std.testing.expectError(error.CorruptPackManifest, cas_manager.fsck(data_dir, .{}));
}

test "cas pack preserves older packs while sealing newly reachable loose objects" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/pack-set", .{tmp.sub_path});
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

    const sid = types.hash64("pack.set.series");
    _ = try series_catalog.register("pack.set.series", "{}", sid);

    const first_points = [_]types.Point{.{ .ts = 1_000, .value = 1.0 }};
    const first_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, first_points[0..]);
    defer talloc.free(first_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, first_path);

    var cas_manager = try CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();

    const initial = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    const first_pack = try cas_manager.pack();
    try std.testing.expect(first_pack.rewritten_objects > 0);

    const second_points = [_]types.Point{.{ .ts = 2_000, .value = 2.0 }};
    const second_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, second_points[0..]);
    defer talloc.free(second_path);
    try manifest.add(data_dir, sid, 0, 2_000, 2_000, 1, second_path);

    const advanced = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, &series_catalog, "advance-pack-set");
    try std.testing.expect(!advanced.eql(initial));

    const second_pack = try cas_manager.pack();
    try std.testing.expect(second_pack.rewritten_objects > 0);

    var pack_dir = try cas_manager.store.root.openDir("objects/packs", .{ .iterate = true });
    defer pack_dir.close();
    var pack_count: usize = 0;
    var idx_count: usize = 0;
    var it = pack_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".pack")) pack_count += 1;
        if (std.mem.endsWith(u8, entry.name, ".idx")) idx_count += 1;
    }
    try std.testing.expect(pack_count >= 2);
    try std.testing.expect(idx_count >= 2);

    const head = try cas_manager.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(head.eql(advanced));
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
    const pack_result = try cas_manager.pack();
    try std.testing.expect(pack_result.rewritten_objects > 0);

    const created = try createBundle(talloc, data_path, bundle_path, .none, null);
    try std.testing.expect(created.ref_count > 0);
    try std.testing.expect(created.object_count > 0);
    try std.testing.expect(created.pack_count > 0);
    try std.testing.expect(created.reftable_file_count > 0);

    const verified = try verifyBundle(talloc, bundle_path);
    try std.testing.expectEqual(created.ref_count, verified.ref_count);
    try std.testing.expectEqual(created.object_count, verified.object_count);
    try std.testing.expectEqual(created.pack_count, verified.pack_count);
    try std.testing.expectEqual(created.reftable_file_count, verified.reftable_file_count);

    const applied = try applyBundle(talloc, bundle_path, restore_path, .none);
    try std.testing.expectEqual(verified.object_count, applied.object_count);
    try std.testing.expectEqual(verified.pack_count, applied.pack_count);

    var restored = try CasManager.init(talloc, restore_path, .none);
    defer restored.deinit();
    const restored_head = try restored.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(restored_head.eql(head));

    var restored_snapshot = try restored.loadHeadIndex();
    defer restored_snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored_snapshot.snapshot.segment_descriptors.len);
    try std.testing.expectEqual(@as(usize, 1), restored_snapshot.snapshot.tag_snapshot.entries.len);
    try std.testing.expectEqual(@as(usize, 1), restored_snapshot.snapshot.series_catalog_snapshot.entries.len);
    try std.testing.expect(restored.repository_id.eql(cas_manager.repository_id));

    var manifest_view = try readBundleManifest(talloc, bundle_path);
    defer manifest_view.deinit(talloc);
    try std.testing.expectEqual(@as(u16, 4), manifest_view.format_version);
    try std.testing.expect(manifest_view.pack_digests.len > 0);
}

test "local clone preserves pack files and reftable state" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/clone-src", .{tmp.sub_path});
    defer talloc.free(data_path);
    const clone_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/clone-dst", .{tmp.sub_path});
    defer talloc.free(clone_path);
    try std.fs.cwd().makePath(data_path);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    const sid = types.hash64("clone.series");
    _ = try series_catalog.register("clone.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 6.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(data_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var source = try CasManager.init(talloc, data_path, .none);
    defer source.deinit();
    const head = try source.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
    _ = try source.pack();

    const cloned = try cloneLocalRepository(talloc, data_path, clone_path, .none);
    try std.testing.expect(cloned.pack_count > 0);
    try std.testing.expect(cloned.reftable_file_count > 0);

    var clone = try CasManager.init(talloc, clone_path, .none);
    defer clone.deinit();
    try std.testing.expectEqual(source.format.ref_backend, clone.format.ref_backend);
    const cloned_head = try clone.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(cloned_head.eql(head));

    const pack_paths = try listFilesRecursive(talloc, clone.store.root, "objects/packs");
    defer freeOwnedStrings(talloc, pack_paths);
    var pack_count: usize = 0;
    for (pack_paths) |path| {
        if (std.mem.endsWith(u8, path, ".pack")) pack_count += 1;
    }
    try std.testing.expect(pack_count > 0);
}

test "local fetch borrows source repositories and tracks source refs" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const src_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/fetch-src", .{tmp.sub_path});
    defer talloc.free(src_path);
    const dst_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/fetch-dst", .{tmp.sub_path});
    defer talloc.free(dst_path);
    try std.fs.cwd().makePath(src_path);
    try std.fs.cwd().makePath(dst_path);

    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();
    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, src_dir, .none);
    defer series_catalog.deinit();
    const sid = types.hash64("fetch.series");
    _ = try series_catalog.register("fetch.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 1.0 }};
    const seg_path = try segment_mod.writeSegment(talloc, src_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(src_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var src = try CasManager.init(talloc, src_path, .none);
    defer src.deinit();
    const src_head = try src.bootstrapIfMissing(src_dir, &manifest, &tags, &series_catalog);
    try src.writeHeadSymRef(main_ref);
    _ = try src.pack();

    const fetched = try fetchLocalRepository(talloc, src_path, dst_path, .none);
    try std.testing.expect(fetched.repository_id.eql(src.repository_id));
    try std.testing.expect(fetched.borrowed_repositories > 0);

    var dst = try CasManager.init(talloc, dst_path, .none);
    defer dst.deinit();
    const tracking_name = try trackingRefName(talloc, src.repository_id, main_ref);
    defer talloc.free(tracking_name);
    const tracked = try dst.refs.readHead(tracking_name) orelse return error.MissingCasHead;
    try std.testing.expect(tracked.eql(src_head));
    try std.testing.expect(try dst.store.hasObject(src_head));
    const remote_head_name = try trackingHeadSymRefName(talloc, src.repository_id);
    defer talloc.free(remote_head_name);
    const remote_head = try dst.refs.readSymRef(remote_head_name) orelse return error.MissingCasHead;
    defer talloc.free(remote_head);
    try std.testing.expectEqualStrings(tracking_name, remote_head);
}

test "local fetch can materialize borrowed content" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const src_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/fetch-materialize-src", .{tmp.sub_path});
    defer talloc.free(src_path);
    const dst_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/fetch-materialize-dst", .{tmp.sub_path});
    defer talloc.free(dst_path);
    try std.fs.cwd().makePath(src_path);
    try std.fs.cwd().makePath(dst_path);

    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();
    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, src_dir, .none);
    defer series_catalog.deinit();
    const sid = types.hash64("fetch.materialize.series");
    _ = try series_catalog.register("fetch.materialize.series", "{}", sid);
    const points = [_]types.Point{.{ .ts = 1_000, .value = 1.5 }};
    const seg_path = try segment_mod.writeSegment(talloc, src_dir, sid, 0, points[0..]);
    defer talloc.free(seg_path);
    try manifest.add(src_dir, sid, 0, 1_000, 1_000, 1, seg_path);

    var src = try CasManager.init(talloc, src_path, .none);
    defer src.deinit();
    const src_head = try src.bootstrapIfMissing(src_dir, &manifest, &tags, &series_catalog);
    _ = try src.pack();

    const fetched = try fetchLocalRepositoryWithOptions(talloc, src_path, dst_path, .none, .{ .materialize = true });
    try std.testing.expect(fetched.repository_id.eql(src.repository_id));
    try std.testing.expectEqual(@as(usize, 0), fetched.borrowed_repositories);

    var dst = try CasManager.init(talloc, dst_path, .none);
    defer dst.deinit();
    try std.testing.expectEqual(@as(usize, 0), dst.store.alternates.repo_paths.len);
    try std.testing.expect(try dst.store.hasLocalObject(talloc, src_head));
}

test "local push enforces fast-forward and materializes owned content by default" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const src_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/push-src", .{tmp.sub_path});
    defer talloc.free(src_path);
    const dst_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/push-dst", .{tmp.sub_path});
    defer talloc.free(dst_path);
    try std.fs.cwd().makePath(src_path);
    try std.fs.cwd().makePath(dst_path);

    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();
    var dst_dir = try std.fs.cwd().openDir(dst_path, .{ .iterate = true });
    defer dst_dir.close();

    var src_manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer src_manifest.deinit();
    var dst_manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer dst_manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var src_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, src_dir, .none);
    defer src_catalog.deinit();
    var dst_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, dst_dir, .none);
    defer dst_catalog.deinit();
    const sid = types.hash64("push.series");
    _ = try src_catalog.register("push.series", "{}", sid);
    _ = try dst_catalog.register("push.series", "{}", sid);

    const base_points = [_]types.Point{.{ .ts = 1_000, .value = 2.0 }};
    const base_src_path = try segment_mod.writeSegment(talloc, src_dir, sid, 0, base_points[0..]);
    defer talloc.free(base_src_path);
    try src_manifest.add(src_dir, sid, 0, 1_000, 1_000, 1, base_src_path);
    const base_dst_path = try segment_mod.writeSegment(talloc, dst_dir, sid, 0, base_points[0..]);
    defer talloc.free(base_dst_path);
    try dst_manifest.add(dst_dir, sid, 0, 1_000, 1_000, 1, base_dst_path);

    var src = try CasManager.init(talloc, src_path, .none);
    defer src.deinit();
    var dst = try CasManager.init(talloc, dst_path, .none);
    defer dst.deinit();
    _ = try src.bootstrapIfMissing(src_dir, &src_manifest, &tags, &src_catalog);
    const dst_head = try dst.bootstrapIfMissing(dst_dir, &dst_manifest, &tags, &dst_catalog);

    const next_points = [_]types.Point{.{ .ts = 2_000, .value = 3.0 }};
    const next_src_path = try segment_mod.writeSegment(talloc, src_dir, sid, 0, next_points[0..]);
    defer talloc.free(next_src_path);
    try src_manifest.add(src_dir, sid, 0, 2_000, 2_000, 1, next_src_path);
    const src_head = try src.syncLegacySnapshot(src_dir, &src_manifest, &tags, &src_catalog, "advance-push");

    const pushed = try pushLocalRepository(talloc, src_path, dst_path, .none);
    try std.testing.expect(pushed.repository_id.eql(src.repository_id));
    try std.testing.expectEqual(@as(usize, 0), pushed.borrowed_repositories);

    const pushed_head = try dst.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(pushed_head.eql(src_head));
    try std.testing.expect(!pushed_head.eql(dst_head));
    try std.testing.expect(try dst.store.hasLocalObject(talloc, src_head));
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
