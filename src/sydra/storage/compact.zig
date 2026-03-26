const std = @import("std");
const manifest_mod = @import("manifest.zig");
const segment = @import("segment.zig");
const types = @import("../types.zig");

// Size-tiered compaction (stub): merge multiple segments within the same (series_id,hour)
// Reorders by time and de-duplicates by ts (last wins), then rewrites a single segment.
pub fn compactAll(alloc: std.mem.Allocator, data_dir: std.fs.Dir, manifest: *manifest_mod.Manifest) !void {
    _ = try compactAllWithResult(alloc, data_dir, manifest);
}

pub fn compactAllWithResult(alloc: std.mem.Allocator, data_dir: std.fs.Dir, manifest: *manifest_mod.Manifest) !bool {
    var changed_any = false;
    while (try findNextCompactibleGroup(alloc, manifest)) |group| {
        defer alloc.free(group.indices);
        try compactGroup(alloc, data_dir, manifest, group.series_id, group.hour_bucket, group.indices);
        changed_any = true;
    }

    if (changed_any) {
        try manifest.rewriteCheckpoint(data_dir);
    }
    return changed_any;
}

const Group = struct {
    series_id: types.SeriesId,
    hour_bucket: i64,
    indices: []usize,
};

fn findNextCompactibleGroup(alloc: std.mem.Allocator, manifest: *const manifest_mod.Manifest) !?Group {
    for (manifest.entries.items, 0..) |entry, idx| {
        var indices = std.array_list.Managed(usize).init(alloc);
        errdefer indices.deinit();
        try indices.append(idx);

        var j = idx + 1;
        while (j < manifest.entries.items.len) : (j += 1) {
            const other = manifest.entries.items[j];
            if (other.series_id == entry.series_id and other.hour_bucket == entry.hour_bucket) {
                try indices.append(j);
            }
        }

        if (indices.items.len > 1) {
            return .{
                .series_id = entry.series_id,
                .hour_bucket = entry.hour_bucket,
                .indices = try indices.toOwnedSlice(),
            };
        }
        indices.deinit();
    }
    return null;
}

fn compactGroup(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    manifest: *manifest_mod.Manifest,
    sid: types.SeriesId,
    hour: i64,
    indices: []const usize,
) !void {
    var all = std.array_list.Managed(types.Point).init(alloc);
    defer all.deinit();

    for (indices) |manifest_index| {
        const entry = manifest.entries.items[manifest_index];
        const points = try segment.readAll(alloc, data_dir, entry.path);
        defer alloc.free(points);
        try all.appendSlice(points);
    }

    std.sort.block(types.Point, all.items, {}, struct {
        fn lessThan(_: void, lhs: types.Point, rhs: types.Point) bool {
            return lhs.ts < rhs.ts;
        }
    }.lessThan);

    var dedup = try alloc.alloc(types.Point, all.items.len);
    defer alloc.free(dedup);

    var dedup_len: usize = 0;
    for (all.items) |point| {
        if (dedup_len == 0 or dedup[dedup_len - 1].ts != point.ts) {
            dedup[dedup_len] = point;
            dedup_len += 1;
        } else {
            dedup[dedup_len - 1] = point;
        }
    }

    const compacted = dedup[0..dedup_len];
    const new_path = try segment.writeSegment(alloc, data_dir, sid, hour, compacted);
    defer alloc.free(new_path);

    var keep = std.ArrayListUnmanaged(manifest_mod.Entry){};
    errdefer keep.deinit(alloc);

    for (manifest.entries.items, 0..) |entry, entry_idx| {
        if (containsIndex(indices, entry_idx)) {
            data_dir.deleteFile(entry.path) catch {};
            alloc.free(entry.path);
            continue;
        }
        try keep.append(alloc, entry);
    }

    try keep.append(alloc, .{
        .series_id = sid,
        .hour_bucket = hour,
        .start_ts = compacted[0].ts,
        .end_ts = compacted[compacted.len - 1].ts,
        .count = @intCast(compacted.len),
        .path = try alloc.dupe(u8, new_path),
    });

    manifest.entries.deinit(manifest.alloc);
    manifest.entries = keep;
}

fn containsIndex(indices: []const usize, target: usize) bool {
    for (indices) |idx| {
        if (idx == target) return true;
    }
    return false;
}
