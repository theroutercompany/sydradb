const std = @import("std");
const types = @import("../types.zig");

pub const manifest_path = "MANIFEST";
pub const repair_intent_path = "MANIFEST.repair";

pub const Entry = struct {
    series_id: types.SeriesId,
    hour_bucket: i64,
    start_ts: i64,
    end_ts: i64,
    count: u32,
    path: []u8,
};

pub const AddInput = struct {
    series_id: types.SeriesId,
    hour_bucket: i64,
    start_ts: i64,
    end_ts: i64,
    count: u32,
    path: []const u8,
};

pub const Manifest = struct {
    alloc: std.mem.Allocator,
    // Use Unmanaged to be stable across Zig versions; pass allocator on mutation
    entries: std.ArrayListUnmanaged(Entry),
    repaired_torn_tail: bool = false,

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir) !Manifest {
        return try loadOrInitWithRepairIntent(alloc, data_dir, false);
    }

    pub fn loadOrInitWithRepairIntent(
        alloc: std.mem.Allocator,
        data_dir: std.fs.Dir,
        persist_repair_intent: bool,
    ) !Manifest {
        var mf = Manifest{ .alloc = alloc, .entries = .{} };
        errdefer mf.deinit();
        mf.repaired_torn_tail = try repairIntentExists(data_dir);

        // create directory structure
        data_dir.makePath("segments") catch {};
        const OpenFlags = std.fs.File.OpenFlags;
        const open_opts: OpenFlags = if (@hasField(OpenFlags, "write"))
            OpenFlags{ .write = true, .read = true }
        else
            OpenFlags{ .mode = .read_write };
        var file = data_dir.openFile(manifest_path, open_opts) catch |e| switch (e) {
            error.FileNotFound => blk: {
                var f = try data_dir.createFile(manifest_path, .{ .read = true });
                f.close();
                break :blk try data_dir.openFile(manifest_path, open_opts);
            },
            else => return e,
        };
        defer file.close();
        // Only newline-terminated records were completely appended. A crash can
        // leave one final fragment; drop it so WAL replay can rebuild the entry.
        const body = try file.readToEndAlloc(alloc, 1024 * 1024 * 64);
        defer alloc.free(body);

        const complete_end = if (body.len == 0 or body[body.len - 1] == '\n')
            body.len
        else if (std.mem.lastIndexOfScalar(u8, body, '\n')) |newline_index|
            newline_index + 1
        else
            0;

        var it = std.mem.splitScalar(u8, body[0..complete_end], '\n');
        while (it.next()) |raw_line| {
            const s = std.mem.trim(u8, raw_line, " \t\r\n");
            if (s.len == 0) continue;
            const entry = try parseEntry(alloc, s);
            mf.entries.append(alloc, entry) catch |err| {
                alloc.free(entry.path);
                return err;
            };
        }

        if (complete_end != body.len) {
            if (persist_repair_intent) try ensureRepairIntent(data_dir);
            try file.setEndPos(complete_end);
            try file.sync();
            mf.repaired_torn_tail = mf.repaired_torn_tail or persist_repair_intent;
        }
        return mf;
    }

    pub fn repairIntentExists(data_dir: std.fs.Dir) !bool {
        var file = data_dir.openFile(repair_intent_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close();
        if ((try file.stat()).size != 0) return error.InvalidManifestRepairIntent;
        return true;
    }

    pub fn clearRepairIntent(data_dir: std.fs.Dir) !void {
        try data_dir.deleteFile(repair_intent_path);
        try syncDirectory(data_dir);
    }

    pub fn deinit(self: *Manifest) void {
        for (self.entries.items) |*e| self.alloc.free(e.path);
        self.entries.deinit(self.alloc);
    }

    pub fn maxEndTs(self: *const Manifest, sid: types.SeriesId) ?i64 {
        var result: ?i64 = null;
        for (self.entries.items) |e| {
            if (e.series_id != sid) continue;
            if (result) |existing| {
                if (e.end_ts > existing) result = e.end_ts;
            } else {
                result = e.end_ts;
            }
        }
        return result;
    }

    pub fn appendEntry(self: *Manifest, entry: Entry) !void {
        try self.entries.append(self.alloc, entry);
    }

    pub fn add(self: *Manifest, data_dir: std.fs.Dir, sid: types.SeriesId, hour: i64, start_ts: i64, end_ts: i64, count: u32, segment_path: []const u8) !void {
        // append line to MANIFEST
        const OpenFlags = std.fs.File.OpenFlags;
        const open_opts: OpenFlags = if (@hasField(OpenFlags, "write"))
            OpenFlags{ .write = true, .read = true }
        else
            OpenFlags{ .mode = .read_write };
        var file = data_dir.openFile(manifest_path, open_opts) catch |err| switch (err) {
            error.FileNotFound => try data_dir.createFile(manifest_path, .{ .read = true }),
            else => return err,
        };
        defer file.close();
        const end_pos = try file.getEndPos();
        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        try writer_state.seekTo(end_pos);
        var writer = anyWriter(&writer_state.interface);
        try writeEntry(&writer, .{
            .series_id = sid,
            .hour_bucket = hour,
            .start_ts = start_ts,
            .end_ts = end_ts,
            .count = count,
            .path = @constCast(segment_path),
        });
        try writer_state.end();
        try self.entries.append(self.alloc, .{
            .series_id = sid,
            .hour_bucket = hour,
            .start_ts = start_ts,
            .end_ts = end_ts,
            .count = count,
            .path = try self.alloc.dupe(u8, segment_path),
        });
    }

    pub fn addBatch(self: *Manifest, data_dir: std.fs.Dir, additions: []const AddInput) !void {
        if (additions.len == 0) return;

        const OpenFlags = std.fs.File.OpenFlags;
        const open_opts: OpenFlags = if (@hasField(OpenFlags, "write"))
            OpenFlags{ .write = true, .read = true }
        else
            OpenFlags{ .mode = .read_write };
        var file = data_dir.openFile(manifest_path, open_opts) catch |err| switch (err) {
            error.FileNotFound => try data_dir.createFile(manifest_path, .{ .read = true }),
            else => return err,
        };
        defer file.close();
        const end_pos = try file.getEndPos();

        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        try writer_state.seekTo(end_pos);
        var writer = anyWriter(&writer_state.interface);
        try self.entries.ensureUnusedCapacity(self.alloc, additions.len);

        for (additions) |addition| {
            try writeEntry(&writer, .{
                .series_id = addition.series_id,
                .hour_bucket = addition.hour_bucket,
                .start_ts = addition.start_ts,
                .end_ts = addition.end_ts,
                .count = addition.count,
                .path = @constCast(addition.path),
            });
        }
        try writer_state.end();

        for (additions) |addition| {
            try self.entries.append(self.alloc, .{
                .series_id = addition.series_id,
                .hour_bucket = addition.hour_bucket,
                .start_ts = addition.start_ts,
                .end_ts = addition.end_ts,
                .count = addition.count,
                .path = try self.alloc.dupe(u8, addition.path),
            });
        }
    }

    pub fn rewriteCheckpoint(self: *Manifest, data_dir: std.fs.Dir) !void {
        const temp_name = "MANIFEST.tmp";
        var file = try data_dir.createFile(temp_name, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer data_dir.deleteFile(temp_name) catch {};

        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        var writer = anyWriter(&writer_state.interface);
        for (self.entries.items) |entry| {
            try writeEntry(&writer, entry);
        }
        try writer_state.end();
        try file.sync();
        try data_dir.rename(temp_name, manifest_path);
        try syncDirectory(data_dir);
    }
};

fn ensureRepairIntent(data_dir: std.fs.Dir) !void {
    const OpenFlags = std.fs.File.OpenFlags;
    const open_opts: OpenFlags = if (@hasField(OpenFlags, "write"))
        OpenFlags{ .write = true, .read = true }
    else
        OpenFlags{ .mode = .read_write };
    var file = data_dir.createFile(repair_intent_path, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => try data_dir.openFile(repair_intent_path, open_opts),
        else => return err,
    };
    defer file.close();
    if ((try file.stat()).size != 0) return error.InvalidManifestRepairIntent;
    try file.sync();
    try syncDirectory(data_dir);
}

fn syncDirectory(data_dir: std.fs.Dir) !void {
    try std.posix.fsync(data_dir.fd);
}

fn writeEntry(writer: *std.Io.AnyWriter, entry: Entry) !void {
    try writer.print(
        "{{\"series_id\":{d},\"hour_bucket\":{d},\"start_ts\":{d},\"end_ts\":{d},\"count\":{d},\"path\":\"{s}\"}}\n",
        .{ entry.series_id, entry.hour_bucket, entry.start_ts, entry.end_ts, entry.count, entry.path },
    );
}

fn anyWriter(writer: *std.Io.Writer) std.Io.AnyWriter {
    return .{
        .context = writer,
        .writeFn = struct {
            fn call(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
                const w: *std.Io.Writer = @ptrCast(@alignCast(@constCast(ctx)));
                return w.write(bytes);
            }
        }.call,
    };
}

fn parseEntry(alloc: std.mem.Allocator, line: []const u8) !Entry {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidCharacter,
    };
    const path = switch (obj.get("path") orelse return error.InvalidCharacter) {
        .string => |string| string,
        else => return error.InvalidCharacter,
    };
    return .{
        .series_id = try jsonSeriesId(obj.get("series_id") orelse return error.InvalidCharacter),
        .hour_bucket = try jsonI64(obj.get("hour_bucket") orelse return error.InvalidCharacter),
        .start_ts = try jsonI64(obj.get("start_ts") orelse return error.InvalidCharacter),
        .end_ts = try jsonI64(obj.get("end_ts") orelse return error.InvalidCharacter),
        .count = try jsonU32(obj.get("count") orelse return error.InvalidCharacter),
        .path = try alloc.dupe(u8, path),
    };
}

