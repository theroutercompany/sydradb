const std = @import("std");
const AtomicU64 = @import("../atomic_util.zig").AtomicU64;

pub const Snapshot = struct {
    translations: u64,
    fallbacks: u64,
    cache_hits: u64,
};

pub const Stats = struct {
    translation_count: AtomicU64 = AtomicU64.init(0),
    fallback_count: AtomicU64 = AtomicU64.init(0),
    cache_hit_count: AtomicU64 = AtomicU64.init(0),

    pub fn noteTranslation(self: *Stats) void {
        _ = self.translation_count.fetchAdd(1, .seq_cst);
    }

    pub fn noteFallback(self: *Stats) void {
        _ = self.fallback_count.fetchAdd(1, .seq_cst);
    }

    pub fn noteCacheHit(self: *Stats) void {
        _ = self.cache_hit_count.fetchAdd(1, .seq_cst);
    }

    pub fn snapshot(self: *Stats) Snapshot {
        return .{
            .translations = self.translation_count.load(.seq_cst),
            .fallbacks = self.fallback_count.load(.seq_cst),
            .cache_hits = self.cache_hit_count.load(.seq_cst),
        };
    }

    pub fn reset(self: *Stats) void {
        self.translation_count.store(0, .seq_cst);
        self.fallback_count.store(0, .seq_cst);
        self.cache_hit_count.store(0, .seq_cst);
    }
};

var global_stats: Stats = .{};

pub fn global() *Stats {
    return &global_stats;
}

pub fn formatSnapshot(snapshot: Snapshot, writer: anytype) !void {
    try writer.print(
        "translations={d} fallbacks={d} cache_hits={d}",
        .{ snapshot.translations, snapshot.fallbacks, snapshot.cache_hits },
    );
}

test "stats increment and snapshot" {
    var stats = Stats{};
    stats.noteTranslation();
    stats.noteFallback();
    stats.noteFallback();
    stats.noteCacheHit();
    stats.noteCacheHit();
    stats.noteCacheHit();
    const snap = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.translations);
    try std.testing.expectEqual(@as(u64, 2), snap.fallbacks);
    try std.testing.expectEqual(@as(u64, 3), snap.cache_hits);
    stats.reset();
    const reset = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 0), reset.translations);
    try std.testing.expectEqual(@as(u64, 0), reset.fallbacks);
    try std.testing.expectEqual(@as(u64, 0), reset.cache_hits);
}
