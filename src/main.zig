const std = @import("std");
const server = @import("sydra/server.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    std.debug.print("sydraDB pre-alpha\n", .{});
    try server.run(alloc);
}
