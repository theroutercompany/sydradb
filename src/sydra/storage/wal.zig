const std = @import("std");
const cfg = @import("../config.zig");
const object_store = @import("object_store.zig");

// WAL v0:
// Type 1 = Put: [u32 len][u8 type][u64 series_id][i64 ts][f64 value][u32 crc32]
// Type 2 = SeriesRegistration: [u32 len][u8 type][u64 series_id][u32 series_len][u32 tags_len][series bytes][canonical tags bytes][u32 crc32]

pub const JournalFrameIndexEntry = struct {
    offset: u64,
    size_bytes: u32,
};

pub const JournalFrameIndex = struct {
    entries: []JournalFrameIndexEntry,

    pub fn deinit(self: *JournalFrameIndex, alloc: std.mem.Allocator) void {
        alloc.free(self.entries);
    }
};

pub const JournalMeta = struct {
    file_size: u64,
    frame_count: u32,
};

const journal_meta_version: u8 = 1;
const journal_frame_index_version: u8 = 1;

const TreeEntry = struct {
    name: []u8,
    object_type: object_store.ObjectType,
    object_id: object_store.ObjectId,

    fn deinit(self: *TreeEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub const WAL = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    fsync: cfg.FsyncPolicy,
    file: std.fs.File,
    bytes_written: usize,

    pub fn open(alloc: std.mem.Allocator, data_dir: std.fs.Dir, policy: cfg.FsyncPolicy) !WAL {
        data_dir.makePath("wal") catch {};
        const open_flags = std.fs.File.OpenFlags{ .mode = .read_write };
        var f = data_dir.openFile("wal/current.wal", open_flags) catch |err| switch (err) {
            error.FileNotFound => try data_dir.createFile("wal/current.wal", .{ .read = true }),
            else => return err,
        };
        const end_pos = try f.getEndPos();
        try f.seekFromEnd(0);
        return .{ .alloc = alloc, .dir = data_dir, .fsync = policy, .file = f, .bytes_written = @intCast(end_pos) };
    }

    pub fn close(self: *WAL) void {
        self.file.close();
    }

    pub fn append(self: *WAL, series_id: u64, ts: i64, value: f64) !u32 {
        var buf: [1 + 8 + 8 + 8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        try w.writeByte(1); // type
        try w.writeInt(u64, series_id, .little);
        try w.writeInt(i64, ts, .little);
        const uv: u64 = @bitCast(value);
        try w.writeInt(u64, uv, .little);
        const payload = fbs.getWritten();
        var header: [4]u8 = undefined;
        const plen: u32 = @intCast(payload.len);
        std.mem.writeInt(u32, &header, plen, .little);
        try self.file.writeAll(&header);
        try self.file.writeAll(payload);
        var crc = std.hash.Crc32.init();
        crc.update(payload);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc.final(), .little);
        try self.file.writeAll(&crc_bytes);
        const total_bytes: usize = header.len + payload.len + 4;
        self.bytes_written += total_bytes;
        switch (self.fsync) {
            .always => try self.file.sync(),
            .interval => {},
            .none => {},
        }
        return @intCast(total_bytes);
    }

    pub fn appendSeriesRegistration(self: *WAL, series_id: u64, series: []const u8, canonical_tags: []const u8) !u32 {
        var payload = std.array_list.Managed(u8).init(self.alloc);
        defer payload.deinit();

        var writer = payload.writer();
        try writer.writeByte(2);
        try writer.writeInt(u64, series_id, .little);
        try writer.writeInt(u32, @intCast(series.len), .little);
        try writer.writeInt(u32, @intCast(canonical_tags.len), .little);
        try writer.writeAll(series);
        try writer.writeAll(canonical_tags);
        return try appendPayload(self, payload.items);
    }

    pub fn rotateIfNeeded(self: *WAL) !void {
        if (self.bytes_written < 64 * 1024 * 1024) return; // 64 MiB
        self.file.close();
        // move current to wal/<epoch>.wal
        const now = std.time.milliTimestamp();
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "wal/{d}.wal", .{now});
        try self.dir.rename("wal/current.wal", name);
        self.file = try self.dir.createFile("wal/current.wal", .{ .read = true });
        self.bytes_written = 0;
    }

    pub fn replay(self: *WAL, alloc: std.mem.Allocator, ctx: anytype) !void {
        const files = try listWalFiles(alloc, self.dir);
        defer freeWalFiles(alloc, files);
        try self.replayFiles(alloc, files, ctx);
    }

    pub fn replayFiles(self: *WAL, alloc: std.mem.Allocator, files: []const []const u8, ctx: anytype) !void {
        var wal_dir = self.dir.openDir("wal", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer wal_dir.close();

        const ctx_ptr = @constCast(ctx);
        for (files) |name| {
            try replayFile(alloc, wal_dir, name, ctx_ptr);
        }
    }

    pub fn replayFileFromOffset(self: *WAL, alloc: std.mem.Allocator, file_name: []const u8, offset: u64, ctx: anytype) !void {
        var wal_dir = self.dir.openDir("wal", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer wal_dir.close();

        var file = try wal_dir.openFile(file_name, .{});
        defer file.close();
        try file.seekTo(offset);

        var read_buf: [4096]u8 = undefined;
        var reader_state = file.reader(&read_buf);
        const reader = std.Io.Reader.adaptToOldInterface(&reader_state.interface);
        const ctx_ptr = @constCast(ctx);
        try replayReader(alloc, reader, ctx_ptr);
    }
};

pub const WalFileInfo = struct {
    name: []u8,
    size: u64,
    hash: [32]u8,
};

pub fn listWalFiles(alloc: std.mem.Allocator, data_dir: std.fs.Dir) ![][]u8 {
    var wal_dir = data_dir.openDir("wal", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc([]u8, 0),
        else => return err,
    };
    defer wal_dir.close();

    var files = try std.array_list.Managed([]u8).initCapacity(alloc, 0);
    errdefer {
        for (files.items) |name| alloc.free(name);
        files.deinit();
    }

    var it = wal_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wal")) continue;
        try files.append(try alloc.dupe(u8, entry.name));
    }

    sortWalFiles(files.items);
    return try files.toOwnedSlice();
}

pub fn freeWalFiles(alloc: std.mem.Allocator, files: [][]u8) void {
    for (files) |name| alloc.free(name);
    alloc.free(files);
}

pub fn freeWalFileInfos(alloc: std.mem.Allocator, files: []WalFileInfo) void {
    for (files) |file| alloc.free(file.name);
    alloc.free(files);
}

pub fn collectWalFileInfos(alloc: std.mem.Allocator, data_dir: std.fs.Dir) ![]WalFileInfo {
    const files = try listWalFiles(alloc, data_dir);
    defer freeWalFiles(alloc, files);

    var infos = std.array_list.Managed(WalFileInfo).init(alloc);
    errdefer {
        for (infos.items) |info| alloc.free(info.name);
        infos.deinit();
    }

    for (files) |name| {
        const path = try std.fmt.allocPrint(alloc, "wal/{s}", .{name});
        defer alloc.free(path);

        var file = try data_dir.openFile(path, .{});
        defer file.close();
        const stat = try file.stat();

        var buf: [8192]u8 = undefined;
        var hasher = std.crypto.hash.Blake3.init(.{});
        while (true) {
            const bytes_read = try file.read(buf[0..]);
            if (bytes_read == 0) break;
            hasher.update(buf[0..bytes_read]);
        }
        var out: [32]u8 = undefined;
        hasher.final(out[0..]);

        try infos.append(.{
            .name = try alloc.dupe(u8, name),
            .size = stat.size,
            .hash = out,
        });
    }

    return try infos.toOwnedSlice();
}

fn replayFile(alloc: std.mem.Allocator, wal_dir: std.fs.Dir, file_name: []const u8, ctx: anytype) !void {
    var file = try wal_dir.openFile(file_name, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var reader_state = file.reader(&read_buf);
    const reader = std.Io.Reader.adaptToOldInterface(&reader_state.interface);
    try replayReader(alloc, reader, ctx);
}

pub fn replayBytes(alloc: std.mem.Allocator, bytes: []const u8, ctx: anytype) !void {
    var stream = std.io.fixedBufferStream(bytes);
    try replayReader(alloc, stream.reader().any(), ctx);
}

pub fn filePrefixMatches(data_dir: std.fs.Dir, path: []const u8, expected_prefix: []const u8) !bool {
    var file = data_dir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    var remaining = expected_prefix;
    var scratch: [4096]u8 = undefined;
    while (remaining.len > 0) {
        const chunk_len = @min(remaining.len, scratch.len);
        const read_len = try file.readAll(scratch[0..chunk_len]);
        if (read_len != chunk_len) return false;
        if (!std.mem.eql(u8, scratch[0..chunk_len], remaining[0..chunk_len])) return false;
        remaining = remaining[chunk_len..];
    }
    return true;
}

pub fn writeJournalRootForWalFile(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    wal_name: []const u8,
) !object_store.ObjectId {
    const path = try std.fmt.allocPrint(alloc, "wal/{s}", .{wal_name});
    defer alloc.free(path);
    const bytes = try data_dir.readFileAlloc(alloc, path, 128 * 1024 * 1024);
    defer alloc.free(bytes);
    return try writeJournalRootFromBytes(alloc, store, bytes);
}

pub fn writeJournalRootFromBytes(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    bytes: []const u8,
) !object_store.ObjectId {
    var frame_entries = std.array_list.Managed(TreeEntry).init(alloc);
    defer {
        for (frame_entries.items) |*entry| entry.deinit(alloc);
        frame_entries.deinit();
    }

    var index_entries = std.array_list.Managed(JournalFrameIndexEntry).init(alloc);
    defer index_entries.deinit();

    var offset: usize = 0;
    var frame_idx: usize = 0;
    while (offset < bytes.len) : (frame_idx += 1) {
        if (offset + 4 > bytes.len) return error.CorruptWal;
        const payload_len = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(bytes[offset .. offset + 4].ptr)), .little);
        if (payload_len == 0 or payload_len > (1 << 20)) return error.CorruptWal;
        const frame_len: usize = 4 + payload_len + 4;
        if (offset + frame_len > bytes.len) return error.CorruptWal;

        const frame_id = try store.put(.blob, bytes[offset .. offset + frame_len]);
        try frame_entries.append(.{
            .name = try std.fmt.allocPrint(alloc, "{d:0>16}", .{frame_idx}),
            .object_type = .blob,
            .object_id = frame_id,
        });
        try index_entries.append(.{
            .offset = offset,
            .size_bytes = @intCast(frame_len),
        });
        offset += frame_len;
    }

    const meta_payload = try encodeJournalMeta(alloc, .{
        .file_size = bytes.len,
        .frame_count = @intCast(index_entries.items.len),
    });
    defer alloc.free(meta_payload);
    const meta_id = try store.put(.blob, meta_payload);

    const frame_index_payload = try encodeJournalFrameIndex(alloc, index_entries.items);
    defer alloc.free(frame_index_payload);
    const frame_index_id = try store.put(.blob, frame_index_payload);

    const frames_tree_id = try putTree(alloc, store, frame_entries.items);

    var root_entries = [_]TreeEntry{
        .{
            .name = try alloc.dupe(u8, "frame_index"),
            .object_type = .blob,
            .object_id = frame_index_id,
        },
        .{
            .name = try alloc.dupe(u8, "frames"),
            .object_type = .tree,
            .object_id = frames_tree_id,
        },
        .{
            .name = try alloc.dupe(u8, "meta"),
            .object_type = .blob,
            .object_id = meta_id,
        },
    };
    defer {
        for (&root_entries) |*entry| entry.deinit(alloc);
    }
    return try putTree(alloc, store, root_entries[0..]);
}

