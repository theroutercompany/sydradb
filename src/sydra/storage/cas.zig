const std = @import("std");
const types = @import("../types.zig");
const manifest_mod = @import("manifest.zig");
const compact_mod = @import("compact.zig");
const object_store = @import("object_store.zig");
const segment_mod = @import("segment.zig");
const tags_mod = @import("tags.zig");
const retention_mod = @import("retention.zig");

pub const main_ref = "heads/main";

pub const SegmentDescriptor = struct {
    path: []u8,
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

pub const TreeEntry = struct {
    path: []u8,
    object_type: object_store.ObjectType,
    object_id: object_store.ObjectId,

    pub fn deinit(self: *TreeEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
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

    pub fn deinit(self: *LegacySnapshot, alloc: std.mem.Allocator) void {
        for (self.segment_descriptors) |*descriptor| descriptor.deinit(alloc);
        alloc.free(self.segment_descriptors);
        self.tag_snapshot.deinit(alloc);
    }
};

pub const Snapshot = struct {
    commit_id: object_store.ObjectId,
    root_id: object_store.ObjectId,
    commit: Commit,
    segment_descriptors: []SegmentDescriptor,
    tag_snapshot: TagSnapshot,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        self.commit.deinit(alloc);
        for (self.segment_descriptors) |*descriptor| descriptor.deinit(alloc);
        alloc.free(self.segment_descriptors);
        self.tag_snapshot.deinit(alloc);
    }
};

pub const RefStore = struct {
    alloc: std.mem.Allocator,
    root: std.fs.Dir,

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !RefStore {
        var cwd = std.fs.cwd();
        try cwd.makePath(path);
        const root = try cwd.openDir(path, .{ .iterate = true });
        try root.makePath("refs");
        return .{ .alloc = alloc, .root = root };
    }

    pub fn deinit(self: *RefStore) void {
        self.root.close();
    }

    pub fn readHead(self: *RefStore, ref_name: []const u8) !?object_store.ObjectId {
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
        const full_path = try std.fmt.allocPrint(self.alloc, "refs/{s}", .{ref_name});
        defer self.alloc.free(full_path);
        if (std.fs.path.dirname(full_path)) |dirname| {
            try self.root.makePath(dirname);
        }

        const tmp_path = try std.fmt.allocPrint(self.alloc, "refs/{s}.tmp", .{ref_name});
        defer self.alloc.free(tmp_path);

        var file = try self.root.createFile(tmp_path, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer self.root.deleteFile(tmp_path) catch {};

        const hex = id.toHex();
        try file.writeAll(hex[0..]);
        try file.writeAll("\n");
        try file.sync();

        self.root.rename(tmp_path, full_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                self.root.deleteFile(full_path) catch {};
                try self.root.rename(tmp_path, full_path);
            },
            else => return err,
        };
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
        parent: ?object_store.ObjectId,
        reason: []const u8,
    ) !object_store.ObjectId {
        var snapshot = try buildLegacySnapshot(self.alloc, data_dir, manifest, tags);
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

        var tree_entries = std.array_list.Managed(TreeEntry).init(self.alloc);
        defer {
            for (tree_entries.items) |*entry| entry.deinit(self.alloc);
            tree_entries.deinit();
        }

        try tree_entries.append(.{
            .path = try self.alloc.dupe(u8, "tags/index"),
            .object_type = .blob,
            .object_id = tag_blob_id,
        });

        for (snapshot.segment_descriptors) |descriptor| {
            const descriptor_payload = try encodeSegmentDescriptor(self.alloc, descriptor);
            defer self.alloc.free(descriptor_payload);
            const descriptor_id = try self.store.put(.blob, descriptor_payload);
            try tree_entries.append(.{
                .path = try descriptorTreePath(self.alloc, descriptor),
                .object_type = .blob,
                .object_id = descriptor_id,
            });
        }

        std.sort.block(TreeEntry, tree_entries.items, {}, struct {
            fn lessThan(_: void, lhs: TreeEntry, rhs: TreeEntry) bool {
                return std.mem.lessThan(u8, lhs.path, rhs.path);
            }
        }.lessThan);

        var tree = Tree{ .entries = try tree_entries.toOwnedSlice() };
        defer tree.deinit(self.alloc);
        const tree_payload = try encodeTree(self.alloc, tree);
        defer self.alloc.free(tree_payload);
        const root_id = try self.store.put(.tree, tree_payload);

        const parent_ids = try buildParentSlice(self.alloc, parent);
        defer self.alloc.free(parent_ids);
        const reason_copy = try self.alloc.dupe(u8, reason);
        defer self.alloc.free(reason_copy);
        const commit = Commit{
            .root = root_id,
            .parents = parent_ids,
            .created_at_ms = std.time.milliTimestamp(),
            .reason = reason_copy,
        };
        const commit_payload = try encodeCommit(self.alloc, commit);
        defer self.alloc.free(commit_payload);
        return try self.store.put(.commit, commit_payload);
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

        const tree_loaded = try self.store.get(self.alloc, commit.root);
        defer self.alloc.free(tree_loaded.payload);
        if (tree_loaded.obj_type != .tree) return error.InvalidTreeObject;

        var tree = try decodeTree(self.alloc, tree_loaded.payload);
        defer tree.deinit(self.alloc);

        var descriptors = std.array_list.Managed(SegmentDescriptor).init(self.alloc);
        errdefer {
            for (descriptors.items) |*descriptor| descriptor.deinit(self.alloc);
            descriptors.deinit();
        }

        var tag_snapshot = try TagSnapshot.empty(self.alloc);
        var saw_tags = false;
        errdefer if (!saw_tags) tag_snapshot.deinit(self.alloc);

        for (tree.entries) |entry| {
            const loaded = try self.store.get(self.alloc, entry.object_id);
            defer self.alloc.free(loaded.payload);

            if (std.mem.eql(u8, entry.path, "tags/index")) {
                if (loaded.obj_type != .blob) return error.InvalidTagSnapshotObject;
                tag_snapshot.deinit(self.alloc);
                tag_snapshot = try decodeTagSnapshot(self.alloc, loaded.payload);
                saw_tags = true;
                continue;
            }

            if (loaded.obj_type != .blob) return error.InvalidSegmentDescriptorObject;
            try descriptors.append(try decodeSegmentDescriptor(self.alloc, loaded.payload));
        }

        std.sort.block(SegmentDescriptor, descriptors.items, {}, struct {
            fn lessThan(_: void, lhs: SegmentDescriptor, rhs: SegmentDescriptor) bool {
                return std.mem.lessThan(u8, lhs.path, rhs.path);
            }
        }.lessThan);

        return .{
            .commit_id = commit_id,
            .root_id = commit.root,
            .commit = commit,
            .segment_descriptors = try descriptors.toOwnedSlice(),
            .tag_snapshot = tag_snapshot,
        };
    }

    pub fn verifyHeadMatchesLegacy(
        self: *CommitReader,
        data_dir: std.fs.Dir,
        manifest: *const manifest_mod.Manifest,
        tags: *const tags_mod.TagIndex,
    ) !void {
        var live = try buildLegacySnapshot(self.alloc, data_dir, manifest, tags);
        defer live.deinit(self.alloc);

        var stored = try self.loadHeadSnapshot();
        defer stored.deinit(self.alloc);

        try verifyLegacySnapshot(live, stored);
    }
};

pub const CasManager = struct {
    alloc: std.mem.Allocator,
    store: object_store.ObjectStore,
    refs: RefStore,

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !CasManager {
        return .{
            .alloc = alloc,
            .store = try object_store.ObjectStore.init(alloc, path),
            .refs = try RefStore.init(alloc, path),
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
    ) !object_store.ObjectId {
        if (try self.refs.readHead(main_ref)) |head| return head;
        const writer = CommitWriter{ .alloc = self.alloc, .store = &self.store };
        const commit_id = try writer.writeSnapshot(data_dir, manifest, tags, null, "bootstrap");
        try self.refs.updateHeadAtomic(main_ref, commit_id);
        return commit_id;
    }

    pub fn syncLegacySnapshot(
        self: *CasManager,
        data_dir: std.fs.Dir,
        manifest: *const manifest_mod.Manifest,
        tags: *const tags_mod.TagIndex,
        reason: []const u8,
    ) !object_store.ObjectId {
        const parent = try self.refs.readHead(main_ref);
        const writer = CommitWriter{ .alloc = self.alloc, .store = &self.store };
        const commit_id = try writer.writeSnapshot(data_dir, manifest, tags, parent, reason);
        try self.refs.updateHeadAtomic(main_ref, commit_id);
        return commit_id;
    }

    pub fn verifyHeadMatchesLegacy(
        self: *CasManager,
        data_dir: std.fs.Dir,
        manifest: *const manifest_mod.Manifest,
        tags: *const tags_mod.TagIndex,
    ) !void {
        var reader = CommitReader{ .alloc = self.alloc, .store = &self.store, .refs = &self.refs };
        try reader.verifyHeadMatchesLegacy(data_dir, manifest, tags);
    }
};

pub fn buildLegacySnapshot(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    manifest: *const manifest_mod.Manifest,
    tags: *const tags_mod.TagIndex,
) !LegacySnapshot {
    var descriptors = std.array_list.Managed(SegmentDescriptor).init(alloc);
    errdefer {
        for (descriptors.items) |*descriptor| descriptor.deinit(alloc);
        descriptors.deinit();
    }

    for (manifest.entries.items) |entry| {
        const metadata = try segment_mod.inspectMetadata(data_dir, entry.path);
        if (metadata.series_id != entry.series_id or metadata.hour_bucket != entry.hour_bucket or metadata.start_ts != entry.start_ts or metadata.end_ts != entry.end_ts or metadata.count != entry.count) {
            return error.ManifestSegmentMismatch;
        }
        try descriptors.append(.{
            .path = try alloc.dupe(u8, entry.path),
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

    std.sort.block(SegmentDescriptor, descriptors.items, {}, struct {
        fn lessThan(_: void, lhs: SegmentDescriptor, rhs: SegmentDescriptor) bool {
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);

    return .{
        .segment_descriptors = try descriptors.toOwnedSlice(),
        .tag_snapshot = try buildTagSnapshot(alloc, tags),
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

fn descriptorTreePath(alloc: std.mem.Allocator, descriptor: SegmentDescriptor) ![]u8 {
    const basename = std.fs.path.basename(descriptor.path);
    return try std.fmt.allocPrint(alloc, "series/{x}/hour/{d}/{s}", .{ descriptor.series_id, descriptor.hour_bucket, basename });
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
    var hasher = std.crypto.hash.blake3.Blake3.init(.{});
    while (true) {
        const bytes_read = try file.read(buf[0..]);
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
    }
    var out: [32]u8 = undefined;
    hasher.final(out[0..]);
    return out;
}

fn encodeSegmentDescriptor(alloc: std.mem.Allocator, descriptor: SegmentDescriptor) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(1);
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
    if (version != 1) return error.UnsupportedSegmentDescriptorVersion;

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

fn encodeTree(alloc: std.mem.Allocator, tree: Tree) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(1);
    try appendInt(&bytes, u32, @intCast(tree.entries.len));
    for (tree.entries) |entry| {
        try appendString(&bytes, entry.path);
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
        const path = try cursor.readOwnedString(alloc);
        errdefer alloc.free(path);

        const object_type = std.meta.intToEnum(object_store.ObjectType, try cursor.readByte()) catch return error.UnknownTreeObjectType;
        const object_id = .{ .hash = try cursor.readHash() };
        entries[i] = .{
            .path = path,
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
        const value = std.mem.readInt(T, self.bytes[self.index .. self.index + size], .little);
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

    fn finish(self: *Cursor) !void {
        if (self.index != self.bytes.len) return error.ExtraObjectBytes;
    }
};

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

    var store = try object_store.ObjectStore.init(std.testing.allocator, tmp_dir.dir_path);
    defer store.deinit();

    const id_a = try store.put(.blob, encoded_a);
    const id_b = try store.put(.blob, encoded_b);
    try std.testing.expect(id_a.eql(id_b));
}

test "cas bootstrap imports legacy manifest and tags into a genesis commit" {
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

    var cas_manager = try CasManager.init(talloc, data_path);
    defer cas_manager.deinit();

    const head = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags);
    const ref_head = try cas_manager.refs.readHead(main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(head.eql(ref_head));
    try cas_manager.verifyHeadMatchesLegacy(data_dir, &manifest, &tags);

    var reader = CommitReader{ .alloc = talloc, .store = &cas_manager.store, .refs = &cas_manager.refs };
    var snapshot = try reader.loadHeadSnapshot();
    defer snapshot.deinit(talloc);

    try std.testing.expectEqual(@as(usize, 0), snapshot.commit.parents.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.segment_descriptors.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.tag_snapshot.entries.len);
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

    const old_path = try segment_mod.writeSegment(talloc, data_dir, sid, old_points[0].ts - @mod(old_points[0].ts, 3600), old_points[0..]);
    defer talloc.free(old_path);
    try manifest.add(data_dir, sid, old_points[0].ts - @mod(old_points[0].ts, 3600), old_points[0].ts, old_points[old_points.len - 1].ts, @intCast(old_points.len), old_path);

    const new_path = try segment_mod.writeSegment(talloc, data_dir, sid, new_points[0].ts - @mod(new_points[0].ts, 3600), new_points[0..]);
    defer talloc.free(new_path);
    try manifest.add(data_dir, sid, new_points[0].ts - @mod(new_points[0].ts, 3600), new_points[0].ts, new_points[new_points.len - 1].ts, @intCast(new_points.len), new_path);

    var cas_manager = try CasManager.init(talloc, data_path);
    defer cas_manager.deinit();
    const initial_head = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags);

    const changed = try retention_mod.applyWithResult(data_dir, &manifest, 1);
    try std.testing.expect(changed);

    var reloaded = try manifest_mod.Manifest.loadOrInit(talloc, data_dir);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.entries.items.len);

    const next_head = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, "retention");
    try std.testing.expect(!initial_head.eql(next_head));
    try cas_manager.verifyHeadMatchesLegacy(data_dir, &manifest, &tags);
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

    const sid = types.hash64("compact.series");
    const first_points = [_]types.Point{
        .{ .ts = 1_000, .value = 1.0 },
        .{ .ts = 1_005, .value = 2.0 },
    };
    const second_points = [_]types.Point{
        .{ .ts = 1_010, .value = 3.0 },
        .{ .ts = 1_015, .value = 4.0 },
    };

    const first_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, first_points[0..]);
    defer talloc.free(first_path);
    try manifest.add(data_dir, sid, 0, first_points[0].ts, first_points[first_points.len - 1].ts, @intCast(first_points.len), first_path);

    const second_path = try segment_mod.writeSegment(talloc, data_dir, sid, 0, second_points[0..]);
    defer talloc.free(second_path);
    try manifest.add(data_dir, sid, 0, second_points[0].ts, second_points[second_points.len - 1].ts, @intCast(second_points.len), second_path);

    var cas_manager = try CasManager.init(talloc, data_path);
    defer cas_manager.deinit();
    const initial_head = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags);

    const changed = try compact_mod.compactAllWithResult(talloc, data_dir, &manifest);
    try std.testing.expect(changed);

    var reloaded = try manifest_mod.Manifest.loadOrInit(talloc, data_dir);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.entries.items.len);

    const next_head = try cas_manager.syncLegacySnapshot(data_dir, &manifest, &tags, "compaction");
    try std.testing.expect(!initial_head.eql(next_head));
    try cas_manager.verifyHeadMatchesLegacy(data_dir, &manifest, &tags);
}
