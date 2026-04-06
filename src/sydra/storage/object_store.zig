const std = @import("std");
const cfg = @import("../config.zig");

pub const ObjectType = enum(u8) {
    blob = 1,
    tree = 2,
    commit = 3,
    ref = 4,
};

pub const ObjectId = struct {
    hash: [32]u8,

    pub fn eql(self: ObjectId, other: ObjectId) bool {
        return std.mem.eql(u8, self.hash[0..], other.hash[0..]);
    }

    pub fn fromHex(hex: []const u8) !ObjectId {
        if (hex.len != 64) return error.InvalidObjectIdHex;
        var hash_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(hash_bytes[0..], hex);
        return .{ .hash = hash_bytes };
    }

    pub fn toHex(self: ObjectId) [64]u8 {
        return std.fmt.bytesToHex(self.hash, .lower);
    }
};

pub const LoadedObject = struct {
    id: ObjectId,
    obj_type: ObjectType,
    payload: []u8,
};

pub const PackWriteResult = struct {
    pack_path: []u8,
    idx_path: []u8,
    rev_path: []u8,
    object_count: usize,

    pub fn deinit(self: *PackWriteResult, alloc: std.mem.Allocator) void {
        alloc.free(self.pack_path);
        alloc.free(self.idx_path);
        alloc.free(self.rev_path);
    }
};

pub const PackManifest = struct {
    pack_path: []u8,
    pack_checksum: [32]u8,
    object_count: u64,
    blob_count: u64,
    tree_count: u64,
    commit_count: u64,
    ref_count: u64,

    pub fn deinit(self: *PackManifest, alloc: std.mem.Allocator) void {
        alloc.free(self.pack_path);
    }
};

pub const PackReverseIndex = struct {
    pack_path: []u8,
    object_ids: []ObjectId,
    offsets: []u64,

    pub fn deinit(self: *PackReverseIndex, alloc: std.mem.Allocator) void {
        alloc.free(self.pack_path);
        alloc.free(self.object_ids);
        alloc.free(self.offsets);
    }
};

pub const AlternateStoreSet = struct {
    repo_paths: [][]u8,

    pub fn deinit(self: *AlternateStoreSet, alloc: std.mem.Allocator) void {
        for (self.repo_paths) |path| alloc.free(path);
        alloc.free(self.repo_paths);
    }
};

pub const PackedBlobReader = struct {
    file: std.fs.File,
    remaining: usize,
    expected_id: ObjectId,
    hasher: std.crypto.hash.Blake3,
    finished: bool = false,

    pub fn deinit(self: *PackedBlobReader) void {
        self.file.close();
    }

    pub fn read(self: *PackedBlobReader, dest: []u8) !usize {
        if (self.remaining == 0) {
            try self.finish();
            return 0;
        }

        const limit = @min(dest.len, self.remaining);
        const read_len = try self.file.read(dest[0..limit]);
        self.hasher.update(dest[0..read_len]);
        self.remaining -= read_len;
        if (self.remaining == 0) try self.finish();
        return read_len;
    }

    pub fn readNoEof(self: *PackedBlobReader, dest: []u8) !void {
        var offset: usize = 0;
        while (offset < dest.len) {
            const read_len = try self.read(dest[offset..]);
            if (read_len == 0) return error.EndOfStream;
            offset += read_len;
        }
    }

    pub fn readByte(self: *PackedBlobReader) !u8 {
        var buf: [1]u8 = undefined;
        try self.readNoEof(buf[0..]);
        return buf[0];
    }

    pub fn finish(self: *PackedBlobReader) !void {
        if (self.finished) return;
        if (self.remaining != 0) return error.UnconsumedBlobPayload;
        var actual_id: [32]u8 = undefined;
        self.hasher.final(actual_id[0..]);
        if (!std.mem.eql(u8, actual_id[0..], self.expected_id.hash[0..])) return error.ObjectHashMismatch;
        self.finished = true;
    }
};

