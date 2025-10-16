const std = @import("std");
const stats = @import("stats.zig");

pub const Recorder = struct {
    enabled: bool = true,
    sample_every: u32 = 1,
    counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn shouldRecord(self: *Recorder) bool {
        if (!self.enabled) return false;
        const prev = self.counter.fetchAdd(1, .seq_cst);
        return (prev % @as(u64, self.sample_every)) == 0;
    }

    pub fn record(self: *Recorder, sql: []const u8, translated: []const u8, used_cache: bool, fell_back: bool, duration_ns: u64) void {
        if (fell_back) stats.global().noteFallback() else stats.global().noteTranslation();
        if (used_cache) stats.global().noteCacheHit();

        if (!self.shouldRecord()) return;
        const stderr = std.io.getStdErr().writer();
        var jw = std.json.writeStream(stderr, .{});
        defer jw.deinit();
        jw.beginObject() catch return;
        jw.objectField("ts") catch return;
        jw.write(std.time.milliTimestamp()) catch return;
        jw.objectField("event") catch return;
        jw.write("compat.translate") catch return;
        jw.objectField("sql") catch return;
        jw.write(sql) catch return;
        jw.objectField("sydraql") catch return;
        jw.write(translated) catch return;
        jw.objectField("cache") catch return;
        jw.write(used_cache) catch return;
        jw.objectField("fallback") catch return;
        jw.write(fell_back) catch return;
        jw.objectField("duration_ns") catch return;
        jw.write(duration_ns) catch return;
        jw.endObject() catch return;
        stderr.writeAll("\n") catch {};

        // stats already recorded above even when sampling skips emission
    }
};

var default_recorder: Recorder = .{};

pub fn global() *Recorder {
    return &default_recorder;
}

test "recorder sampling" {
    var recorder = Recorder{ .sample_every = 2 };
    try std.testing.expect(recorder.shouldRecord());
    try std.testing.expect(!recorder.shouldRecord());
    try std.testing.expect(recorder.shouldRecord());
}