fn jsonI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        .number_string => |digits| try std.fmt.parseInt(i64, digits, 10),
        else => error.InvalidCharacter,
    };
}

fn jsonU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer) orelse error.InvalidCharacter,
        .number_string => |digits| try std.fmt.parseInt(u32, digits, 10),
        else => error.InvalidCharacter,
    };
}

fn jsonSeriesId(value: std.json.Value) !types.SeriesId {
    return switch (value) {
        .integer => |integer| std.math.cast(types.SeriesId, integer) orelse error.InvalidCharacter,
        .number_string => |digits| try std.fmt.parseInt(types.SeriesId, digits, 10),
        else => error.InvalidCharacter,
    };
}

test "single and batched additions append without overwriting prior entries" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try Manifest.loadOrInit(talloc, tmp.dir);
    defer manifest.deinit();

    try manifest.add(tmp.dir, 1, 10, 100, 101, 2, "segments/first.seg");
    try manifest.addBatch(tmp.dir, &.{
        .{
            .series_id = 2,
            .hour_bucket = 20,
            .start_ts = 200,
            .end_ts = 202,
            .count = 3,
            .path = "segments/second.seg",
        },
        .{
            .series_id = 3,
            .hour_bucket = 30,
            .start_ts = 300,
            .end_ts = 303,
            .count = 4,
            .path = "segments/third.seg",
        },
    });
    try std.testing.expectEqual(@as(usize, 3), manifest.entries.items.len);

    var reloaded = try Manifest.loadOrInit(talloc, tmp.dir);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 3), reloaded.entries.items.len);
    try std.testing.expectEqual(@as(types.SeriesId, 1), reloaded.entries.items[0].series_id);
    try std.testing.expectEqualStrings("segments/first.seg", reloaded.entries.items[0].path);
    try std.testing.expectEqual(@as(types.SeriesId, 2), reloaded.entries.items[1].series_id);
    try std.testing.expectEqualStrings("segments/second.seg", reloaded.entries.items[1].path);
    try std.testing.expectEqual(@as(types.SeriesId, 3), reloaded.entries.items[2].series_id);
    try std.testing.expectEqualStrings("segments/third.seg", reloaded.entries.items[2].path);
}

