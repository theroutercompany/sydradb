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