pub fn replayJournalRoot(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
    captured_bytes: u64,
    ctx: anytype,
) !void {
    const journal_bytes = try readJournalBytes(alloc, store, root_id, captured_bytes);
    defer alloc.free(journal_bytes);
    try replayBytes(alloc, journal_bytes, ctx);
}

pub fn journalPrefixMatchesFile(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    path: []const u8,
    root_id: object_store.ObjectId,
    captured_bytes: u64,
) !bool {
    const journal_bytes = try readJournalBytes(alloc, store, root_id, captured_bytes);
    defer alloc.free(journal_bytes);
    return try filePrefixMatches(data_dir, path, journal_bytes);
}

fn readJournalBytes(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
    captured_bytes: u64,
) ![]u8 {
    var root_tree = try loadTreeObject(alloc, store, root_id);
    defer root_tree.deinit(alloc);

    const meta_id = findTreeEntry(root_tree.entries, "meta", .blob) orelse return error.MissingJournalMeta;
    const frame_index_id = findTreeEntry(root_tree.entries, "frame_index", .blob) orelse return error.MissingJournalFrameIndex;
    const frames_id = findTreeEntry(root_tree.entries, "frames", .tree) orelse return error.MissingJournalFrames;

    const meta_payload = try loadBlobObject(alloc, store, meta_id);
    defer alloc.free(meta_payload);
    const meta = try decodeJournalMeta(meta_payload);
    if (captured_bytes > meta.file_size) return error.CorruptJournalRoot;

    const frame_index_payload = try loadBlobObject(alloc, store, frame_index_id);
    defer alloc.free(frame_index_payload);
    var frame_index = try decodeJournalFrameIndex(alloc, frame_index_payload);
    defer frame_index.deinit(alloc);

    var frames_tree = try loadTreeObject(alloc, store, frames_id);
    defer frames_tree.deinit(alloc);
    if (frames_tree.entries.len != frame_index.entries.len) return error.CorruptJournalRoot;

    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    var appended_bytes: u64 = 0;
    for (frame_index.entries, frames_tree.entries) |entry, frame_tree_entry| {
        if (entry.offset + entry.size_bytes > captured_bytes) break;
        if (frame_tree_entry.object_type != .blob) return error.InvalidJournalFrameObject;
        const frame_payload = try loadBlobObject(alloc, store, frame_tree_entry.object_id);
        defer alloc.free(frame_payload);
        try bytes.appendSlice(frame_payload);
        appended_bytes += frame_payload.len;
    }
    if (appended_bytes != captured_bytes) return error.CorruptJournalRoot;
    return try bytes.toOwnedSlice();
}