pub const ObjectStore = struct {
    allocator: std.mem.Allocator,
    root: std.fs.Dir,
    fsync: cfg.FsyncPolicy,
    alternates: AlternateStoreSet,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, fsync: cfg.FsyncPolicy) !ObjectStore {
        var cwd = std.fs.cwd();
        try cwd.makePath(path);
        const root = try cwd.openDir(path, .{ .iterate = true });
        try root.makePath("objects");
        try root.makePath("objects/packs");
        try root.makePath("objects/info");
        try root.makePath("refs");
        return .{
            .allocator = allocator,
            .root = root,
            .fsync = fsync,
            .alternates = try loadAlternateStoreSet(allocator, root),
        };
    }

    pub fn deinit(self: *ObjectStore) void {
        self.alternates.deinit(self.allocator);
        self.root.close();
    }

    pub fn put(self: *ObjectStore, obj_type: ObjectType, payload: []const u8) !ObjectId {
        const id = hash(obj_type, payload);
        if (try self.containsId(id)) return id;

        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        const dir_buf = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
        const dir_slice = dir_buf[0..];

        try objects_dir.makePath(dir_slice);
        var bucket_dir = try objects_dir.openDir(dir_slice, .{});
        defer bucket_dir.close();

        const object_name = id.toHex();

        const tmp_name = try std.fmt.allocPrint(self.allocator, "{s}.tmp-{d}", .{ object_name[0..], std.time.nanoTimestamp() });
        defer self.allocator.free(tmp_name);
        errdefer bucket_dir.deleteFile(tmp_name) catch {};

        var file = try bucket_dir.createFile(tmp_name, .{ .read = true, .truncate = true });
        defer file.close();

        var header = [_]u8{ @intFromEnum(obj_type), 0, 0, 0, 0 };
        const payload_len: u32 = @intCast(payload.len);
        std.mem.writeInt(u32, header[1..5], payload_len, .little);

        try file.writeAll(&header);
        try file.writeAll(payload);
        if (shouldSync(self.fsync)) {
            try file.sync();
        }
        bucket_dir.rename(tmp_name, object_name[0..]) catch |err| switch (err) {
            error.PathAlreadyExists => {
                bucket_dir.deleteFile(tmp_name) catch {};
            },
            else => return err,
        };
        if (shouldSync(self.fsync)) {
            try syncDir(&bucket_dir);
        }
        return id;
    }

    pub fn get(self: *ObjectStore, allocator: std.mem.Allocator, id: ObjectId) !LoadedObject {
        return self.getLocal(allocator, id) catch |err| switch (err) {
            error.FileNotFound => try self.getFromAlternates(allocator, id),
            else => return err,
        };
    }

    pub fn hasObject(self: *ObjectStore, id: ObjectId) !bool {
        if (self.getLocal(self.allocator, id)) |loaded| {
            self.allocator.free(loaded.payload);
            return true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        return try self.hasAlternateObject(id);
    }

    pub fn configureAlternates(self: *ObjectStore, allocator: std.mem.Allocator, repo_paths: []const []const u8) !void {
        try writeAlternatesFile(allocator, self.root, repo_paths, self.fsync);
        self.alternates.deinit(self.allocator);
        self.alternates = try loadAlternateStoreSet(self.allocator, self.root);
    }

    fn getLoose(self: *ObjectStore, allocator: std.mem.Allocator, id: ObjectId) !LoadedObject {
        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        const dir_buf = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
        const dir_slice = dir_buf[0..];

        var bucket_dir = objects_dir.openDir(dir_slice, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        defer bucket_dir.close();

        const object_name = id.toHex();
        var file = try bucket_dir.openFile(object_name[0..], .{ .mode = .read_only });
        defer file.close();

        const stat = try file.stat();
        if (stat.size < 5) return error.CorruptObject;

        var buffer = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(buffer);
        const bytes_read = try file.readAll(buffer);
        if (bytes_read != buffer.len) return error.CorruptObject;

        const obj_type = std.meta.intToEnum(ObjectType, buffer[0]) catch return error.UnknownObjectType;
        const payload_len = std.mem.readInt(u32, buffer[1..5], .little);
        if (payload_len != buffer[5..].len) return error.CorruptObject;

        const encoded_payload = buffer[5 .. 5 + payload_len];
        if (!hash(obj_type, encoded_payload).eql(id)) return error.ObjectHashMismatch;
        const payload = try allocator.dupe(u8, encoded_payload);
        allocator.free(buffer);
        return LoadedObject{
            .id = id,
            .obj_type = obj_type,
            .payload = payload,
        };
    }

    fn getLocal(self: *ObjectStore, allocator: std.mem.Allocator, id: ObjectId) !LoadedObject {
        return self.getLoose(allocator, id) catch |err| switch (err) {
            error.FileNotFound => try self.getPacked(allocator, id),
            else => return err,
        };
    }

    pub fn listIds(self: *ObjectStore, allocator: std.mem.Allocator) ![]ObjectId {
        var seen = std.AutoHashMap(ObjectId, void).init(allocator);
        defer seen.deinit();

        var ids = std.array_list.Managed(ObjectId).init(allocator);
        errdefer ids.deinit();

        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        var bucket_it = objects_dir.iterate();
        while (try bucket_it.next()) |bucket_entry| {
            if (bucket_entry.kind != .directory) continue;
            if (bucket_entry.name.len != 2) continue;
            var bucket_dir = try objects_dir.openDir(bucket_entry.name, .{ .iterate = true });
            defer bucket_dir.close();

            var object_it = bucket_dir.iterate();
            while (try object_it.next()) |object_entry| {
                if (object_entry.kind != .file) continue;
                if (std.mem.indexOf(u8, object_entry.name, ".tmp-") != null) continue;
                const id = try ObjectId.fromHex(object_entry.name);
                if (!seen.contains(id)) {
                    try seen.put(id, {});
                    try ids.append(id);
                }
            }
        }

        const packed_ids = try self.listPackedIds(allocator);
        defer allocator.free(packed_ids);
        for (packed_ids) |id| {
            if (!seen.contains(id)) {
                try seen.put(id, {});
                try ids.append(id);
            }
        }

        return try ids.toOwnedSlice();
    }

    pub fn delete(self: *ObjectStore, id: ObjectId) !void {
        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        const dir_buf = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
        const dir_slice = dir_buf[0..];

        var bucket_dir = objects_dir.openDir(dir_slice, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (try self.findPackedLocation(id) != null) return error.ObjectStoredInPack;
                return err;
            },
            else => return err,
        };
        defer bucket_dir.close();

        const object_name = id.toHex();
        bucket_dir.deleteFile(object_name[0..]) catch |err| switch (err) {
            error.FileNotFound => {
                if (try self.findPackedLocation(id) != null) return error.ObjectStoredInPack;
                return err;
            },
            else => return err,
        };
        if (shouldSync(self.fsync)) {
            try syncDir(&bucket_dir);
        }
    }

    pub fn writePack(self: *ObjectStore, allocator: std.mem.Allocator, ids: []const ObjectId) !PackWriteResult {
        const stamp = std.time.nanoTimestamp();
        const base_prefix = try std.fmt.allocPrint(allocator, "objects/packs/pack-{d}", .{stamp});
        defer allocator.free(base_prefix);
        return try self.writePackAt(allocator, ids, base_prefix, true, true);
    }

    pub fn writeCruftPack(self: *ObjectStore, allocator: std.mem.Allocator, ids: []const ObjectId, stamp_ms: i64) !PackWriteResult {
        const dir_path = try std.fmt.allocPrint(allocator, "objects/cruft/{d}/packs", .{stamp_ms});
        defer allocator.free(dir_path);
        try self.root.makePath(dir_path);

        const base_prefix = try std.fmt.allocPrint(allocator, "{s}/cruft-{d}", .{ dir_path, std.time.nanoTimestamp() });
        defer allocator.free(base_prefix);
        return try self.writePackAt(allocator, ids, base_prefix, false, true);
    }

    fn writePackAt(
        self: *ObjectStore,
        allocator: std.mem.Allocator,
        ids: []const ObjectId,
        base_prefix: []const u8,
        refresh_active_indexes: bool,
        delete_loose_after: bool,
    ) !PackWriteResult {
        const sorted_ids = try allocator.dupe(ObjectId, ids);
        defer allocator.free(sorted_ids);
        std.sort.block(ObjectId, sorted_ids, {}, struct {
            fn lessThan(_: void, lhs: ObjectId, rhs: ObjectId) bool {
                return std.mem.lessThan(u8, lhs.hash[0..], rhs.hash[0..]);
            }
        }.lessThan);

        const pack_rel = try std.fmt.allocPrint(allocator, "{s}.pack", .{base_prefix});
        errdefer allocator.free(pack_rel);
        const idx_rel = try std.fmt.allocPrint(allocator, "{s}.idx", .{base_prefix});
        errdefer allocator.free(idx_rel);
        const rev_rel = try std.fmt.allocPrint(allocator, "{s}.rev", .{base_prefix});
        errdefer allocator.free(rev_rel);
        const manifest_rel = try std.fmt.allocPrint(allocator, "{s}.manifest", .{base_prefix});
        defer allocator.free(manifest_rel);

        const tmp_pack_rel = try std.fmt.allocPrint(allocator, "{s}.tmp", .{pack_rel});
        defer allocator.free(tmp_pack_rel);
        const tmp_idx_rel = try std.fmt.allocPrint(allocator, "{s}.tmp", .{idx_rel});
        defer allocator.free(tmp_idx_rel);
        const tmp_rev_rel = try std.fmt.allocPrint(allocator, "{s}.tmp", .{rev_rel});
        defer allocator.free(tmp_rev_rel);
        const tmp_manifest_rel = try std.fmt.allocPrint(allocator, "{s}.tmp", .{manifest_rel});
        defer allocator.free(tmp_manifest_rel);

        var offsets = try allocator.alloc(u64, sorted_ids.len);
        defer allocator.free(offsets);

        var manifest = PackManifest{
            .pack_path = try allocator.dupe(u8, pack_rel),
            .pack_checksum = [_]u8{0} ** 32,
            .object_count = sorted_ids.len,
            .blob_count = 0,
            .tree_count = 0,
            .commit_count = 0,
            .ref_count = 0,
        };
        defer manifest.deinit(allocator);

        var pack_file = try self.root.createFile(tmp_pack_rel, .{ .truncate = true, .read = true });
        defer pack_file.close();
        errdefer self.root.deleteFile(tmp_pack_rel) catch {};

        var pack_write_buf: [4096]u8 = undefined;
        var pack_writer_state = pack_file.writer(&pack_write_buf);
        const pack_writer = &pack_writer_state.interface;
        try pack_writer.writeAll(packMagic[0..]);
        try pack_writer.writeInt(u16, 1, .little);
        try pack_writer.writeInt(u64, @intCast(sorted_ids.len), .little);

        var current_offset: u64 = packMagic.len + @sizeOf(u16) + @sizeOf(u64);
        for (sorted_ids, 0..) |id, idx| {
            offsets[idx] = current_offset;
            const loaded = try self.get(allocator, id);
            defer allocator.free(loaded.payload);

            switch (loaded.obj_type) {
                .blob => manifest.blob_count += 1,
                .tree => manifest.tree_count += 1,
                .commit => manifest.commit_count += 1,
                .ref => manifest.ref_count += 1,
            }

            try pack_writer.writeAll(id.hash[0..]);
            try pack_writer.writeByte(@intFromEnum(loaded.obj_type));
            try pack_writer.writeInt(u64, @intCast(loaded.payload.len), .little);
            try pack_writer.writeAll(loaded.payload);

            current_offset += 32 + 1 + @sizeOf(u64) + @as(u64, @intCast(loaded.payload.len));
        }
        try pack_writer_state.end();
        if (shouldSync(self.fsync)) {
            try pack_file.sync();
        }

        const pack_checksum = try hashRelativeFile(self.root, allocator, tmp_pack_rel);
        manifest.pack_checksum = pack_checksum;
        const pack_stat = try pack_file.stat();

        const idx_bytes = try encodePackIndex(allocator, sorted_ids, offsets, pack_stat.size, pack_checksum);
        defer allocator.free(idx_bytes);

        var idx_file = try self.root.createFile(tmp_idx_rel, .{ .truncate = true, .read = true });
        defer idx_file.close();
        errdefer self.root.deleteFile(tmp_idx_rel) catch {};
        try idx_file.writeAll(idx_bytes);
        if (shouldSync(self.fsync)) {
            try idx_file.sync();
        }

        const rev_bytes = try encodePackReverseIndex(allocator, pack_rel, sorted_ids, offsets);
        defer allocator.free(rev_bytes);
        var rev_file = try self.root.createFile(tmp_rev_rel, .{ .truncate = true, .read = true });
        defer rev_file.close();
        errdefer self.root.deleteFile(tmp_rev_rel) catch {};
        try rev_file.writeAll(rev_bytes);
        if (shouldSync(self.fsync)) {
            try rev_file.sync();
        }

        const manifest_bytes = try encodePackManifest(allocator, manifest);
        defer allocator.free(manifest_bytes);
        var manifest_file = try self.root.createFile(tmp_manifest_rel, .{ .truncate = true, .read = true });
        defer manifest_file.close();
        errdefer self.root.deleteFile(tmp_manifest_rel) catch {};
        try manifest_file.writeAll(manifest_bytes);
        if (shouldSync(self.fsync)) {
            try manifest_file.sync();
        }

        try self.root.rename(tmp_pack_rel, pack_rel);
        try self.root.rename(tmp_idx_rel, idx_rel);
        try self.root.rename(tmp_rev_rel, rev_rel);
        try self.root.rename(tmp_manifest_rel, manifest_rel);
        if (shouldSync(self.fsync)) {
            try syncDir(&self.root);
        }
        if (refresh_active_indexes) {
            try self.rebuildMultiPackIndex(allocator);
        }

        if (delete_loose_after) {
            for (sorted_ids) |id| {
                self.delete(id) catch |err| switch (err) {
                    error.FileNotFound, error.ObjectStoredInPack => {},
                    else => return err,
                };
            }
        }

        return .{
            .pack_path = pack_rel,
            .idx_path = idx_rel,
            .rev_path = rev_rel,
            .object_count = sorted_ids.len,
        };
    }

    pub fn hasLooseObject(self: *ObjectStore, id: ObjectId) !bool {
        if (self.getLoose(self.allocator, id)) |loaded| {
            self.allocator.free(loaded.payload);
            return true;
        } else |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    }

    pub fn verifyActivePackMetadata(self: *ObjectStore, allocator: std.mem.Allocator) !void {
        const idx_paths = try self.listPackIndexPaths(allocator);
        defer freeOwnedStrings(allocator, idx_paths);

        for (idx_paths) |idx_path| {
            var index = try loadPackIndex(allocator, self.root, idx_path);
            defer index.deinit(allocator);
            const rev_path = try revPathForIndex(allocator, idx_path);
            defer allocator.free(rev_path);
            var reverse = try loadPackReverseIndex(allocator, self.root, rev_path);
            defer reverse.deinit(allocator);

            const manifest_path = try manifestPathForIndex(allocator, idx_path);
            defer allocator.free(manifest_path);
            var manifest = try loadPackManifest(allocator, self.root, manifest_path);
            defer manifest.deinit(allocator);

            if (!std.mem.eql(u8, manifest.manifest.pack_path, index.pack_path)) return error.CorruptPackManifest;
            if (!std.mem.eql(u8, manifest.manifest.pack_checksum[0..], index.pack_checksum[0..])) return error.CorruptPackManifest;
            if (manifest.manifest.object_count != index.object_ids.len) return error.CorruptPackManifest;
            if (!std.mem.eql(u8, reverse.pack_path, index.pack_path)) return error.CorruptPackReverseIndex;
            if (reverse.object_ids.len != index.object_ids.len) return error.CorruptPackReverseIndex;
            if (reverse.offsets.len != index.offsets.len) return error.CorruptPackReverseIndex;

            var counts = [_]u64{0} ** 4;
            var pack_file = try self.root.openFile(index.pack_path, .{ .mode = .read_only });
            defer pack_file.close();
            for (reverse.offsets, reverse.object_ids, 0..) |offset, reverse_id, object_idx| {
                try pack_file.seekTo(offset + 32);
                var type_buf: [1]u8 = undefined;
                if (try pack_file.readAll(type_buf[0..]) != type_buf.len) return error.CorruptPack;
                const obj_type = std.meta.intToEnum(ObjectType, type_buf[0]) catch return error.UnknownObjectType;
                counts[@intFromEnum(obj_type) - 1] += 1;
                if (!reverse_id.eql(index.object_ids[object_idx])) return error.CorruptPackReverseIndex;
                if (offset != index.offsets[object_idx]) return error.CorruptPackReverseIndex;
            }

            if (counts[@intFromEnum(ObjectType.blob) - 1] != manifest.manifest.blob_count) return error.CorruptPackManifest;
            if (counts[@intFromEnum(ObjectType.tree) - 1] != manifest.manifest.tree_count) return error.CorruptPackManifest;
            if (counts[@intFromEnum(ObjectType.commit) - 1] != manifest.manifest.commit_count) return error.CorruptPackManifest;
            if (counts[@intFromEnum(ObjectType.ref) - 1] != manifest.manifest.ref_count) return error.CorruptPackManifest;
        }
    }

    pub fn openPackedBlobReader(self: *ObjectStore, allocator: std.mem.Allocator, id: ObjectId) !?PackedBlobReader {
        _ = allocator;
        var location = try self.findPackedLocation(id) orelse return null;
        defer location.deinit(self.allocator);

        var pack_file = try self.root.openFile(location.pack_path, .{ .mode = .read_only });
        errdefer pack_file.close();
        try pack_file.seekTo(location.offset);

        var id_buf: [32]u8 = undefined;
        if (try pack_file.readAll(id_buf[0..]) != id_buf.len) return error.CorruptPack;
        if (!std.mem.eql(u8, id_buf[0..], id.hash[0..])) return error.CorruptPack;

        var type_buf: [1]u8 = undefined;
        if (try pack_file.readAll(type_buf[0..]) != type_buf.len) return error.CorruptPack;
        const obj_type = std.meta.intToEnum(ObjectType, type_buf[0]) catch return error.UnknownObjectType;
        if (obj_type != .blob) return error.InvalidExtentChunkObject;

        var len_buf: [8]u8 = undefined;
        if (try pack_file.readAll(len_buf[0..]) != len_buf.len) return error.CorruptPack;
        const payload_len = std.mem.readInt(u64, &len_buf, .little);

        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&[_]u8{@intFromEnum(ObjectType.blob)});
        return .{
            .file = pack_file,
            .remaining = @intCast(payload_len),
            .expected_id = id,
            .hasher = hasher,
        };
    }

    fn containsId(self: *ObjectStore, id: ObjectId) !bool {
        if (self.getLoose(self.allocator, id)) |loaded| {
            self.allocator.free(loaded.payload);
            return true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        if (try self.findPackedLocation(id)) |location| {
            defer location.deinit(self.allocator);
            return true;
        }
        return false;
    }

    fn getPacked(self: *ObjectStore, allocator: std.mem.Allocator, id: ObjectId) !LoadedObject {
        var location = try self.findPackedLocation(id) orelse return error.FileNotFound;
        defer location.deinit(allocator);

        var pack_file = try self.root.openFile(location.pack_path, .{ .mode = .read_only });
        defer pack_file.close();
        try pack_file.seekTo(location.offset);

        var id_buf: [32]u8 = undefined;
        if (try pack_file.readAll(id_buf[0..]) != id_buf.len) return error.CorruptPack;
        if (!std.mem.eql(u8, id_buf[0..], id.hash[0..])) return error.CorruptPack;

        var type_buf: [1]u8 = undefined;
        if (try pack_file.readAll(type_buf[0..]) != type_buf.len) return error.CorruptPack;
        const obj_type = std.meta.intToEnum(ObjectType, type_buf[0]) catch return error.UnknownObjectType;
        var len_buf: [8]u8 = undefined;
        if (try pack_file.readAll(len_buf[0..]) != len_buf.len) return error.CorruptPack;
        const payload_len = std.mem.readInt(u64, &len_buf, .little);
        const payload = try allocator.alloc(u8, @intCast(payload_len));
        errdefer allocator.free(payload);
        const bytes_read = try pack_file.readAll(payload);
        if (bytes_read != payload.len) return error.CorruptPack;
        if (!computeId(obj_type, payload).eql(id)) return error.ObjectHashMismatch;
        return .{
            .id = id,
            .obj_type = obj_type,
            .payload = payload,
        };
    }

    fn findPackedLocation(self: *ObjectStore, id: ObjectId) !?PackLocation {
        if (self.loadMultiPackIndex(self.allocator)) |loaded_midx| {
            var midx = loaded_midx;
            defer midx.deinit(self.allocator);
            if (midx.lookup(id)) |location| {
                return .{
                    .pack_path = try self.allocator.dupe(u8, location.pack_path),
                    .offset = location.offset,
                };
            }
        } else |err| switch (err) {
            error.FileNotFound, error.CorruptMultiPackIndex, error.UnsupportedMultiPackIndexVersion => {},
            else => return err,
        }

        const idx_paths = try self.listPackIndexPaths(self.allocator);
        defer freeOwnedStrings(self.allocator, idx_paths);

        for (idx_paths) |idx_path| {
            var index = try loadPackIndex(self.allocator, self.root, idx_path);
            defer index.deinit(self.allocator);
            if (index.lookup(id)) |offset| {
                return .{
                    .pack_path = try self.allocator.dupe(u8, index.pack_path),
                    .offset = offset,
                };
            }
        }
        return null;
    }

    fn listPackedIds(self: *ObjectStore, allocator: std.mem.Allocator) ![]ObjectId {
        if (self.loadMultiPackIndex(allocator)) |loaded_midx| {
            var midx = loaded_midx;
            defer midx.deinit(allocator);
            const ids = try allocator.alloc(ObjectId, midx.records.len);
            for (midx.records, 0..) |record, idx| ids[idx] = record.id;
            return ids;
        } else |err| switch (err) {
            error.FileNotFound, error.CorruptMultiPackIndex, error.UnsupportedMultiPackIndexVersion => {},
            else => return err,
        }

        const idx_paths = try self.listPackIndexPaths(allocator);
        defer freeOwnedStrings(allocator, idx_paths);

        var ids = std.array_list.Managed(ObjectId).init(allocator);
        errdefer ids.deinit();
        var seen = std.AutoHashMap(ObjectId, void).init(allocator);
        defer seen.deinit();
        for (idx_paths) |idx_path| {
            var index = try loadPackIndex(allocator, self.root, idx_path);
            defer index.deinit(allocator);
            for (index.object_ids) |id| {
                const gop = try seen.getOrPut(id);
                if (gop.found_existing) continue;
                try ids.append(id);
            }
        }
        return try ids.toOwnedSlice();
    }

    fn listPackIndexPaths(self: *ObjectStore, allocator: std.mem.Allocator) ![][]u8 {
        var pack_dir = self.root.openDir("objects/packs", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return try allocator.alloc([]u8, 0),
            else => return err,
        };
        defer pack_dir.close();

        var out = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (out.items) |path| allocator.free(path);
            out.deinit();
        }

        var it = pack_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
            if (std.mem.endsWith(u8, entry.name, ".tmp")) continue;
            try out.append(try std.fmt.allocPrint(allocator, "objects/packs/{s}", .{entry.name}));
        }

        std.sort.block([]u8, out.items, {}, struct {
            fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);
        return try out.toOwnedSlice();
    }

    fn rebuildMultiPackIndex(self: *ObjectStore, allocator: std.mem.Allocator) !void {
        const idx_paths = try self.listPackIndexPaths(allocator);
        defer freeOwnedStrings(allocator, idx_paths);

        if (idx_paths.len == 0) {
            self.root.deleteFile(midxPath) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            return;
        }

        const pack_paths = try allocator.alloc([]u8, idx_paths.len);
        defer {
            for (pack_paths) |path| allocator.free(path);
            allocator.free(pack_paths);
        }
        const pack_has_reverse = try allocator.alloc(bool, idx_paths.len);
        defer allocator.free(pack_has_reverse);

        var records = std.array_list.Managed(MultiPackRecord).init(allocator);
        defer records.deinit();
        var seen = std.AutoHashMap(ObjectId, void).init(allocator);
        defer seen.deinit();

        for (idx_paths, 0..) |idx_path, pack_idx| {
            var index = try loadPackIndex(allocator, self.root, idx_path);
            defer index.deinit(allocator);
            pack_paths[pack_idx] = try allocator.dupe(u8, index.pack_path);
            const rev_path = try revPathForIndex(allocator, idx_path);
            defer allocator.free(rev_path);
            pack_has_reverse[pack_idx] = try pathExists(self.root, rev_path);
            if (!pack_has_reverse[pack_idx]) {
                try writePackReverseIndexFile(
                    allocator,
                    self.root,
                    rev_path,
                    index.pack_path,
                    index.object_ids,
                    index.offsets,
                    self.fsync,
                );
                pack_has_reverse[pack_idx] = true;
            }
            for (index.object_ids, index.offsets) |id, offset| {
                const gop = try seen.getOrPut(id);
                if (gop.found_existing) continue;
                try records.append(.{
                    .id = id,
                    .pack_path_index = @intCast(pack_idx),
                    .offset = offset,
                });
            }
        }

        std.sort.block(MultiPackRecord, records.items, {}, struct {
            fn lessThan(_: void, lhs: MultiPackRecord, rhs: MultiPackRecord) bool {
                return std.mem.lessThan(u8, lhs.id.hash[0..], rhs.id.hash[0..]);
            }
        }.lessThan);

        const bytes = try encodeMultiPackIndex(allocator, pack_paths, pack_has_reverse, records.items);
        defer allocator.free(bytes);

        const temp_path = midxPath ++ ".tmp";
        var file = try self.root.createFile(temp_path, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer self.root.deleteFile(temp_path) catch {};
        try file.writeAll(bytes);
        if (shouldSync(self.fsync)) {
            try file.sync();
        }
        self.root.rename(temp_path, midxPath) catch |err| switch (err) {
            error.PathAlreadyExists => {
                self.root.deleteFile(midxPath) catch {};
                try self.root.rename(temp_path, midxPath);
            },
            else => return err,
        };
        if (shouldSync(self.fsync)) {
            try syncDir(&self.root);
        }
    }

    fn loadMultiPackIndex(self: *ObjectStore, allocator: std.mem.Allocator) !MultiPackIndex {
        return try readMultiPackIndex(allocator, self.root);
    }

    fn getFromAlternates(self: *ObjectStore, allocator: std.mem.Allocator, id: ObjectId) !LoadedObject {
        for (self.alternates.repo_paths) |repo_path| {
            var alternate = try openAlternateStore(self.allocator, repo_path);
            defer alternate.deinit();
            if (alternate.getLocal(allocator, id)) |loaded| {
                return loaded;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
        return error.FileNotFound;
    }

    fn hasAlternateObject(self: *ObjectStore, id: ObjectId) !bool {
        for (self.alternates.repo_paths) |repo_path| {
            var alternate = try openAlternateStore(self.allocator, repo_path);
            defer alternate.deinit();
            if (alternate.getLocal(self.allocator, id)) |loaded| {
                self.allocator.free(loaded.payload);
                return true;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
        return false;
    }
};

pub fn computeId(obj_type: ObjectType, payload: []const u8) ObjectId {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(&[_]u8{@intFromEnum(obj_type)});
    hasher.update(payload);
    var out: [32]u8 = undefined;
    hasher.final(out[0..]);
    return .{ .hash = out };
}

fn hash(obj_type: ObjectType, payload: []const u8) ObjectId {
    return computeId(obj_type, payload);
}

fn shouldSync(policy: cfg.FsyncPolicy) bool {
    return policy != .none;
}

fn syncDir(dir: *std.fs.Dir) !void {
    if (@hasDecl(std.fs.Dir, "sync")) {
        try dir.sync();
    }
}

const packMagic = "SYDPACK1";
const idxMagic = "SYDIDX1\x00";
const midxMagic = "SYDMIDX1";
const manifestMagic = "SYDPMAN1";
const revMagic = "SYDREV1\x00";
const midxPath = "objects/info/multi-pack-index";
const alternatesPath = "objects/info/alternates";

const PackLocation = struct {
    pack_path: []u8,
    offset: u64,

    fn deinit(self: *const PackLocation, alloc: std.mem.Allocator) void {
        alloc.free(self.pack_path);
    }
};

const MultiPackRecord = struct {
    id: ObjectId,
    pack_path_index: u32,
    offset: u64,
};

const MultiPackLocation = struct {
    pack_path: []const u8,
    offset: u64,
    has_reverse_index: bool,
};

const MultiPackIndex = struct {
    pack_paths: [][]u8,
    pack_has_reverse: []bool,
    fanout: [256]u64,
    records: []MultiPackRecord,

    fn deinit(self: *MultiPackIndex, alloc: std.mem.Allocator) void {
        for (self.pack_paths) |path| alloc.free(path);
        alloc.free(self.pack_paths);
        alloc.free(self.pack_has_reverse);
        alloc.free(self.records);
    }

    fn lookup(self: *const MultiPackIndex, id: ObjectId) ?MultiPackLocation {
        const prefix = id.hash[0];
        const start = if (prefix == 0) 0 else self.fanout[prefix - 1];
        const end = self.fanout[prefix];
        var lo: usize = @intCast(start);
        var hi: usize = @intCast(end);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const candidate = self.records[mid];
            if (candidate.id.eql(id)) {
                const pack_idx: usize = @intCast(candidate.pack_path_index);
                if (pack_idx >= self.pack_paths.len) return null;
                return .{
                    .pack_path = self.pack_paths[pack_idx],
                    .offset = candidate.offset,
                    .has_reverse_index = self.pack_has_reverse[pack_idx],
                };
            }
            if (std.mem.lessThan(u8, candidate.id.hash[0..], id.hash[0..])) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }
};

const PackIndex = struct {
    pack_path: []u8,
    pack_size: u64,
    pack_checksum: [32]u8,
    fanout: [256]u64,
    object_ids: []ObjectId,
    offsets: []u64,

    fn deinit(self: *PackIndex, alloc: std.mem.Allocator) void {
        alloc.free(self.pack_path);
        alloc.free(self.object_ids);
        alloc.free(self.offsets);
    }

    fn lookup(self: *const PackIndex, id: ObjectId) ?u64 {
        const prefix = id.hash[0];
        const start = if (prefix == 0) 0 else self.fanout[prefix - 1];
        const end = self.fanout[prefix];
        var lo: usize = @intCast(start);
        var hi: usize = @intCast(end);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const candidate = self.object_ids[mid];
            if (candidate.eql(id)) return self.offsets[mid];
            if (std.mem.lessThan(u8, candidate.hash[0..], id.hash[0..])) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }
};

const LoadedPackManifest = struct {
    manifest: PackManifest,

    fn deinit(self: *LoadedPackManifest, alloc: std.mem.Allocator) void {
        self.manifest.deinit(alloc);
    }
};

fn encodePackIndex(
    alloc: std.mem.Allocator,
    ids: []const ObjectId,
    offsets: []const u64,
    pack_size: u64,
    pack_checksum: [32]u8,
) ![]u8 {
    var fanout: [256]u64 = [_]u64{0} ** 256;
    for (ids) |id| {
        fanout[id.hash[0]] += 1;
    }
    var i: usize = 1;
    while (i < fanout.len) : (i += 1) {
        fanout[i] += fanout[i - 1];
    }

    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.appendSlice(idxMagic[0..]);
    try appendInt(&bytes, u16, 1);
    try appendInt(&bytes, u64, @intCast(ids.len));
    for (fanout) |count| try appendInt(&bytes, u64, count);
    try appendInt(&bytes, u64, pack_size);
    try bytes.appendSlice(pack_checksum[0..]);
    for (ids) |id| try bytes.appendSlice(id.hash[0..]);
    for (offsets) |offset| try appendInt(&bytes, u64, offset);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes.items);
    var checksum: [32]u8 = undefined;
    hasher.final(checksum[0..]);
    try bytes.appendSlice(checksum[0..]);
    return try bytes.toOwnedSlice();
}

fn encodeMultiPackIndex(
    alloc: std.mem.Allocator,
    pack_paths: []const []const u8,
    pack_has_reverse: []const bool,
    records: []const MultiPackRecord,
) ![]u8 {
    var fanout: [256]u64 = [_]u64{0} ** 256;
    for (records) |record| {
        fanout[record.id.hash[0]] += 1;
    }
    var i: usize = 1;
    while (i < fanout.len) : (i += 1) {
        fanout[i] += fanout[i - 1];
    }

    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.appendSlice(midxMagic[0..]);
    try appendInt(&bytes, u16, 2);
    try appendInt(&bytes, u64, @intCast(records.len));
    try appendInt(&bytes, u64, @intCast(pack_paths.len));
    for (fanout) |count| try appendInt(&bytes, u64, count);
    for (pack_paths, pack_has_reverse) |pack_path, has_reverse| {
        try appendInt(&bytes, u16, @intCast(pack_path.len));
        try bytes.appendSlice(pack_path);
        try bytes.append(if (has_reverse) 1 else 0);
    }
    for (records) |record| try bytes.appendSlice(record.id.hash[0..]);
    for (records) |record| try appendInt(&bytes, u32, record.pack_path_index);
    for (records) |record| try appendInt(&bytes, u64, record.offset);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes.items);
    var checksum: [32]u8 = undefined;
    hasher.final(checksum[0..]);
    try bytes.appendSlice(checksum[0..]);
    return try bytes.toOwnedSlice();
}

fn encodePackManifest(alloc: std.mem.Allocator, manifest: PackManifest) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.appendSlice(manifestMagic[0..]);
    try appendInt(&bytes, u16, 1);
    try appendInt(&bytes, u16, @intCast(manifest.pack_path.len));
    try bytes.appendSlice(manifest.pack_path);
    try bytes.appendSlice(manifest.pack_checksum[0..]);
    try appendInt(&bytes, u64, manifest.object_count);
    try appendInt(&bytes, u64, manifest.blob_count);
    try appendInt(&bytes, u64, manifest.tree_count);
    try appendInt(&bytes, u64, manifest.commit_count);
    try appendInt(&bytes, u64, manifest.ref_count);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes.items);
    var checksum: [32]u8 = undefined;
    hasher.final(checksum[0..]);
    try bytes.appendSlice(checksum[0..]);
    return try bytes.toOwnedSlice();
}

