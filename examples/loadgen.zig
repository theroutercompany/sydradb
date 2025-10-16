const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var stdout_file = std.fs.File.stdout();
    var stdout_buf: [512]u8 = undefined;
    var stdout_state = stdout_file.writer(&stdout_buf);
    var stdout = stdout_state.interface();
    var ts: i64 = 1694300000;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const val = 20.0 + @floatFromInt(f64, @intCast(i % 100)) / 10.0;
        try stdout.print("{s}\n", .{try std.fmt.allocPrint(alloc, "{\"series\":\"weather.room1\",\"ts\":{d},\"value\":{d:.2}}", .{ ts, val })});
        ts += 10;
    }
}
