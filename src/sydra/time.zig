const std = @import("std");

/// SydraDB's supported runtime targets expose monotonic timers. Treat
/// TimerUnsupported as an unsupported platform precondition instead of falling
/// back to realtime clocks for elapsed durations.
pub fn startTimer() std.time.Timer {
    return std.time.Timer.start() catch unreachable;
}

pub fn timeoutNanos(timeout_ms: u64) u64 {
    return std.math.mul(u64, timeout_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
}

pub const IntervalDeadline = struct {
    timer: std.time.Timer,
    interval_ns: u64,
    deadline_ns: u64,

    pub fn start(interval_ms: u64) IntervalDeadline {
        const interval_ns = timeoutNanos(interval_ms);
        return .{
            .timer = startTimer(),
            .interval_ns = interval_ns,
            .deadline_ns = interval_ns,
        };
    }

    pub fn due(self: *IntervalDeadline) bool {
        return self.timer.read() >= self.deadline_ns;
    }

    pub fn scheduleFromNow(self: *IntervalDeadline) void {
        const now_ns = self.timer.read();
        self.deadline_ns = std.math.add(u64, now_ns, self.interval_ns) catch std.math.maxInt(u64);
    }
};

test "interval deadline treats zero interval as immediately due" {
    var deadline = IntervalDeadline.start(0);
    try std.testing.expect(deadline.due());
    deadline.scheduleFromNow();
    try std.testing.expect(deadline.due());
}

test "interval deadline does not report a long interval as immediately due" {
    var deadline = IntervalDeadline.start(std.math.maxInt(u32));
    try std.testing.expect(!deadline.due());
    deadline.scheduleFromNow();
    try std.testing.expect(!deadline.due());
}