fn encodePackReverseIndex(
    alloc: std.mem.Allocator,
    pack_path: []const u8,
    ids: []const ObjectId,
    offsets: []const u64,
) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.appendSlice(revMagic[0..]);
    try appendInt(&bytes, u16, 1);
    try appendInt(&bytes, u16, @intCast(pack_path.len));
    try bytes.appendSlice(pack_path);
    try appendInt(&bytes, u64, @intCast(ids.len));
    for (ids) |id| try bytes.appendSlice(id.hash[0..]);
    for (offsets) |offset| try appendInt(&bytes, u64, offset);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes.items);
    var checksum: [32]u8 = undefined;
    hasher.final(checksum[0..]);
    try bytes.appendSlice(checksum[0..]);
    return try bytes.toOwnedSlice();
}

fn loadPackIndex(alloc: std.mem.Allocator, root: std.fs.Dir, idx_path: []const u8) !PackIndex {
    const bytes = try root.readFileAlloc(alloc, idx_path, 256 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < idxMagic.len + @sizeOf(u16) + @sizeOf(u64) + (256 * @sizeOf(u64)) + @sizeOf(u64) + 32 + 32) {
        return error.CorruptPackIndex;
    }
    if (!std.mem.eql(u8, bytes[0..idxMagic.len], idxMagic[0..])) return error.CorruptPackIndex;

    const checksum_start = bytes.len - 32;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes[0..checksum_start]);
    var expected_checksum: [32]u8 = undefined;
    hasher.final(expected_checksum[0..]);
    if (!std.mem.eql(u8, expected_checksum[0..], bytes[checksum_start..])) return error.CorruptPackIndex;

    var cursor: usize = idxMagic.len;
    const version = readIntAt(bytes, &cursor, u16);
    if (version != 1) return error.UnsupportedPackIndexVersion;
    const object_count = readIntAt(bytes, &cursor, u64);

    var fanout: [256]u64 = undefined;
    for (&fanout) |*entry| entry.* = readIntAt(bytes, &cursor, u64);
    const pack_size = readIntAt(bytes, &cursor, u64);
    var pack_checksum: [32]u8 = undefined;
    @memcpy(pack_checksum[0..], bytes[cursor .. cursor + 32]);
    cursor += 32;

    const object_ids = try alloc.alloc(ObjectId, @intCast(object_count));
    errdefer alloc.free(object_ids);
    for (object_ids) |*id| {
        @memcpy(id.hash[0..], bytes[cursor .. cursor + 32]);
        cursor += 32;
    }

    const offsets = try alloc.alloc(u64, @intCast(object_count));
    errdefer alloc.free(offsets);
    for (offsets) |*offset| {
        offset.* = readIntAt(bytes, &cursor, u64);
    }

    const pack_path = try packPathForIndex(alloc, idx_path);
    return .{
        .pack_path = pack_path,
        .pack_size = pack_size,
        .pack_checksum = pack_checksum,
        .fanout = fanout,
        .object_ids = object_ids,
        .offsets = offsets,
    };
}

