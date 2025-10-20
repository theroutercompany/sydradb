const std = @import("std");
const server = @import("sydra/server.zig");
const alloc_mod = @import("sydra/alloc.zig");
pub fn main() !void {
    var alloc_handle = alloc_mod.AllocatorHandle.init();
    defer alloc_handle.deinit();
    const alloc = alloc_handle.allocator();
    std.debug.print("sydraDB pre-alpha\n", .{});
    try server.run(alloc);
}
