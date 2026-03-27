const std = @import("std");
const manifest_mod = @import("manifest.zig");

pub fn apply(data_dir: std.fs.Dir, manifest: *manifest_mod.Manifest, ttl_days: u32) !void {
    if (ttl_days == 0) return; // keep forever
    _ = try applyWithResult(data_dir, manifest, ttl_days);
}

pub fn applyWithResult(data_dir: std.fs.Dir, manifest: *manifest_mod.Manifest, ttl_days: u32) !bool {
    if (ttl_days == 0) return false; // keep forever
    const now_secs: i64 = @intCast(std.time.timestamp());
    const ttl_secs: i64 = @as(i64, @intCast(ttl_days)) * 24 * 3600;
    var keep = std.ArrayListUnmanaged(manifest_mod.Entry){};
    errdefer keep.deinit(manifest.alloc);
    var changed = false;
    for (manifest.entries.items) |e| {
        if ((now_secs - e.end_ts) > ttl_secs) {
            // delete segment file best-effort
            if (e.path.len != 0) {
                data_dir.deleteFile(e.path) catch {};
            }
            manifest.alloc.free(e.path);
            changed = true;
            continue;
        }
        try keep.append(manifest.alloc, e);
    }
    if (!changed) {
        keep.deinit(manifest.alloc);
        return false;
    }
    manifest.entries.deinit(manifest.alloc);
    manifest.entries = keep;
    try manifest.rewriteCheckpoint(data_dir);
    return true;
}

test "retention removes expired segments" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("segments");
    try tmp.dir.writeFile(.{ .sub_path = "segments/old.seg", .data = "old" });
    try tmp.dir.writeFile(.{ .sub_path = "segments/new.seg", .data = "new" });

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();

    const now: i64 = @intCast(std.time.timestamp());
    try manifest.entries.append(talloc, .{
        .series_id = 1,
        .hour_bucket = 0,
        .start_ts = 0,
        .end_ts = now - 3 * 24 * 3600,
        .count = 1,
        .path = try talloc.dupe(u8, "segments/old.seg"),
    });
    try manifest.entries.append(talloc, .{
        .series_id = 1,
        .hour_bucket = 0,
        .start_ts = now,
        .end_ts = now,
        .count = 1,
        .path = try talloc.dupe(u8, "segments/new.seg"),
    });

    try apply(tmp.dir, &manifest, 1);

    try std.testing.expectEqual(@as(usize, 1), manifest.entries.items.len);
    try std.testing.expectEqualStrings("segments/new.seg", manifest.entries.items[0].path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("segments/old.seg"));
}