fn loadPackManifest(alloc: std.mem.Allocator, root: std.fs.Dir, manifest_path: []const u8) !LoadedPackManifest {
    const bytes = try root.readFileAlloc(alloc, manifest_path, 16 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < manifestMagic.len + @sizeOf(u16) + @sizeOf(u16) + 32 + @sizeOf(u64) * 5 + 32) return error.CorruptPackManifest;
    if (!std.mem.eql(u8, bytes[0..manifestMagic.len], manifestMagic[0..])) return error.CorruptPackManifest;

    const checksum_start = bytes.len - 32;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes[0..checksum_start]);
    var expected_checksum: [32]u8 = undefined;
    hasher.final(expected_checksum[0..]);
    if (!std.mem.eql(u8, expected_checksum[0..], bytes[checksum_start..])) return error.CorruptPackManifest;

    var cursor: usize = manifestMagic.len;
    const version = readIntAt(bytes, &cursor, u16);
    if (version != 1) return error.UnsupportedPackManifestVersion;
    const path_len = readIntAt(bytes, &cursor, u16);
    if (cursor + path_len > checksum_start) return error.CorruptPackManifest;
    const pack_path = try alloc.dupe(u8, bytes[cursor .. cursor + path_len]);
    cursor += path_len;
    errdefer alloc.free(pack_path);

    var pack_checksum: [32]u8 = undefined;
    @memcpy(pack_checksum[0..], bytes[cursor .. cursor + 32]);
    cursor += 32;
    const object_count = readIntAt(bytes, &cursor, u64);
    const blob_count = readIntAt(bytes, &cursor, u64);
    const tree_count = readIntAt(bytes, &cursor, u64);
    const commit_count = readIntAt(bytes, &cursor, u64);
    const ref_count = readIntAt(bytes, &cursor, u64);
    if (cursor != checksum_start) return error.CorruptPackManifest;

    return .{ .manifest = .{
        .pack_path = pack_path,
        .pack_checksum = pack_checksum,
        .object_count = object_count,
        .blob_count = blob_count,
        .tree_count = tree_count,
        .commit_count = commit_count,
        .ref_count = ref_count,
    } };
}