fn replayReader(alloc: std.mem.Allocator, reader: anytype, ctx: anytype) !void {
    while (true) {
        var len_buf: [4]u8 = undefined;
        const len_read = try reader.read(&len_buf);
        if (len_read == 0) break;
        if (len_read != 4) return error.CorruptWal;

        const payload_len = std.mem.readInt(u32, &len_buf, .little);
        if (payload_len == 0 or payload_len > (1 << 20)) return error.CorruptWal;

        const payload = try alloc.alloc(u8, payload_len);
        defer alloc.free(payload);
        try readExact(reader, payload);

        var crc_buf: [4]u8 = undefined;
        try readExact(reader, crc_buf[0..4]);
        const expected_crc = std.mem.readInt(u32, &crc_buf, .little);
        var crc = std.hash.Crc32.init();
        crc.update(payload);
        if (crc.final() != expected_crc) return error.CorruptWal;

        switch (payload[0]) {
            1 => {
                if (payload.len < 1 + 8 + 8 + 8) continue;
                const sid = std.mem.readInt(u64, payload[1 .. 1 + 8], .little);
                const ts = std.mem.readInt(i64, payload[9 .. 9 + 8], .little);
                const val_bits = std.mem.readInt(u64, payload[17 .. 17 + 8], .little);
                const value: f64 = @bitCast(val_bits);
                try ctx.onRecord(sid, ts, value);
            },
            2 => {
                if (payload.len < 1 + 8 + 4 + 4) return error.CorruptWal;
                const sid = std.mem.readInt(u64, payload[1 .. 1 + 8], .little);
                const series_len = std.mem.readInt(u32, payload[9 .. 9 + 4], .little);
                const tags_len = std.mem.readInt(u32, payload[13 .. 13 + 4], .little);
                const expected_len = 1 + 8 + 4 + 4 + @as(usize, series_len) + @as(usize, tags_len);
                if (payload.len != expected_len) return error.CorruptWal;
                const series_start = 17;
                const tags_start = series_start + series_len;
                const series = payload[series_start..tags_start];
                const tags = payload[tags_start .. tags_start + tags_len];
                if (@hasDecl(@TypeOf(ctx.*), "onSeriesRegistration")) {
                    try ctx.onSeriesRegistration(sid, series, tags);
                }
            },
            else => continue,
        }
    }
}

