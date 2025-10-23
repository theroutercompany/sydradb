const std = @import("std");

pub const ObjectType = enum(u8) {
    blob = 1,
    tree = 2,
    commit = 3,
    ref = 4,
};

pub const ObjectId = struct {
    hash: [32]u8,

    pub fn toHex(self: ObjectId) [64]u8 {
        var out: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "{s}", .{std.fmt.fmtSliceHexLower(self.hash[0..])}) catch unreachable;
        return out;
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

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !ObjectStore {
        var cwd = std.fs.cwd();
        try cwd.makePath(path);
        const root = try cwd.openDir(path, .{ .iterate = true });
        try root.makePath("objects");
        try root.makePath("refs");
        return .{ .allocator = allocator, .root = root };
    }

    pub fn deinit(self: *ObjectStore) void {
        self.root.close();
    }

    pub fn put(self: *ObjectStore, obj_type: ObjectType, payload: []const u8) !ObjectId {
        const id = hash(obj_type, payload);

        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        const prefix_byte = id.hash[0];
        var dir_buf: [2]u8 = undefined;
        const dir_slice = try std.fmt.bufPrint(&dir_buf, "{02x}", .{prefix_byte});

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

        var file = try bucket_dir.createFile(object_name[0..], .{ .read = true, .truncate = true });
        defer file.close();

        var header = [_]u8{ @intFromEnum(obj_type), 0, 0, 0, 0 };
        const payload_len: u32 = @intCast(payload.len);
        std.mem.writeInt(u32, header[1..5], payload_len, .little);

        try file.writeAll(&header);
        try file.writeAll(payload);
        return id;
    }

    pub fn get(self: *ObjectStore, allocator: std.mem.Allocator, id: ObjectId) !LoadedObject {
        var objects_dir = try self.root.openDir("objects", .{ .iterate = true });
        defer objects_dir.close();

        const prefix_byte = id.hash[0];
        var dir_buf: [2]u8 = undefined;
        const dir_slice = try std.fmt.bufPrint(&dir_buf, "{02x}", .{prefix_byte});

        var bucket_dir = try objects_dir.openDir(dir_slice, .{});
        defer bucket_dir.close();

        const object_name = id.toHex();
        var file = try bucket_dir.openFile(object_name[0..], .{ .mode = .read_only });
        defer file.close();

        const stat = try file.stat();
        if (stat.size < 5) return error.CorruptObject;

        var buffer = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(buffer);
        try file.readAll(buffer);

        const obj_type = std.meta.intToEnum(ObjectType, buffer[0]) catch return error.UnknownObjectType;
        const payload_len = std.mem.readInt(u32, buffer[1..5], .little);
        if (payload_len > buffer[5..].len) return error.CorruptObject;

        const payload = buffer[5 .. 5 + payload_len];
        return LoadedObject{
            .id = id,
            .obj_type = obj_type,
            .payload = payload,
        };
    }
};

fn hash(obj_type: ObjectType, payload: []const u8) ObjectId {
    var hasher = std.crypto.hash.blake3.Blake3.init(.{});
    hasher.update(&[_]u8{@intFromEnum(obj_type)});
    hasher.update(payload);
    var out: [32]u8 = undefined;
    hasher.final(out[0..]);
    return .{ .hash = out };
}

test "object store write/read round-trip" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = try ObjectStore.init(std.testing.allocator, tmp_dir.dir_path);
    defer store.deinit();

    const payload = "hello world";
    const id = try store.put(.blob, payload);

    const loaded = try store.get(std.testing.allocator, id);
    defer std.testing.allocator.free(loaded.payload);

    try std.testing.expect(loaded.obj_type == .blob);
    try std.testing.expectEqualStrings(payload, loaded.payload);
}