fn loadPackReverseIndex(alloc: std.mem.Allocator, root: std.fs.Dir, rev_path: []const u8) !PackReverseIndex {
    const bytes = try root.readFileAlloc(alloc, rev_path, 256 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < revMagic.len + @sizeOf(u16) + @sizeOf(u16) + @sizeOf(u64) + 32) return error.CorruptPackReverseIndex;
    if (!std.mem.eql(u8, bytes[0..revMagic.len], revMagic[0..])) return error.CorruptPackReverseIndex;

    const checksum_start = bytes.len - 32;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes[0..checksum_start]);
    var expected_checksum: [32]u8 = undefined;
    hasher.final(expected_checksum[0..]);
    if (!std.mem.eql(u8, expected_checksum[0..], bytes[checksum_start..])) return error.CorruptPackReverseIndex;

    var cursor: usize = revMagic.len;
    const version = readIntAt(bytes, &cursor, u16);
    if (version != 1) return error.UnsupportedPackReverseIndexVersion;
    const path_len = readIntAt(bytes, &cursor, u16);
    if (cursor + path_len > checksum_start) return error.CorruptPackReverseIndex;
    const pack_path = try alloc.dupe(u8, bytes[cursor .. cursor + path_len]);
    cursor += path_len;
    errdefer alloc.free(pack_path);

    const object_count = readIntAt(bytes, &cursor, u64);
    const object_ids = try alloc.alloc(ObjectId, @intCast(object_count));
    errdefer alloc.free(object_ids);
    for (object_ids) |*id| {
        @memcpy(id.hash[0..], bytes[cursor .. cursor + 32]);
        cursor += 32;
    }

    const offsets = try alloc.alloc(u64, @intCast(object_count));
    errdefer alloc.free(offsets);
    for (offsets) |*offset| {
        offset.* = readIntAt(bytes, &cursor, u64);
    }

    if (cursor != checksum_start) return error.CorruptPackReverseIndex;
    return .{
        .pack_path = pack_path,
        .object_ids = object_ids,
        .offsets = offsets,
    };
}