fn appendPayload(self: *WAL, payload: []const u8) !u32 {
    var header: [4]u8 = undefined;
    const plen: u32 = @intCast(payload.len);
    std.mem.writeInt(u32, &header, plen, .little);
    try self.file.writeAll(&header);
    try self.file.writeAll(payload);
    var crc = std.hash.Crc32.init();
    crc.update(payload);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .little);
    try self.file.writeAll(&crc_bytes);
    const total_bytes: usize = header.len + payload.len + 4;
    self.bytes_written += total_bytes;
    switch (self.fsync) {
        .always => try self.file.sync(),
        .interval => {},
        .none => {},
    }
    return @intCast(total_bytes);
}

fn sortWalFiles(files: [][]u8) void {
    std.sort.block([]u8, files, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const is_a_current = std.mem.eql(u8, a, "current.wal");
            const is_b_current = std.mem.eql(u8, b, "current.wal");
            if (is_a_current and !is_b_current) return false;
            if (!is_a_current and is_b_current) return true;
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn readExact(reader: std.Io.AnyReader, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try reader.read(buf[offset..]);
        if (n == 0) return error.CorruptWal;
        offset += n;
    }
}

test "wal replays series registrations before point records" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var wal = try WAL.open(alloc, tmp.dir, .none);
    defer wal.close();

    _ = try wal.appendSeriesRegistration(77, "weather.room4", "{\"host\":\"b\"}");
    _ = try wal.append(77, 1_000, 3.5);

    var ctx = struct {
        alloc: std.mem.Allocator,
        registered: bool = false,
        seen_series_id: ?u64 = null,
        seen_series: ?[]const u8 = null,
        seen_tags: ?[]const u8 = null,
        point_count: usize = 0,

        pub fn onSeriesRegistration(self: *@This(), series_id: u64, series: []const u8, canonical_tags: []const u8) !void {
            self.registered = true;
            self.seen_series_id = series_id;
            if (self.seen_series) |existing| self.alloc.free(existing);
            if (self.seen_tags) |existing| self.alloc.free(existing);
            self.seen_series = try self.alloc.dupe(u8, series);
            self.seen_tags = try self.alloc.dupe(u8, canonical_tags);
        }

        pub fn onRecord(self: *@This(), series_id: u64, ts: i64, value: f64) !void {
            try std.testing.expect(self.registered);
            try std.testing.expectEqual(@as(u64, 77), series_id);
            try std.testing.expectEqual(@as(i64, 1_000), ts);
            try std.testing.expectApproxEqAbs(@as(f64, 3.5), value, 1e-9);
            self.point_count += 1;
        }
    }{ .alloc = alloc };
    defer {
        if (ctx.seen_series) |series| alloc.free(series);
        if (ctx.seen_tags) |tags| alloc.free(tags);
    }

    try wal.replay(alloc, &ctx);

    try std.testing.expect(ctx.registered);
    try std.testing.expectEqual(@as(u64, 77), ctx.seen_series_id.?);
    try std.testing.expectEqualStrings("weather.room4", ctx.seen_series.?);
    try std.testing.expectEqualStrings("{\"host\":\"b\"}", ctx.seen_tags.?);
    try std.testing.expectEqual(@as(usize, 1), ctx.point_count);
}

