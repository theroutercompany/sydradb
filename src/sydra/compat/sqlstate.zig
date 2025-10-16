const std = @import("std");

/// Canonical subset of PostgreSQL SQLSTATE error identifiers we intend to emulate.
pub const Code = enum {
    successful_completion, // 00000
    unique_violation, // 23505
    not_null_violation, // 23502
    foreign_key_violation, // 23503
    check_violation, // 23514
    serialization_failure, // 40001
    deadlock_detected, // 40P01
    syntax_error, // 42601
    undefined_table, // 42P01
    undefined_column, // 42703
    insufficient_privilege, // 42501
    duplicate_object, // 42710
    feature_not_supported, // 0A000
    invalid_parameter_value, // 22023
};

const Entry = struct {
    sqlstate: []const u8,
    severity: []const u8,
    default_message: []const u8,
};

const entries = [_]Entry{
    .{ .sqlstate = "00000", .severity = "NOTICE", .default_message = "successful completion" },
    .{ .sqlstate = "23505", .severity = "ERROR", .default_message = "duplicate key value violates unique constraint" },
    .{ .sqlstate = "23502", .severity = "ERROR", .default_message = "null value violates not-null constraint" },
    .{ .sqlstate = "23503", .severity = "ERROR", .default_message = "insert or update on table violates foreign key constraint" },
    .{ .sqlstate = "23514", .severity = "ERROR", .default_message = "check constraint violation" },
    .{ .sqlstate = "40001", .severity = "ERROR", .default_message = "could not serialize access due to concurrent update" },
    .{ .sqlstate = "40P01", .severity = "ERROR", .default_message = "deadlock detected" },
    .{ .sqlstate = "42601", .severity = "ERROR", .default_message = "syntax error" },
    .{ .sqlstate = "42P01", .severity = "ERROR", .default_message = "relation does not exist" },
    .{ .sqlstate = "42703", .severity = "ERROR", .default_message = "column does not exist" },
    .{ .sqlstate = "42501", .severity = "ERROR", .default_message = "permission denied" },
    .{ .sqlstate = "42710", .severity = "ERROR", .default_message = "duplicate object" },
    .{ .sqlstate = "0A000", .severity = "ERROR", .default_message = "feature not supported" },
    .{ .sqlstate = "22023", .severity = "ERROR", .default_message = "invalid parameter value" },
};

pub fn lookup(code: Code) Entry {
    return entries[@intFromEnum(code)];
}

pub const ErrorPayload = struct {
    sqlstate: []const u8,
    severity: []const u8,
    message: []const u8,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
};

pub fn buildPayload(code: Code, message: ?[]const u8, detail: ?[]const u8, hint: ?[]const u8) ErrorPayload {
    const entry = lookup(code);
    return .{
        .sqlstate = entry.sqlstate,
        .severity = entry.severity,
        .message = message orelse entry.default_message,
        .detail = detail,
        .hint = hint,
    };
}

pub fn writeHumanReadable(payload: ErrorPayload, writer: anytype) !void {
    try writer.print("[{s}] {s}: {s}", .{ payload.sqlstate, payload.severity, payload.message });
    if (payload.detail) |d| try writer.print(" detail={s}", .{d});
    if (payload.hint) |h| try writer.print(" hint={s}", .{h});
}

pub fn fromSqlstate(sqlstate: []const u8) ?Code {
    for (entries, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.sqlstate, sqlstate)) return @enumFromInt(idx);
    }
    return null;
}

test "lookup and payload formatting" {
    const entry = lookup(.unique_violation);
    try std.testing.expectEqualStrings("23505", entry.sqlstate);
    const payload = buildPayload(.unique_violation, null, "duplicate key value violates unique constraint \"users_pkey\"", "Check the ON CONFLICT clause");
    try std.testing.expectEqualStrings("23505", payload.sqlstate);
    try std.testing.expectEqualStrings("duplicate key value violates unique constraint", payload.message);
    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try writeHumanReadable(payload, buf.writer());
    try std.testing.expectStringStartsWith(buf.items, "[23505] ERROR: duplicate key value violates unique constraint");
    const roundtrip = fromSqlstate("23505");
    try std.testing.expect(roundtrip != null);
    try std.testing.expectEqual(Code.unique_violation, roundtrip.?);
}
