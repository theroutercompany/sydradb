const std = @import("std");
const compat = @import("../compat.zig");

fn startsWithCaseInsensitive(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (prefix, 0..) |ch, idx| {
        if (std.ascii.toLower(text[idx]) != std.ascii.toLower(ch)) return false;
    }
    return true;
}

fn findCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    const end_idx = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end_idx) : (i += 1) {
        var match = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

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

    if (startsWithCaseInsensitive(trimmed, "SELECT ")) {
        if (findCaseInsensitive(trimmed, " FROM ")) |from_idx| {
            const cols_raw = std.mem.trim(u8, trimmed["SELECT ".len .. from_idx], " \t\r\n");
            const remainder = std.mem.trim(u8, trimmed[from_idx + " FROM ".len ..], " \t\r\n;");
            if (cols_raw.len != 0 and remainder.len != 0) {
                var table_part = remainder;
                var where_part: ?[]const u8 = null;
                if (findCaseInsensitive(remainder, " WHERE ")) |where_idx| {
                    table_part = std.mem.trim(u8, remainder[0..where_idx], " \t\r\n");
                    const cond_slice = std.mem.trim(u8, remainder[where_idx + " WHERE ".len ..], " \t\r\n;");
                    if (cond_slice.len != 0) where_part = cond_slice;
                }
                if (table_part.len != 0) {
                    var builder = std.ArrayList(u8).init(alloc);
                    defer builder.deinit();
                    try builder.appendSlice("from ");
                    try builder.appendSlice(table_part);
                    if (where_part) |cond| {
                        try builder.appendSlice(" where ");
                        try builder.appendSlice(cond);
                    }
                    try builder.appendSlice(" select ");
                    var col_iter = std.mem.splitScalar(u8, cols_raw, ',');
                    var first = true;
                    while (col_iter.next()) |raw| {
                        const trimmed_col = std.mem.trim(u8, raw, " \t\r\n");
                        if (trimmed_col.len == 0) continue;
                        if (!first) try builder.appendSlice(",");
                        first = false;
                        try builder.appendSlice(trimmed_col);
                    }
                    if (!first) {
                        const sydra_str = try builder.toOwnedSlice();
                        const duration = std.time.nanoTimestamp() - start;
                        compat.clog.global().record(trimmed, sydra_str, false, false, duration);
                        return Result{ .success = .{ .sydraql = sydra_str } };
                    }
                }
            }
        }
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