test "journal roots replay captured wal frames in order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const store_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/wal-journal-store", .{tmp.sub_path});
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    var wal = try WAL.open(alloc, tmp.dir, .none);
    defer wal.close();
    const registration_bytes = try wal.appendSeriesRegistration(77, "metric.room7", "{\"host\":\"b\"}");
    const first_bytes = try wal.append(77, 1_000, 3.5);
    _ = try wal.append(77, 1_005, 4.5);

    const root_id = try writeJournalRootForWalFile(alloc, tmp.dir, &store, "current.wal");

    var ctx = struct {
        registered: bool = false,
        point_count: usize = 0,

        pub fn onSeriesRegistration(self: *@This(), series_id: u64, series: []const u8, canonical_tags: []const u8) !void {
            try std.testing.expectEqual(@as(u64, 77), series_id);
            try std.testing.expectEqualStrings("metric.room7", series);
            try std.testing.expectEqualStrings("{\"host\":\"b\"}", canonical_tags);
            self.registered = true;
        }

        pub fn onRecord(self: *@This(), series_id: u64, ts: i64, value: f64) !void {
            try std.testing.expect(self.registered);
            try std.testing.expectEqual(@as(u64, 77), series_id);
            try std.testing.expect(ts == 1_000 or ts == 1_005);
            _ = value;
            self.point_count += 1;
        }
    }{};

    try replayJournalRoot(alloc, &store, root_id, registration_bytes + first_bytes, &ctx);
    try std.testing.expect(ctx.registered);
    try std.testing.expectEqual(@as(usize, 1), ctx.point_count);
}

