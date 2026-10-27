const std = @import("std");

pub const exit_code: u8 = 86;

pub const Point = enum(u8) {
    after_registration = 1,
    after_wal_append = 2,
    after_memtable_append = 3,
    after_segment_creation = 4,
    after_manifest_update = 5,
    after_cas_object_write = 6,
    after_ref_update = 7,

    pub fn parse(value: []const u8) !Point {
        inline for (std.meta.fields(Point)) |field| {
            if (std.mem.eql(u8, value, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return error.InvalidCrashPoint;
    }
};

var armed_point = std.atomic.Value(u8).init(0);

/// Arm one process-local, one-shot crash point. Production code never calls
/// this function; dedicated recovery tooling must opt in explicitly.
pub fn arm(point: Point) void {
    armed_point.store(@intFromEnum(point), .seq_cst);
}

pub fn disarm() void {
    armed_point.store(0, .seq_cst);
}

pub fn hit(point: Point) void {
    if (armed_point.cmpxchgStrong(
        @intFromEnum(point),
        0,
        .seq_cst,
        .seq_cst,
    ) != null) return;

    std.debug.print(
        "native-market crash injection reached {s}; exiting with code {d}\n",
        .{ @tagName(point), exit_code },
    );
    std.process.exit(exit_code);
}

test "crash injection point names are stable" {
    inline for (std.meta.fields(Point)) |field| {
        const parsed = try Point.parse(field.name);
        try std.testing.expectEqual(@as(u8, @intCast(field.value)), @intFromEnum(parsed));
    }
    try std.testing.expectError(error.InvalidCrashPoint, Point.parse("after_unknown"));
}