fn writePackReverseIndexFile(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    rev_path: []const u8,
    pack_path: []const u8,
    ids: []const ObjectId,
    offsets: []const u64,
    fsync: cfg.FsyncPolicy,
) !void {
    const bytes = try encodePackReverseIndex(alloc, pack_path, ids, offsets);
    defer alloc.free(bytes);

    const tmp_rev_rel = try std.fmt.allocPrint(alloc, "{s}.tmp", .{rev_path});
    defer alloc.free(tmp_rev_rel);
    var rev_file = try root.createFile(tmp_rev_rel, .{ .truncate = true, .read = true });
    defer rev_file.close();
    errdefer root.deleteFile(tmp_rev_rel) catch {};
    try rev_file.writeAll(bytes);
    if (shouldSync(fsync)) {
        try rev_file.sync();
    }
    root.rename(tmp_rev_rel, rev_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(rev_path) catch {};
            try root.rename(tmp_rev_rel, rev_path);
        },
        else => return err,
    };
    if (shouldSync(fsync)) {
        var root_for_sync = root;
        try syncDir(&root_for_sync);
    }
}

fn readMultiPackIndex(alloc: std.mem.Allocator, root: std.fs.Dir) !MultiPackIndex {
    const bytes = try root.readFileAlloc(alloc, midxPath, 256 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < midxMagic.len + @sizeOf(u16) + @sizeOf(u64) * 2 + (256 * @sizeOf(u64)) + 32) {
        return error.CorruptMultiPackIndex;
    }
    if (!std.mem.eql(u8, bytes[0..midxMagic.len], midxMagic[0..])) return error.CorruptMultiPackIndex;

    const checksum_start = bytes.len - 32;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes[0..checksum_start]);
    var expected_checksum: [32]u8 = undefined;
    hasher.final(expected_checksum[0..]);
    if (!std.mem.eql(u8, expected_checksum[0..], bytes[checksum_start..])) return error.CorruptMultiPackIndex;

    var cursor: usize = midxMagic.len;
    const version = readIntAt(bytes, &cursor, u16);
    if (version != 1 and version != 2) return error.UnsupportedMultiPackIndexVersion;
    const object_count = readIntAt(bytes, &cursor, u64);
    const pack_count = readIntAt(bytes, &cursor, u64);

    var fanout: [256]u64 = undefined;
    for (&fanout) |*entry| entry.* = readIntAt(bytes, &cursor, u64);

    const pack_paths = try alloc.alloc([]u8, @intCast(pack_count));
    var pack_paths_loaded: usize = 0;
    errdefer {
        for (pack_paths[0..pack_paths_loaded]) |path| alloc.free(path);
        alloc.free(pack_paths);
    }
    const pack_has_reverse = try alloc.alloc(bool, @intCast(pack_count));
    errdefer alloc.free(pack_has_reverse);
    for (pack_paths) |*pack_path| {
        const path_len = readIntAt(bytes, &cursor, u16);
        if (cursor + path_len > checksum_start) return error.CorruptMultiPackIndex;
        pack_path.* = try alloc.dupe(u8, bytes[cursor .. cursor + path_len]);
        cursor += path_len;
        if (version >= 2) {
            if (cursor >= checksum_start) return error.CorruptMultiPackIndex;
            pack_has_reverse[pack_paths_loaded] = switch (bytes[cursor]) {
                0 => false,
                1 => true,
                else => return error.CorruptMultiPackIndex,
            };
            cursor += 1;
        } else {
            pack_has_reverse[pack_paths_loaded] = false;
        }
        pack_paths_loaded += 1;
    }

    const records = try alloc.alloc(MultiPackRecord, @intCast(object_count));
    errdefer alloc.free(records);
    for (records) |*record| {
        record.id = .{ .hash = try readHashAt(bytes, &cursor, checksum_start) };
    }
    for (records) |*record| {
        record.pack_path_index = readIntAt(bytes, &cursor, u32);
    }
    for (records) |*record| {
        record.offset = readIntAt(bytes, &cursor, u64);
        if (record.pack_path_index >= pack_paths.len) return error.CorruptMultiPackIndex;
    }
    if (cursor != checksum_start) return error.CorruptMultiPackIndex;

    return .{
        .pack_paths = pack_paths,
        .pack_has_reverse = pack_has_reverse,
        .fanout = fanout,
        .records = records,
    };
}

