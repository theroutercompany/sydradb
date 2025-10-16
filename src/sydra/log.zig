const std = @import("std");

pub const Level = enum { debug, info, warn, err };

pub fn logJson(level: Level, msg: []const u8, fields: ?[]const std.json.Value, writer: *std.io.Writer) !void {
    var jw = std.json.Stringify{ .writer = writer };
    try jw.beginObject();
    try jw.objectField("ts");
    try jw.write(std.time.milliTimestamp());
    try jw.objectField("level");
    try jw.write(@tagName(level));
    try jw.objectField("msg");
    try jw.write(msg);
    if (fields) |arr| {
        for (arr) |v| {
            // Best-effort merge of flat objects passed in.
            if (v == .object) {
                var it = v.object.iterator();
                while (it.next()) |entry| {
                    try jw.objectField(entry.key_ptr.*);
                    try jw.write(entry.value_ptr.*);
                }
            }
        }
    }
    try jw.endObject();
    try writer.writeAll("\n");
}
