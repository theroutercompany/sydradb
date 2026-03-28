const std = @import("std");

pub const AtomicU64 = if (@sizeOf(usize) == 8) std.atomic.Value(u64) else struct {
    raw: u64,
    mutex: std.Thread.Mutex,

    pub fn init(val: u64) @This() {
        return .{ .raw = val, .mutex = .{} };
    }

    pub fn fetchAdd(self: *@This(), op: u64, _: std.builtin.AtomicOrder) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const old = self.raw;
        self.raw +%= op;
        return old;
    }

    pub fn load(self: *@This(), _: std.builtin.AtomicOrder) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.raw;
    }

    pub fn store(self: *@This(), val: u64, _: std.builtin.AtomicOrder) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.raw = val;
    }
};
