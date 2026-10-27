const std = @import("std");
const builtin = @import("builtin");

/// Stable repository-relative lock file used to coordinate processes that can
/// mutate repository state.
pub const lock_file_name = ".sydradb-maintenance.lock";

/// An owned advisory repository lock.
///
/// The caller must keep this value alive for the full mutation window and call
/// `deinit` exactly once. Closing the file also releases the lock if a process
/// exits without running normal cleanup.
pub const RepositoryLock = struct {
    file: std.fs.File,
    held: bool = true,

    /// Creates the repository directory when needed and tries to acquire its
    /// exclusive writer lease without waiting. Every process that owns an
    /// Engine or otherwise mutates repository state must hold this lease for
    /// its complete mutation lifetime.
    pub fn acquirePath(path: []const u8) !RepositoryLock {
        return try acquirePathWithMode(path, .exclusive);
    }

    /// Tries to acquire a shared inspection lease without waiting.
    ///
    /// This is only suitable for paths that never initialize Engine and never
    /// create, repair, or rewrite repository state.
    pub fn acquireInspectionPath(path: []const u8) !RepositoryLock {
        var dir = try std.fs.cwd().openDir(path, .{});
        defer dir.close();
        return try acquireDirWithMode(dir, .shared);
    }

    fn acquirePathWithMode(path: []const u8, mode: std.fs.File.Lock) !RepositoryLock {
        try std.fs.cwd().makePath(path);
        var dir = try std.fs.cwd().openDir(path, .{});
        defer dir.close();
        return try acquireDirWithMode(dir, mode);
    }

    /// Tries to acquire an exclusive lock in an already-open repository
    /// directory. Contention is reported as `error.RepositoryLocked`.
    pub fn acquireDir(dir: std.fs.Dir) !RepositoryLock {
        return try acquireDirWithMode(dir, .exclusive);
    }

    /// Tries to acquire a shared inspection lease in an already-open
    /// repository directory.
    pub fn acquireInspectionDir(dir: std.fs.Dir) !RepositoryLock {
        return try acquireDirWithMode(dir, .shared);
    }

    fn acquireDirWithMode(dir: std.fs.Dir, mode: std.fs.File.Lock) !RepositoryLock {
        const file = dir.createFile(lock_file_name, .{
            .read = true,
            .truncate = false,
            .lock = mode,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.RepositoryLocked,
            else => return err,
        };
        return .{ .file = file };
    }

    pub fn deinit(self: *RepositoryLock) void {
        if (!self.held) return;
        self.file.unlock();
        self.file.close();
        self.held = false;
    }
};

/// Two exclusive repository leases acquired in canonical path order.
///
/// Source/destination operations use this type so reciprocal operations cannot
/// each retain a different first lease. Canonicalization also rejects relative
/// or symlink aliases that resolve to the same repository.
pub const RepositoryLockPair = struct {
    first: RepositoryLock,
    second: RepositoryLock,

    pub fn acquirePaths(
        alloc: std.mem.Allocator,
        first_path: []const u8,
        second_path: []const u8,
    ) !RepositoryLockPair {
        const first_canonical = try canonicalRepositoryPath(alloc, first_path);
        defer alloc.free(first_canonical);
        const second_canonical = try canonicalRepositoryPath(alloc, second_path);
        defer alloc.free(second_canonical);

        if (std.mem.eql(u8, first_canonical, second_canonical)) {
            return error.SameRepository;
        }

        const ordered = switch (std.mem.order(u8, first_canonical, second_canonical)) {
            .lt => .{ first_canonical, second_canonical },
            .eq => unreachable,
            .gt => .{ second_canonical, first_canonical },
        };

        var first = try RepositoryLock.acquirePath(ordered[0]);
        errdefer first.deinit();
        const second = try RepositoryLock.acquirePath(ordered[1]);
        return .{ .first = first, .second = second };
    }

    pub fn deinit(self: *RepositoryLockPair) void {
        self.second.deinit();
        self.first.deinit();
    }
};

fn canonicalRepositoryPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    try std.fs.cwd().makePath(path);
    return try std.fs.cwd().realpathAlloc(alloc, path);
}

test "repository lock rejects contention and can be reacquired after release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try RepositoryLock.acquireDir(tmp.dir);
    try std.testing.expectError(error.RepositoryLocked, RepositoryLock.acquireDir(tmp.dir));

    first.deinit();

    var second = try RepositoryLock.acquireDir(tmp.dir);
    second.deinit();
}

test "repository locks for different directories are independent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("one");
    try tmp.dir.makePath("two");

    var one_dir = try tmp.dir.openDir("one", .{});
    defer one_dir.close();
    var two_dir = try tmp.dir.openDir("two", .{});
    defer two_dir.close();

    var first = try RepositoryLock.acquireDir(one_dir);
    defer first.deinit();
    var second = try RepositoryLock.acquireDir(two_dir);
    defer second.deinit();
}

test "inspection leases coexist and exclude repository writers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try RepositoryLock.acquireInspectionDir(tmp.dir);
    defer first.deinit();
    var second = try RepositoryLock.acquireInspectionDir(tmp.dir);

    try std.testing.expectError(error.RepositoryLocked, RepositoryLock.acquireDir(tmp.dir));
    second.deinit();
    try std.testing.expectError(error.RepositoryLocked, RepositoryLock.acquireDir(tmp.dir));
    first.deinit();

    var writer = try RepositoryLock.acquireDir(tmp.dir);
    writer.deinit();
}

test "repository lock contention and release are visible across processes" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var parent_lock = try RepositoryLock.acquireDir(tmp.dir);

    const contending_pid = try std.posix.fork();
    if (contending_pid == 0) {
        var child_lock = RepositoryLock.acquireDir(tmp.dir) catch |err| {
            std.posix.exit(if (err == error.RepositoryLocked) 0 else 2);
        };
        child_lock.deinit();
        std.posix.exit(1);
    }
    const contending_result = std.posix.waitpid(contending_pid, 0);
    try std.testing.expect(std.posix.W.IFEXITED(contending_result.status));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(contending_result.status));

    parent_lock.deinit();

    const acquiring_pid = try std.posix.fork();
    if (acquiring_pid == 0) {
        var child_lock = RepositoryLock.acquireDir(tmp.dir) catch std.posix.exit(2);
        child_lock.deinit();
        std.posix.exit(0);
    }
    const acquiring_result = std.posix.waitpid(acquiring_pid, 0);
    try std.testing.expect(std.posix.W.IFEXITED(acquiring_result.status));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(acquiring_result.status));
}

test "repository lock pair rejects aliases of the same repository" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(relative);
    const absolute = try std.fs.cwd().realpathAlloc(alloc, relative);
    defer alloc.free(absolute);

    try std.testing.expectError(
        error.SameRepository,
        RepositoryLockPair.acquirePaths(alloc, relative, absolute),
    );
}

test "repository lock pair canonical order prevents split ownership" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/a", .{tmp.sub_path});
    defer alloc.free(first_path);
    const second_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/b", .{tmp.sub_path});
    defer alloc.free(second_path);

    var forward = try RepositoryLockPair.acquirePaths(alloc, first_path, second_path);
    try std.testing.expectError(
        error.RepositoryLocked,
        RepositoryLockPair.acquirePaths(alloc, second_path, first_path),
    );
    forward.deinit();

    var reverse = try RepositoryLockPair.acquirePaths(alloc, second_path, first_path);
    reverse.deinit();
}
