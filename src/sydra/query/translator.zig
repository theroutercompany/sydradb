const std = @import("std");
const compat = @import("../compat.zig");

pub const Result = union(enum) {
    success: Success,
    failure: Failure,
};

pub const Success = struct {
    sydraql: []const u8,
};

pub const Failure = struct {
    sqlstate: []const u8,
    message: []const u8,
};

pub fn translate(alloc: std.mem.Allocator, sql: []const u8) !Result {
    const trimmed = std.mem.trim(u8, sql, " \t\r\n");
    const start = std.time.nanoTimestamp();
    if (std.ascii.eqlIgnoreCase(trimmed, "SELECT 1")) {
        const out = try alloc.dupe(u8, "select const 1");
        const duration = std.time.nanoTimestamp() - start;
        compat.clog.global().record(trimmed, out, false, false, duration);
        return Result{ .success = .{ .sydraql = out } };
    }
    const payload = compat.sqlstate.buildPayload(.feature_not_supported, null, null, null);
    const duration = std.time.nanoTimestamp() - start;
    compat.clog.global().record(trimmed, "", false, true, duration);
    return Result{ .failure = .{ .sqlstate = payload.sqlstate, .message = payload.message } };
}

test "translator fixtures" {
    const alloc = std.testing.allocator;
    const rec = compat.clog.global();
    const prev_enabled = rec.enabled;
    rec.enabled = false;
    defer rec.enabled = prev_enabled;
    compat.stats.global().reset();
    var cases = try compat.fixtures.translator.loadCases(alloc, "tests/translator/cases.jsonl");
    defer cases.deinit();

    for (cases.cases) |case| {
        const result = try translate(alloc, case.sql);
        defer switch (result) {
            .success => |s| alloc.free(s.sydraql),
            .failure => |_| {},
        };
        switch (case.expect) {
            .success => |expected| {
                try std.testing.expect(result == .success);
                try std.testing.expectEqualStrings(expected.sydraql, result.success.sydraql);
            },
            .failure => |expected| {
                try std.testing.expect(result == .failure);
                try std.testing.expectEqualStrings(expected.sqlstate, result.failure.sqlstate);
                if (expected.message.len != 0) {
                    try std.testing.expectEqualStrings(expected.message, result.failure.message);
                }
            },
        }
    }
}
