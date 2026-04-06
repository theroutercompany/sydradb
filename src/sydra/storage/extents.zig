const std = @import("std");
const object_store = @import("object_store.zig");

pub const DefaultChunkBytes: u32 = 64 * 1024;

pub const WriteResult = struct {
    root_id: object_store.ObjectId,
    size_bytes: u64,
    chunk_bytes: u32,
};

pub const Reader = struct {
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    entries: []TreeEntry,
    expected_size: usize,
    bytes_read: usize = 0,
    next_entry_idx: usize = 0,
    current_chunk: []u8 = &[_]u8{},
    current_chunk_offset: usize = 0,
    current_packed_reader: ?object_store.PackedBlobReader = null,

    pub fn deinit(self: *Reader) void {
        if (self.current_packed_reader) |*packed_reader| packed_reader.deinit();
        if (self.current_chunk.len != 0) self.alloc.free(self.current_chunk);
        for (self.entries) |*entry| entry.deinit(self.alloc);
        self.alloc.free(self.entries);
    }

    pub fn read(self: *Reader, dest: []u8) !usize {
        if (dest.len == 0) return 0;

        var total: usize = 0;
        while (total < dest.len) {
            if (!try self.ensureChunk()) break;

            if (self.current_packed_reader) |*packed_reader| {
                const read_len = try packed_reader.read(dest[total..]);
                if (read_len == 0) {
                    packed_reader.deinit();
                    self.current_packed_reader = null;
                    continue;
                }
                total += read_len;
                self.bytes_read += read_len;
                continue;
            }

            const available = self.current_chunk.len - self.current_chunk_offset;
            const read_len = @min(dest.len - total, available);
            @memcpy(dest[total .. total + read_len], self.current_chunk[self.current_chunk_offset .. self.current_chunk_offset + read_len]);
            self.current_chunk_offset += read_len;
            total += read_len;
            self.bytes_read += read_len;
            if (self.current_chunk_offset == self.current_chunk.len) {
                self.alloc.free(self.current_chunk);
                self.current_chunk = &[_]u8{};
                self.current_chunk_offset = 0;
            }
        }
        return total;
    }

    pub fn readNoEof(self: *Reader, dest: []u8) !void {
        var offset: usize = 0;
        while (offset < dest.len) {
            const read_len = try self.read(dest[offset..]);
            if (read_len == 0) return error.EndOfStream;
            offset += read_len;
        }
    }

    pub fn readByte(self: *Reader) !u8 {
        var buf: [1]u8 = undefined;
        try self.readNoEof(buf[0..]);
        return buf[0];
    }

    pub fn finish(self: *Reader) !void {
        if (self.current_packed_reader) |*packed_reader| {
            try packed_reader.finish();
            packed_reader.deinit();
            self.current_packed_reader = null;
        }
        if (self.current_chunk.len != 0 and self.current_chunk_offset != self.current_chunk.len) return error.UnconsumedExtentBytes;
        if (self.next_entry_idx != self.entries.len) return error.UnconsumedExtentBytes;
        if (self.bytes_read != self.expected_size) return error.CorruptExtentTree;
    }

    fn ensureChunk(self: *Reader) !bool {
        if (self.current_packed_reader) |*packed_reader| {
            if (packed_reader.remaining != 0) return true;
            try packed_reader.finish();
            packed_reader.deinit();
            self.current_packed_reader = null;
        }
        if (self.current_chunk.len != 0 and self.current_chunk_offset < self.current_chunk.len) return true;
        if (self.current_chunk.len != 0) {
            self.alloc.free(self.current_chunk);
            self.current_chunk = &[_]u8{};
            self.current_chunk_offset = 0;
        }
        if (self.next_entry_idx >= self.entries.len) return false;

        const entry = self.entries[self.next_entry_idx];
        self.next_entry_idx += 1;
        if (entry.object_type != .blob) return error.InvalidExtentChunkObject;

        if (try self.store.openPackedBlobReader(self.alloc, entry.object_id)) |packed_reader| {
            self.current_packed_reader = packed_reader;
            return true;
        }

        const chunk = try self.store.get(self.alloc, entry.object_id);
        errdefer self.alloc.free(chunk.payload);
        if (chunk.obj_type != .blob) return error.InvalidExtentChunkObject;
        self.current_chunk = chunk.payload;
        self.current_chunk_offset = 0;
        return true;
    }
};