fn packPathForIndex(alloc: std.mem.Allocator, idx_path: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, idx_path, ".idx")) return error.InvalidPackIndexPath;
    return try std.fmt.allocPrint(alloc, "{s}.pack", .{idx_path[0 .. idx_path.len - 4]});
}

fn manifestPathForIndex(alloc: std.mem.Allocator, idx_path: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, idx_path, ".idx")) return error.InvalidPackIndexPath;
    return try std.fmt.allocPrint(alloc, "{s}.manifest", .{idx_path[0 .. idx_path.len - 4]});
}

fn revPathForIndex(alloc: std.mem.Allocator, idx_path: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, idx_path, ".idx")) return error.InvalidPackIndexPath;
    return try std.fmt.allocPrint(alloc, "{s}.rev", .{idx_path[0 .. idx_path.len - 4]});
}

fn appendInt(bytes: *std.array_list.Managed(u8), comptime T: type, value: T) !void {
    var raw: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &raw, value, .little);
    try bytes.appendSlice(raw[0..]);
}

fn readIntAt(bytes: []const u8, cursor: *usize, comptime T: type) T {
    defer cursor.* += @sizeOf(T);
    var raw: [@sizeOf(T)]u8 = undefined;
    @memcpy(raw[0..], bytes[cursor.* .. cursor.* + @sizeOf(T)]);
    return std.mem.readInt(T, &raw, .little);
}

fn readHashAt(bytes: []const u8, cursor: *usize, limit: usize) ![32]u8 {
    if (cursor.* + 32 > limit) return error.CorruptMultiPackIndex;
    var hash_bytes: [32]u8 = undefined;
    @memcpy(hash_bytes[0..], bytes[cursor.* .. cursor.* + 32]);
    cursor.* += 32;
    return hash_bytes;
}

fn hashRelativeFile(root: std.fs.Dir, alloc: std.mem.Allocator, path: []const u8) ![32]u8 {
    _ = alloc;
    var file = try root.openFile(path, .{ .mode = .read_only });
    defer file.close();

    var buf: [8192]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.init(.{});
    while (true) {
        const read_len = try file.read(buf[0..]);
        if (read_len == 0) break;
        hasher.update(buf[0..read_len]);
    }
    var out: [32]u8 = undefined;
    hasher.final(out[0..]);
    return out;
}

fn freeOwnedStrings(alloc: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

fn pathExists(root: std.fs.Dir, path: []const u8) !bool {
    root.access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn loadAlternateStoreSet(alloc: std.mem.Allocator, root: std.fs.Dir) !AlternateStoreSet {
    const body = root.readFileAlloc(alloc, alternatesPath, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .repo_paths = try alloc.alloc([]u8, 0) },
        else => return err,
    };
    defer alloc.free(body);

    var repo_paths = std.array_list.Managed([]u8).init(alloc);
    errdefer {
        for (repo_paths.items) |path| alloc.free(path);
        repo_paths.deinit();
    }
    var line_it = std.mem.tokenizeScalar(u8, body, '\n');
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        try repo_paths.append(try alloc.dupe(u8, line));
    }
    return .{ .repo_paths = try repo_paths.toOwnedSlice() };
}

fn writeAlternatesFile(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    repo_paths: []const []const u8,
    fsync: cfg.FsyncPolicy,
) !void {
    _ = alloc;
    const temp_path = alternatesPath ++ ".tmp";
    var file = try root.createFile(temp_path, .{ .truncate = true, .read = true });
    defer file.close();
    errdefer root.deleteFile(temp_path) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer_state = file.writer(&write_buf);
    const writer = &writer_state.interface;
    for (repo_paths) |repo_path| {
        try writer.writeAll(repo_path);
        try writer.writeAll("\n");
    }
    try writer_state.end();
    if (shouldSync(fsync)) try file.sync();
    root.rename(temp_path, alternatesPath) catch |err| switch (err) {
        error.PathAlreadyExists => {
            root.deleteFile(alternatesPath) catch {};
            try root.rename(temp_path, alternatesPath);
        },
        else => return err,
    };
    if (shouldSync(fsync)) {
        var root_for_sync = root;
        try syncDir(&root_for_sync);
    }
}

fn openAlternateStore(alloc: std.mem.Allocator, repo_path: []const u8) !ObjectStore {
    var cwd = std.fs.cwd();
    const root = try cwd.openDir(repo_path, .{ .iterate = true });
    return .{
        .allocator = alloc,
        .root = root,
        .fsync = .none,
        .alternates = .{ .repo_paths = try alloc.alloc([]u8, 0) },
    };
}

test "object store write/read round-trip" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const payload = "hello world";
    const id = try store.put(.blob, payload);

    const loaded = try store.get(std.testing.allocator, id);
    defer std.testing.allocator.free(loaded.payload);

    try std.testing.expect(loaded.obj_type == .blob);
    try std.testing.expectEqualStrings(payload, loaded.payload);
}

test "object id hex round-trip" {
    const payload = "hex round trip";
    const id = hash(.blob, payload);
    const hex = id.toHex();
    const parsed = try ObjectId.fromHex(hex[0..]);
    try std.testing.expect(parsed.eql(id));
}