fn encodeJournalMeta(alloc: std.mem.Allocator, meta: JournalMeta) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();
    try bytes.append(journal_meta_version);
    try appendInt(&bytes, u64, meta.file_size);
    try appendInt(&bytes, u32, meta.frame_count);
    return try bytes.toOwnedSlice();
}

fn decodeJournalMeta(payload: []const u8) !JournalMeta {
    var cursor: usize = 0;
    if (try readByteAt(payload, &cursor) != journal_meta_version) return error.UnsupportedJournalMetaVersion;
    const meta = JournalMeta{
        .file_size = try readIntAt(payload, &cursor, u64),
        .frame_count = try readIntAt(payload, &cursor, u32),
    };
    if (cursor != payload.len) return error.ExtraJournalMetaBytes;
    return meta;
}

fn encodeJournalFrameIndex(alloc: std.mem.Allocator, entries: []const JournalFrameIndexEntry) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();
    try bytes.append(journal_frame_index_version);
    try appendInt(&bytes, u32, @intCast(entries.len));
    for (entries) |entry| {
        try appendInt(&bytes, u64, entry.offset);
        try appendInt(&bytes, u32, entry.size_bytes);
    }
    return try bytes.toOwnedSlice();
}

fn decodeJournalFrameIndex(alloc: std.mem.Allocator, payload: []const u8) !JournalFrameIndex {
    var cursor: usize = 0;
    if (try readByteAt(payload, &cursor) != journal_frame_index_version) return error.UnsupportedJournalFrameIndexVersion;
    const entry_count = try readIntAt(payload, &cursor, u32);
    const entries = try alloc.alloc(JournalFrameIndexEntry, entry_count);
    for (entries, 0..) |*entry, idx| {
        _ = idx;
        entry.* = .{
            .offset = try readIntAt(payload, &cursor, u64),
            .size_bytes = try readIntAt(payload, &cursor, u32),
        };
    }
    if (cursor != payload.len) return error.ExtraJournalFrameIndexBytes;
    return .{ .entries = entries };
}