const TreeEntry = struct {
    name: []u8,
    object_type: object_store.ObjectType,
    object_id: object_store.ObjectId,

    fn deinit(self: *TreeEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub fn writeAll(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    bytes: []const u8,
    chunk_bytes: u32,
) !WriteResult {
    const effective_chunk_bytes = if (chunk_bytes == 0) DefaultChunkBytes else chunk_bytes;
    var entries = std.array_list.Managed(TreeEntry).init(alloc);
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    var offset: usize = 0;
    var index: usize = 0;
    while (offset < bytes.len) : (index += 1) {
        const end = @min(bytes.len, offset + effective_chunk_bytes);
        const chunk_id = try store.put(.blob, bytes[offset..end]);
        try entries.append(.{
            .name = try std.fmt.allocPrint(alloc, "{d:0>16}", .{index}),
            .object_type = .blob,
            .object_id = chunk_id,
        });
        offset = end;
    }

    const payload = try encodeTree(alloc, entries.items);
    defer alloc.free(payload);
    return .{
        .root_id = try store.put(.tree, payload),
        .size_bytes = bytes.len,
        .chunk_bytes = effective_chunk_bytes,
    };
}

pub fn readAll(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    tree_ref: anytype,
) ![]u8 {
    var reader = try openReader(alloc, store, tree_ref);
    defer reader.deinit();
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();
    try bytes.ensureTotalCapacity(@intCast(tree_ref.size_bytes));
    var scratch: [8192]u8 = undefined;
    while (true) {
        const read_len = try reader.read(scratch[0..]);
        if (read_len == 0) break;
        try bytes.appendSlice(scratch[0..read_len]);
    }
    try reader.finish();
    if (bytes.items.len != tree_ref.size_bytes) return error.CorruptExtentTree;
    return try bytes.toOwnedSlice();
}

pub fn openReader(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    tree_ref: anytype,
) !Reader {
    if (tree_ref.size_bytes == 0) {
        return .{
            .alloc = alloc,
            .store = store,
            .entries = try alloc.alloc(TreeEntry, 0),
            .expected_size = 0,
        };
    }

    const loaded = try store.get(alloc, tree_ref.root_id);
    defer alloc.free(loaded.payload);
    if (loaded.obj_type != .tree) return error.InvalidExtentTreeObject;

    return .{
        .alloc = alloc,
        .store = store,
        .entries = try decodeTree(alloc, loaded.payload),
        .expected_size = @intCast(tree_ref.size_bytes),
    };
}

fn encodeTree(alloc: std.mem.Allocator, entries: []const TreeEntry) ![]u8 {
    var copy_entries = try alloc.alloc(TreeEntry, entries.len);
    defer {
        for (copy_entries) |*entry| entry.deinit(alloc);
        alloc.free(copy_entries);
    }
    for (entries, 0..) |entry, idx| {
        copy_entries[idx] = .{
            .name = try alloc.dupe(u8, entry.name),
            .object_type = entry.object_type,
            .object_id = entry.object_id,
        };
    }
    std.sort.block(TreeEntry, copy_entries, {}, struct {
        fn lessThan(_: void, lhs: TreeEntry, rhs: TreeEntry) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();
    try bytes.append(1);
    try appendInt(&bytes, u32, @intCast(copy_entries.len));
    for (copy_entries) |entry| {
        try appendString(&bytes, entry.name);
        try bytes.append(@intFromEnum(entry.object_type));
        try bytes.appendSlice(entry.object_id.hash[0..]);
    }
    return try bytes.toOwnedSlice();
}

fn decodeTree(alloc: std.mem.Allocator, payload: []const u8) ![]TreeEntry {
    if (payload.len == 0 or payload[0] != 1) return error.UnsupportedExtentTreeVersion;
    var cursor: usize = 1;
    const entry_count = try readIntAt(payload, &cursor, u32);
    var decoded_count: usize = 0;
    var entries = try alloc.alloc(TreeEntry, entry_count);
    errdefer {
        for (entries[0..decoded_count]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    for (entries) |*entry| entry.* = .{ .name = &[_]u8{}, .object_type = .blob, .object_id = undefined };

    var idx: usize = 0;
    while (idx < entry_count) : (idx += 1) {
        const name = try readOwnedStringAt(alloc, payload, &cursor);
        errdefer alloc.free(name);
        const object_type = std.meta.intToEnum(object_store.ObjectType, try readByteAt(payload, &cursor)) catch return error.UnknownTreeObjectType;
        entries[idx] = .{
            .name = name,
            .object_type = object_type,
            .object_id = .{ .hash = try readHashAt(payload, &cursor) },
        };
        decoded_count += 1;
    }
    if (cursor != payload.len) return error.ExtraObjectBytes;
    return entries;
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

fn readByteAt(payload: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= payload.len) return error.TruncatedObject;
    const out = payload[cursor.*];
    cursor.* += 1;
    return out;
}

fn readIntAt(payload: []const u8, cursor: *usize, comptime T: type) !T {
    const size = @sizeOf(T);
    if (cursor.* + size > payload.len) return error.TruncatedObject;
    const out = std.mem.readInt(T, @as(*const [size]u8, @ptrCast(payload[cursor.* .. cursor.* + size].ptr)), .little);
    cursor.* += size;
    return out;
}

fn readHashAt(payload: []const u8, cursor: *usize) ![32]u8 {
    if (cursor.* + 32 > payload.len) return error.TruncatedObject;
    var out: [32]u8 = undefined;
    @memcpy(out[0..], payload[cursor.* .. cursor.* + 32]);
    cursor.* += 32;
    return out;
}

fn readOwnedStringAt(alloc: std.mem.Allocator, payload: []const u8, cursor: *usize) ![]u8 {
    const len = try readIntAt(payload, cursor, u32);
    if (cursor.* + len > payload.len) return error.TruncatedObject;
    const out = try alloc.dupe(u8, payload[cursor.* .. cursor.* + len]);
    cursor.* += len;
    return out;
}

test "extent trees round-trip chunked content" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/extent-store", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try object_store.ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const payload = "abcdefghijklmnopqrstuvwxyz0123456789";
    const written = try writeAll(std.testing.allocator, &store, payload, 8);
    const restored = try readAll(std.testing.allocator, &store, written);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqualStrings(payload, restored);
    try std.testing.expectEqual(@as(u64, payload.len), written.size_bytes);
    try std.testing.expectEqual(@as(u32, 8), written.chunk_bytes);
}

test "extent reader streams packed chunks after loose copies are pruned" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/extent-store-packed", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(store_path);
    var store = try object_store.ObjectStore.init(std.testing.allocator, store_path, .none);
    defer store.deinit();

    const payload = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const written = try writeAll(std.testing.allocator, &store, payload, 7);

    const ids = try store.listIds(std.testing.allocator);
    defer std.testing.allocator.free(ids);
    var pack_write = try store.writePack(std.testing.allocator, ids);
    defer pack_write.deinit(std.testing.allocator);

    var reader = try openReader(std.testing.allocator, &store, written);
    defer reader.deinit();
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    var scratch: [5]u8 = undefined;
    while (true) {
        const read_len = try reader.read(scratch[0..]);
        if (read_len == 0) break;
        try out.appendSlice(scratch[0..read_len]);
    }
    try reader.finish();
    try std.testing.expectEqualStrings(payload, out.items);
}
