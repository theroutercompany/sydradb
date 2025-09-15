const std = @import("std");

pub const SeriesId = u64;

pub const Point = struct {
    ts: i64,
    value: f64,
};

pub fn hash64(data: []const u8) SeriesId {
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(data);
    return hasher.final();
}

pub fn seriesIdFrom(series: []const u8, tags_json: []const u8) SeriesId {
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(series);
    hasher.update("|");
    hasher.update(tags_json);
    return hasher.final();
}