test "load repairs an unterminated tail before later appends" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try Manifest.loadOrInit(talloc, tmp.dir);
    try manifest.add(tmp.dir, 1, 10, 100, 101, 2, "segments/first.seg");
    manifest.deinit();

    var file = try tmp.dir.openFile(manifest_path, .{ .mode = .read_write });
    const end_pos = try file.getEndPos();
    try file.seekTo(end_pos);
    try file.writeAll("{\"series_id\"");
    file.close();

    var repaired = try Manifest.loadOrInit(talloc, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), repaired.entries.items.len);
    try repaired.add(tmp.dir, 2, 20, 200, 202, 3, "segments/second.seg");
    repaired.deinit();

    var reloaded = try Manifest.loadOrInit(talloc, tmp.dir);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), reloaded.entries.items.len);
    try std.testing.expectEqualStrings("segments/first.seg", reloaded.entries.items[0].path);
    try std.testing.expectEqualStrings("segments/second.seg", reloaded.entries.items[1].path);

    const body = try tmp.dir.readFileAlloc(talloc, manifest_path, 4096);
    defer talloc.free(body);
    try std.testing.expect(std.mem.endsWith(u8, body, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"series_id\"") != null);
}

test "load rejects malformed newline terminated records" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = manifest_path,
        .data = "{\"series_id\"\n",
    });
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        Manifest.loadOrInit(talloc, tmp.dir),
    );
}