test "object store detects hash mismatches" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-corrupt", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const payload = "hello world";
    const id = try store.put(.blob, payload);
    const hex = id.toHex();

    var objects_dir = try store.root.openDir("objects", .{ .iterate = true });
    defer objects_dir.close();
    var bucket_dir = try objects_dir.openDir(hex[0..2], .{});
    defer bucket_dir.close();
    var file = try bucket_dir.openFile(hex[0..], .{ .mode = .read_write });
    defer file.close();

    try file.seekTo(5);
    try file.writeAll("x");

    try std.testing.expectError(error.ObjectHashMismatch, store.get(std.testing.allocator, id));
}

test "object store can read packed objects after loose copies are pruned" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-pack", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const blob_id = try store.put(.blob, "packed blob");
    const tree_id = try store.put(.tree, "packed tree");
    const ids = [_]ObjectId{ blob_id, tree_id };

    var pack_write = try store.writePack(std.testing.allocator, ids[0..]);
    defer pack_write.deinit(std.testing.allocator);

    const loaded_blob = try store.get(std.testing.allocator, blob_id);
    defer std.testing.allocator.free(loaded_blob.payload);
    try std.testing.expectEqual(ObjectType.blob, loaded_blob.obj_type);
    try std.testing.expectEqualStrings("packed blob", loaded_blob.payload);

    const loaded_tree = try store.get(std.testing.allocator, tree_id);
    defer std.testing.allocator.free(loaded_tree.payload);
    try std.testing.expectEqual(ObjectType.tree, loaded_tree.obj_type);
    try std.testing.expectEqualStrings("packed tree", loaded_tree.payload);

    const all_ids = try store.listIds(std.testing.allocator);
    defer std.testing.allocator.free(all_ids);
    try std.testing.expectEqual(@as(usize, 2), all_ids.len);
}

test "pack manifests track per-type counts and checksum" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-pack-manifest", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const blob_id = try store.put(.blob, "manifest blob");
    const tree_id = try store.put(.tree, "manifest tree");
    const commit_id = try store.put(.commit, "manifest commit");

    var pack_write = try store.writePack(std.testing.allocator, &[_]ObjectId{ blob_id, tree_id, commit_id });
    defer pack_write.deinit(std.testing.allocator);

    try store.verifyActivePackMetadata(std.testing.allocator);
}

test "pack reverse indexes track physical object order" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-pack-rev", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const first = try store.put(.blob, "alpha");
    const second = try store.put(.tree, "beta");

    var pack_write = try store.writePack(std.testing.allocator, &[_]ObjectId{ second, first });
    defer pack_write.deinit(std.testing.allocator);

    _ = try store.root.statFile(pack_write.rev_path);
    var reverse = try loadPackReverseIndex(std.testing.allocator, store.root, pack_write.rev_path);
    defer reverse.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), reverse.object_ids.len);
    const expected = if (std.mem.lessThan(u8, first.hash[0..], second.hash[0..]))
        [_]ObjectId{ first, second }
    else
        [_]ObjectId{ second, first };
    try std.testing.expect(reverse.object_ids[0].eql(expected[0]));
    try std.testing.expect(reverse.object_ids[1].eql(expected[1]));
    try store.verifyActivePackMetadata(std.testing.allocator);
}

test "object store rejects corrupt pack indexes" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-pack-corrupt", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const id = try store.put(.blob, "corrupt pack blob");
    var pack_write = try store.writePack(std.testing.allocator, &[_]ObjectId{id});
    defer pack_write.deinit(std.testing.allocator);

    var idx_file = try store.root.openFile(pack_write.idx_path, .{ .mode = .read_write });
    defer idx_file.close();
    try idx_file.seekTo(0);
    try idx_file.writeAll("BROKEN!!");

    store.root.deleteFile(midxPath) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try std.testing.expectError(error.CorruptPackIndex, store.get(std.testing.allocator, id));
}

test "multi-pack rebuild synthesizes missing reverse indexes" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-pack-rev-rebuild", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const first = try store.put(.blob, "first-pack");
    var first_pack = try store.writePack(std.testing.allocator, &[_]ObjectId{first});
    defer first_pack.deinit(std.testing.allocator);
    try store.root.deleteFile(first_pack.rev_path);

    const second = try store.put(.blob, "second-pack");
    var second_pack = try store.writePack(std.testing.allocator, &[_]ObjectId{second});
    defer second_pack.deinit(std.testing.allocator);

    _ = try store.root.statFile(first_pack.rev_path);
    try store.verifyActivePackMetadata(std.testing.allocator);
}

test "object store resolves objects across multiple packs with a multi-pack index" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-midx", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const first = try store.put(.blob, "first-pack");
    var first_pack = try store.writePack(std.testing.allocator, &[_]ObjectId{first});
    defer first_pack.deinit(std.testing.allocator);

    const second = try store.put(.blob, "second-pack");
    var second_pack = try store.writePack(std.testing.allocator, &[_]ObjectId{second});
    defer second_pack.deinit(std.testing.allocator);

    const midx_bytes = try store.root.readFileAlloc(std.testing.allocator, midxPath, 1024 * 1024);
    defer std.testing.allocator.free(midx_bytes);
    try std.testing.expect(midx_bytes.len > 0);

    const loaded_first = try store.get(std.testing.allocator, first);
    defer std.testing.allocator.free(loaded_first.payload);
    try std.testing.expectEqualStrings("first-pack", loaded_first.payload);

    const loaded_second = try store.get(std.testing.allocator, second);
    defer std.testing.allocator.free(loaded_second.payload);
    try std.testing.expectEqualStrings("second-pack", loaded_second.payload);

    var pack_dir = try store.root.openDir("objects/packs", .{ .iterate = true });
    defer pack_dir.close();
    var idx_count: usize = 0;
    var pack_count: usize = 0;
    var it = pack_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".idx")) idx_count += 1;
        if (std.mem.endsWith(u8, entry.name, ".pack")) pack_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), idx_count);
    try std.testing.expectEqual(@as(usize, 2), pack_count);
}

test "object store falls back to pack indexes when the multi-pack index is corrupt" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-midx-corrupt", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const first = try store.put(.blob, "first-pack");
    var first_pack = try store.writePack(std.testing.allocator, &[_]ObjectId{first});
    defer first_pack.deinit(std.testing.allocator);

    const second = try store.put(.blob, "second-pack");
    var second_pack = try store.writePack(std.testing.allocator, &[_]ObjectId{second});
    defer second_pack.deinit(std.testing.allocator);

    var midx_file = try store.root.openFile(midxPath, .{ .mode = .read_write });
    defer midx_file.close();
    try midx_file.seekTo(0);
    try midx_file.writeAll("BROKEN!!");

    const loaded_first = try store.get(std.testing.allocator, first);
    defer std.testing.allocator.free(loaded_first.payload);
    try std.testing.expectEqualStrings("first-pack", loaded_first.payload);

    const loaded_second = try store.get(std.testing.allocator, second);
    defer std.testing.allocator.free(loaded_second.payload);
    try std.testing.expectEqualStrings("second-pack", loaded_second.payload);
}

test "object store alternates provide borrowed object reads" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const src_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-alt-src", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(src_path);
    const dst_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/object-store-alt-dst", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(dst_path);

    var src = try ObjectStore.init(std.testing.allocator, src_path, .none);
    defer src.deinit();
    const borrowed_id = try src.put(.blob, "borrowed-pack-object");

    var dst = try ObjectStore.init(std.testing.allocator, dst_path, .none);
    defer dst.deinit();
    try dst.configureAlternates(std.testing.allocator, &[_][]const u8{src_path});

    try std.testing.expect(try dst.hasObject(borrowed_id));
    const loaded = try dst.get(std.testing.allocator, borrowed_id);
    defer std.testing.allocator.free(loaded.payload);
    try std.testing.expectEqualStrings("borrowed-pack-object", loaded.payload);
}
