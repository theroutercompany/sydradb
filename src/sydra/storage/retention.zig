const std = @import("std");
const manifest_mod = @import("manifest.zig");

pub fn apply(data_dir: std.fs.Dir, manifest: *manifest_mod.Manifest, ttl_days: u32) !void {
    if (ttl_days == 0) return; // keep forever
    const now_secs: i64 = @intCast(std.time.timestamp());
    const ttl_secs: i64 = @as(i64, @intCast(ttl_days)) * 24 * 3600;
    var keep = std.ArrayListUnmanaged(manifest_mod.Entry){};
    defer keep.deinit(manifest.alloc);
    for (manifest.entries.items) |e| {
        if ((now_secs - e.end_ts) > ttl_secs) {
            // delete segment file best-effort
            data_dir.deleteFile(e.path) catch {};
            continue;
        }
        try keep.append(manifest.alloc, e);
    }
    manifest.entries.deinit(manifest.alloc);
    manifest.entries = keep;
}

test "retention removes expired segments" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("segments");
    try tmp.dir.writeFile("segments/old.seg", "old");
    try tmp.dir.writeFile("segments/new.seg", "new");

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
