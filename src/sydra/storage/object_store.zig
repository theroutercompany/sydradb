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

pub const ObjectStore = struct {
    allocator: std.mem.Allocator,
    root: std.fs.Dir,
    fsync: cfg.FsyncPolicy,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, fsync: cfg.FsyncPolicy) !ObjectStore {
        var cwd = std.fs.cwd();
        try cwd.makePath(path);
        const root = try cwd.openDir(path, .{ .iterate = true });
        try root.makePath("objects");
        try root.makePath("refs");
        return .{ .allocator = allocator, .root = root, .fsync = fsync };
    }

    pub fn deinit(self: *ObjectStore) void {
        self.root.close();
    }

    pub fn put(self: *ObjectStore, obj_type: ObjectType, payload: []const u8) !ObjectId {
        const id = hash(obj_type, payload);

        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        const dir_buf = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
        const dir_slice = dir_buf[0..];

        try objects_dir.makePath(dir_slice);
        var bucket_dir = try objects_dir.openDir(dir_slice, .{});
        defer bucket_dir.close();

        const object_name = id.toHex();

        if (bucket_dir.openFile(object_name[0..], .{ .mode = .read_only })) |existing| {
            existing.close();
            return id;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

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
        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        const dir_buf = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
        const dir_slice = dir_buf[0..];

        var bucket_dir = try objects_dir.openDir(dir_slice, .{});
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

        const payload = buffer[5 .. 5 + payload_len];
        if (!hash(obj_type, payload).eql(id)) return error.ObjectHashMismatch;
        return LoadedObject{
            .id = id,
            .obj_type = obj_type,
            .payload = payload,
        };
    }

    pub fn listIds(self: *ObjectStore, allocator: std.mem.Allocator) ![]ObjectId {
        var ids = std.array_list.Managed(ObjectId).init(allocator);
        errdefer ids.deinit();

        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        var bucket_it = objects_dir.iterate();
        while (try bucket_it.next()) |bucket_entry| {
            if (bucket_entry.kind != .directory) continue;
            var bucket_dir = try objects_dir.openDir(bucket_entry.name, .{ .iterate = true });
            defer bucket_dir.close();

            var object_it = bucket_dir.iterate();
            while (try object_it.next()) |object_entry| {
                if (object_entry.kind != .file) continue;
                if (std.mem.indexOf(u8, object_entry.name, ".tmp-") != null) continue;
                try ids.append(try ObjectId.fromHex(object_entry.name));
            }
        }

        return try ids.toOwnedSlice();
    }

    pub fn delete(self: *ObjectStore, id: ObjectId) !void {
        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        const dir_buf = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
        const dir_slice = dir_buf[0..];

        var bucket_dir = try objects_dir.openDir(dir_slice, .{});
        defer bucket_dir.close();

        const object_name = id.toHex();
        try bucket_dir.deleteFile(object_name[0..]);
        if (shouldSync(self.fsync)) {
            try syncDir(&bucket_dir);
        }
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