fn putTree(alloc: std.mem.Allocator, store: *object_store.ObjectStore, entries: []const TreeEntry) !object_store.ObjectId {
    const payload = try encodeTree(alloc, entries);
    defer alloc.free(payload);
    return try store.put(.tree, payload);
}

fn loadTreeObject(alloc: std.mem.Allocator, store: *object_store.ObjectStore, id: object_store.ObjectId) !struct {
    entries: []TreeEntry,
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
} {
    const loaded = try store.get(alloc, id);
    defer alloc.free(loaded.payload);
    if (loaded.obj_type != .tree) return error.InvalidJournalTree;
    return .{ .entries = try decodeTree(alloc, loaded.payload) };
}

fn loadBlobObject(alloc: std.mem.Allocator, store: *object_store.ObjectStore, id: object_store.ObjectId) ![]u8 {
    const loaded = try store.get(alloc, id);
    errdefer alloc.free(loaded.payload);
    if (loaded.obj_type != .blob) return error.InvalidJournalBlob;
    return loaded.payload;
}

fn findTreeEntry(entries: []const TreeEntry, name: []const u8, object_type: object_store.ObjectType) ?object_store.ObjectId {
    for (entries) |entry| {
        if (entry.object_type != object_type) continue;
        if (std.mem.eql(u8, entry.name, name)) return entry.object_id;
    }
    return null;
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
    var cursor: usize = 0;
    if (try readByteAt(payload, &cursor) != 1) return error.UnsupportedJournalTreeVersion;
    const entry_count = try readIntAt(payload, &cursor, u32);
    var entries = try alloc.alloc(TreeEntry, entry_count);
    var decoded_count: usize = 0;
    errdefer {
        for (entries[0..decoded_count]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    while (decoded_count < entry_count) : (decoded_count += 1) {
        const name = try readOwnedStringAt(alloc, payload, &cursor);
        errdefer alloc.free(name);
        entries[decoded_count] = .{
            .name = name,
            .object_type = std.meta.intToEnum(object_store.ObjectType, try readByteAt(payload, &cursor)) catch return error.UnknownTreeObjectType,
            .object_id = .{ .hash = try readHashAt(payload, &cursor) },
        };
    }
    if (cursor != payload.len) return error.ExtraJournalTreeBytes;
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
    if (cursor.* >= payload.len) return error.TruncatedJournalObject;
    const out = payload[cursor.*];
    cursor.* += 1;
    return out;
}

fn readIntAt(payload: []const u8, cursor: *usize, comptime T: type) !T {
    const size = @sizeOf(T);
    if (cursor.* + size > payload.len) return error.TruncatedJournalObject;
    const out = std.mem.readInt(T, @as(*const [size]u8, @ptrCast(payload[cursor.* .. cursor.* + size].ptr)), .little);
    cursor.* += size;
    return out;
}

fn readHashAt(payload: []const u8, cursor: *usize) ![32]u8 {
    if (cursor.* + 32 > payload.len) return error.TruncatedJournalObject;
    var out: [32]u8 = undefined;
    @memcpy(out[0..], payload[cursor.* .. cursor.* + 32]);
    cursor.* += 32;
    return out;
}

fn readOwnedStringAt(alloc: std.mem.Allocator, payload: []const u8, cursor: *usize) ![]u8 {
    const len = try readIntAt(payload, cursor, u32);
    if (cursor.* + len > payload.len) return error.TruncatedJournalObject;
    const out = try alloc.dupe(u8, payload[cursor.* .. cursor.* + len]);
    cursor.* += len;
    return out;
}
