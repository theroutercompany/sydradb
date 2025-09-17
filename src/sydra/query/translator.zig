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

fn findLastCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var idx = haystack.len - needle.len + 1;
    while (idx > 0) {
        idx -= 1;
        var match = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[idx + j]) != std.ascii.toLower(ch)) {
                match = false;
                break;
            }
        }
        if (match) return idx;
    }
    return null;
}

fn findMatchingParen(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '(') return null;
    var depth: i32 = 0;
    var idx = open_index;
    while (idx < text.len) : (idx += 1) {
        const ch = text[idx];
        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return idx;
        }
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
            const cols_raw = std.mem.trim(u8, trimmed["SELECT ".len..from_idx], " \t\r\n");
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

    if (startsWithCaseInsensitive(trimmed, "INSERT INTO ")) {
        const inserted = std.mem.trim(u8, trimmed["INSERT INTO ".len..], " \t\r\n");
        if (inserted.len != 0) {
            var idx: usize = 0;
            while (idx < inserted.len and inserted[idx] == ' ') : (idx += 1) {}
            const table_start = idx;
            while (idx < inserted.len) : (idx += 1) {
                const ch = inserted[idx];
                if (ch == ' ' or ch == '(') break;
            }
            if (idx > table_start) {
                const table_name = std.mem.trimRight(u8, inserted[table_start..idx], " \t\r\n");
                var cursor = idx;
                while (cursor < inserted.len and std.ascii.isWhitespace(inserted[cursor])) : (cursor += 1) {}

                var columns_slice: ?[]const u8 = null;
                if (cursor < inserted.len and inserted[cursor] == '(') {
                    if (findMatchingParen(inserted, cursor)) |close_idx| {
                        const inner = inserted[cursor + 1 .. close_idx];
                        columns_slice = std.mem.trim(u8, inner, " \t\r\n");
                        cursor = close_idx + 1;
                        while (cursor < inserted.len and std.ascii.isWhitespace(inserted[cursor])) : (cursor += 1) {}
                    } else {
                        cursor = inserted.len;
                    }
                }

                const values_kw = "VALUES";
                if (cursor < inserted.len and startsWithCaseInsensitive(inserted[cursor..], values_kw)) {
                    cursor += values_kw.len;
                    while (cursor < inserted.len and std.ascii.isWhitespace(inserted[cursor])) : (cursor += 1) {}
                    if (cursor < inserted.len and inserted[cursor] == '(') {
                        if (findMatchingParen(inserted, cursor)) |values_close| {
                            const values_inner = std.mem.trim(u8, inserted[cursor + 1 .. values_close], " \t\r\n");
                            var remainder = inserted[values_close + 1 ..];
                            remainder = std.mem.trim(u8, remainder, " \t\r\n;");
                            if (remainder.len == 0 or startsWithCaseInsensitive(remainder, "RETURNING")) {
                                const returning_clause = if (remainder.len == 0)
                                    null
                                else blk: {
                                    const clause = std.mem.trim(u8, remainder["RETURNING".len..], " \t\r\n");
                                    if (clause.len == 0) break :blk null;
                                    break :blk clause;
                                };
                                if (remainder.len != 0 and returning_clause == null) {
                                    // Malformed RETURNING clause; allow fallback below.
                                } else {
                                    var builder = std.ArrayList(u8).init(alloc);
                                    defer builder.deinit();
                                    try builder.appendSlice("insert into ");
                                    try builder.appendSlice(table_name);
                                    if (columns_slice) |cols| {
                                        try builder.appendSlice(" (");
                                        try builder.appendSlice(cols);
                                        try builder.appendSlice(")");
                                    }
                                    try builder.appendSlice(" values (");
                                    try builder.appendSlice(values_inner);
                                    try builder.appendSlice(")");
                                    if (returning_clause) |clause| {
                                        try builder.appendSlice(" returning ");
                                        try builder.appendSlice(clause);
                                    }
                                    const sydra_str = try builder.toOwnedSlice();
                                    const duration = std.time.nanoTimestamp() - start;
                                    compat.clog.global().record(trimmed, sydra_str, false, false, duration);
                                    return Result{ .success = .{ .sydraql = sydra_str } };
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (startsWithCaseInsensitive(trimmed, "UPDATE ")) {
        const after_update = std.mem.trim(u8, trimmed["UPDATE ".len..], " \t\r\n");
        if (after_update.len != 0) {
            if (findCaseInsensitive(after_update, " SET ")) |set_idx| {
                const table_raw = std.mem.trim(u8, after_update[0..set_idx], " \t\r\n");
                if (table_raw.len != 0) {
                    var remainder = std.mem.trim(u8, after_update[set_idx + " SET ".len ..], " \t\r\n");
                    if (remainder.len != 0) {
                        var returning_clause: ?[]const u8 = null;
                        if (findLastCaseInsensitive(remainder, "RETURNING")) |ret_idx| {
                            const before_ok = ret_idx == 0 or std.ascii.isWhitespace(remainder[ret_idx - 1]);
                            const after_idx = ret_idx + "RETURNING".len;
                            const after_ok = after_idx >= remainder.len or std.ascii.isWhitespace(remainder[after_idx]);
                            if (before_ok and after_idx <= remainder.len and after_ok) {
                                const clause_raw = std.mem.trim(u8, remainder[after_idx..], " \t\r\n;");
                                if (clause_raw.len != 0) {
                                    returning_clause = clause_raw;
                                    remainder = std.mem.trimRight(u8, remainder[0..ret_idx], " \t\r\n;");
                                }
                            }
                        }
                        remainder = std.mem.trimRight(u8, remainder, " \t\r\n;");
                        if (remainder.len != 0) {
                            var set_clause = remainder;
                            var where_clause: ?[]const u8 = null;
                            if (findCaseInsensitive(remainder, " WHERE ")) |where_idx| {
                                const before_where = std.mem.trimRight(u8, remainder[0..where_idx], " \t\r\n;");
                                const after_where = std.mem.trim(u8, remainder[where_idx + " WHERE ".len ..], " \t\r\n;");
                                if (after_where.len != 0 and before_where.len != 0) {
                                    set_clause = before_where;
                                    where_clause = after_where;
                                } else {
                                    where_clause = null;
                                    set_clause = remainder;
                                }
                            }
                            set_clause = std.mem.trimRight(u8, set_clause, " \t\r\n;");
                            if (set_clause.len != 0) {
                                var builder = std.ArrayList(u8).init(alloc);
                                defer builder.deinit();
                                try builder.appendSlice("update ");
                                try builder.appendSlice(table_raw);
                                try builder.appendSlice(" set ");
                                try builder.appendSlice(set_clause);
                                if (where_clause) |wc| {
                                    try builder.appendSlice(" where ");
                                    try builder.appendSlice(wc);
                                }
                                if (returning_clause) |rc| {
                                    try builder.appendSlice(" returning ");
                                    try builder.appendSlice(rc);
                                }
                                const sydra_str = try builder.toOwnedSlice();
                                const duration = std.time.nanoTimestamp() - start;
                                compat.clog.global().record(trimmed, sydra_str, false, false, duration);
                                return Result{ .success = .{ .sydraql = sydra_str } };
                            }
                        }
                    }
                }
            }
        }
    }

    if (startsWithCaseInsensitive(trimmed, "DELETE FROM ")) {
        var remainder = std.mem.trim(u8, trimmed["DELETE FROM ".len..], " \t\r\n");
        if (remainder.len != 0) {
            var returning_clause: ?[]const u8 = null;
            if (findLastCaseInsensitive(remainder, "RETURNING")) |ret_idx| {
                const before_ok = ret_idx == 0 or std.ascii.isWhitespace(remainder[ret_idx - 1]);
                const after_idx = ret_idx + "RETURNING".len;
                const after_ok = after_idx >= remainder.len or std.ascii.isWhitespace(remainder[after_idx]);
                if (before_ok and after_idx <= remainder.len and after_ok) {
                    const clause_raw = std.mem.trim(u8, remainder[after_idx..], " \t\r\n;");
                    if (clause_raw.len != 0) {
                        returning_clause = clause_raw;
                        remainder = std.mem.trimRight(u8, remainder[0..ret_idx], " \t\r\n;");
                    }
                }
            }
            remainder = std.mem.trimRight(u8, remainder, " \t\r\n;");
            if (remainder.len != 0) {
                var table_slice = remainder;
                var where_clause: ?[]const u8 = null;
                if (findCaseInsensitive(remainder, " WHERE ")) |where_idx| {
                    const before_where = std.mem.trimRight(u8, remainder[0..where_idx], " \t\r\n;");
                    const after_where = std.mem.trim(u8, remainder[where_idx + " WHERE ".len ..], " \t\r\n;");
                    if (after_where.len != 0 and before_where.len != 0) {
                        table_slice = before_where;
                        where_clause = after_where;
                    } else {
                        table_slice = remainder;
                        where_clause = null;
                    }
                }
                table_slice = std.mem.trimRight(u8, table_slice, " \t\r\n;");
                if (table_slice.len != 0) {
                    var builder = std.ArrayList(u8).init(alloc);
                    defer builder.deinit();
                    try builder.appendSlice("delete from ");
                    try builder.appendSlice(table_slice);
                    if (where_clause) |wc| {
                        try builder.appendSlice(" where ");
                        try builder.appendSlice(wc);
                    }
                    if (returning_clause) |rc| {
                        try builder.appendSlice(" returning ");
                        try builder.appendSlice(rc);
                    }
                    const sydra_str = try builder.toOwnedSlice();
                    const duration = std.time.nanoTimestamp() - start;
                    compat.clog.global().record(trimmed, sydra_str, false, false, duration);
                    return Result{ .success = .{ .sydraql = sydra_str } };
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

    var expected_translations: u64 = 0;
    var expected_fallbacks: u64 = 0;

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
                expected_translations += 1;
            },
            .failure => |expected| {
                try std.testing.expect(result == .failure);
                try std.testing.expectEqualStrings(expected.sqlstate, result.failure.sqlstate);
                if (expected.message.len != 0) {
                    try std.testing.expectEqualStrings(expected.message, result.failure.message);
                }
                expected_fallbacks += 1;
            },
        }
    }

    const snap = compat.stats.global().snapshot();
    try std.testing.expectEqual(expected_translations, snap.translations);
    try std.testing.expectEqual(expected_fallbacks, snap.fallbacks);
    compat.stats.global().reset();
}
