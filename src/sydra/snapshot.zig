const std = @import("std");
const cfg = @import("config.zig");
const cas = @import("storage/cas.zig");

pub fn snapshot(alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, fsync: cfg.FsyncPolicy) !void {
    _ = try cas.createBundle(alloc, src_path, dst_path, fsync, null);
}

pub fn restore(alloc: std.mem.Allocator, dst_path: []const u8, src_path: []const u8, fsync: cfg.FsyncPolicy) !void {
    _ = try cas.applyBundle(alloc, src_path, dst_path, fsync);
}
