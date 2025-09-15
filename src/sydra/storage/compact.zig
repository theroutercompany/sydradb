const std = @import("std");
const manifest_mod = @import("manifest.zig");
const segment = @import("segment.zig");
const types = @import("../types.zig");

// Size-tiered compaction (stub): merge multiple segments within the same (series_id,hour)
// Reorders by time and de-duplicates by ts (last wins), then rewrites a single segment.
pub fn compactAll(alloc: std.mem.Allocator, data_dir: std.fs.Dir, manifest: *manifest_mod.Manifest) !void {
    // Group entries by (series_id,hour)
    const Key = struct { s: u64, h: i64 };
    var groups = std.AutoHashMap(Key, std.ArrayList(usize)).init(alloc);
    defer groups.deinit();
    for (manifest.entries.items, 0..) |e, idx| {
        const key: Key = .{ .s = e.series_id, .h = e.hour_bucket };
        var gop = try groups.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = try std.ArrayList(usize).initCapacity(alloc, 0);
        try gop.value_ptr.append(alloc, idx);
    }
    var it = groups.iterator();
    while (it.next()) |entry| {
        const ids = entry.value_ptr.*.items;
        if (ids.len <= 1) continue;
        var all = try std.ArrayList(types.Point).initCapacity(alloc, 0);
        defer all.deinit();
        for (ids) |mi| {
            const me = manifest.entries.items[mi];
            const pts = try segment.readAll(alloc, data_dir, me.path);
            defer alloc.free(pts);
            try all.appendSlice(pts);
        }
        std.sort.block(types.Point, all.items, {}, struct {
            fn lessThan(_: void, a: types.Point, b: types.Point) bool { return a.ts < b.ts; }
        }.lessThan);
        // de-duplicate by ts (last wins)
        var dedup = try alloc.alloc(types.Point, all.items.len);
        defer alloc.free(dedup);
        var n: usize = 0;
        var i: usize = 0;
        while (i < all.items.len) : (i += 1) {
            const p = all.items[i];
            if (n == 0 or dedup[n - 1].ts != p.ts) {
                dedup[n] = p; n += 1;
            } else {
                dedup[n - 1] = p; // last wins
            }
        }
        const slice = dedup[0..n];
        const sid = entry.key_ptr.*.s;
        const hour = entry.key_ptr.*.h;
        const new_path = try segment.writeSegment(alloc, data_dir, sid, hour, slice);
        // Remove old segment files in this group
        for (ids) |mi| {
            const me = manifest.entries.items[mi];
            data_dir.deleteFile(me.path) catch {};
        }
        // Rebuild manifest without old entries
        var keep = std.ArrayListUnmanaged(manifest_mod.Entry){};
        defer keep.deinit(alloc);
        for (manifest.entries.items) |me| {
            if (me.series_id == sid and me.hour_bucket == hour) {
                // free removed entry path to avoid leak
                alloc.free(me.path);
                continue;
            }
            try keep.append(alloc, me);
        }
        manifest.entries.deinit(manifest.alloc);
        manifest.entries = keep;
        // Add new consolidated entry
        const cnt: u32 = @intCast(slice.len);
        try manifest.add(data_dir, sid, hour, slice[0].ts, slice[slice.len - 1].ts, cnt, new_path);
        alloc.free(new_path);
    }
}
