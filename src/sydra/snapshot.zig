const std = @import("std");

pub fn snapshot(alloc: std.mem.Allocator, data_dir: std.fs.Dir, dst_path: []const u8) !void {
    // Simple manifested copy: copy MANIFEST, wal/, segments/, tags.json
    try std.fs.cwd().makePath(dst_path);
    var dst = try std.fs.cwd().openDir(dst_path, .{ .iterate = true });
    defer dst.close();
    try copyIfExists(data_dir, dst, "MANIFEST");
    try copyDirRecursive(alloc, data_dir, dst, "wal");
    try copyDirRecursive(alloc, data_dir, dst, "segments");
    try copyIfExists(data_dir, dst, "tags.json");
}

pub fn restore(alloc: std.mem.Allocator, data_dir: std.fs.Dir, src_path: []const u8) !void {
    var src = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src.close();
    try copyIfExists(src, data_dir, "MANIFEST");
    try copyDirRecursive(alloc, src, data_dir, "wal");
    try copyDirRecursive(alloc, src, data_dir, "segments");
    try copyIfExists(src, data_dir, "tags.json");
}

fn copyIfExists(from: std.fs.Dir, to: std.fs.Dir, name: []const u8) !void {
    var f = from.openFile(name, .{}) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer f.close();
    var g = try to.createFile(name, .{ .truncate = true, .read = true });
    defer g.close();
    var reader_buffer: [4096]u8 = undefined;
    var file_reader = f.reader(&reader_buffer);
    var writer_buffer: [4096]u8 = undefined;
    var file_writer = g.writer(&writer_buffer);
    _ = try file_reader.interface.streamRemaining(&file_writer.interface);
    try file_writer.interface.flush();
}

fn copyDirRecursive(alloc: std.mem.Allocator, from: std.fs.Dir, to: std.fs.Dir, name: []const u8) !void {
    var sub_from = from.openDir(name, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer sub_from.close();
    to.makePath(name) catch {};
    var sub_to = try to.openDir(name, .{ .iterate = true });
    defer sub_to.close();
    var it = sub_from.iterate();
    while (try it.next()) |ent| {
        if (ent.kind == .file) {
            var f = try sub_from.openFile(ent.name, .{});
            defer f.close();
            var g = try sub_to.createFile(ent.name, .{ .truncate = true, .read = true });
            defer g.close();
            var reader_buffer: [4096]u8 = undefined;
            var file_reader = f.reader(&reader_buffer);
            var writer_buffer: [4096]u8 = undefined;
            var file_writer = g.writer(&writer_buffer);
            _ = try file_reader.interface.streamRemaining(&file_writer.interface);
            try file_writer.interface.flush();
        } else if (ent.kind == .directory) {
            try copyDirRecursive(alloc, sub_from, sub_to, ent.name);
        }
    }
}
