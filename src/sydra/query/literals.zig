const std = @import("std");

pub const LiteralParseError = error{
    InvalidNumber,
    InvalidDuration,
    InvalidTimestamp,
};

pub fn isFloatLiteral(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '.') != null or
        std.mem.indexOfScalar(u8, text, 'e') != null or
        std.mem.indexOfScalar(u8, text, 'E') != null;
}

pub fn parseDurationSeconds(text: []const u8) LiteralParseError!f64 {
    if (text.len < 2) return error.InvalidDuration;
    var unit_start: usize = 0;
    while (unit_start < text.len and ((text[unit_start] >= '0' and text[unit_start] <= '9') or text[unit_start] == '.' or text[unit_start] == '+' or text[unit_start] == '-')) : (unit_start += 1) {}
    if (unit_start == 0 or unit_start >= text.len) return error.InvalidDuration;

    const magnitude = std.fmt.parseFloat(f64, text[0..unit_start]) catch return error.InvalidDuration;
    const unit = text[unit_start..];
    const seconds = if (std.ascii.eqlIgnoreCase(unit, "ns"))
        magnitude / @as(f64, @floatFromInt(std.time.ns_per_s))
    else if (std.ascii.eqlIgnoreCase(unit, "us"))
        magnitude / @as(f64, @floatFromInt(std.time.us_per_s))
    else if (std.ascii.eqlIgnoreCase(unit, "ms"))
        magnitude / @as(f64, @floatFromInt(std.time.ms_per_s))
    else if (std.ascii.eqlIgnoreCase(unit, "s"))
        magnitude
    else if (std.ascii.eqlIgnoreCase(unit, "m"))
        magnitude * 60.0
    else if (std.ascii.eqlIgnoreCase(unit, "h"))
        magnitude * 60.0 * 60.0
    else if (std.ascii.eqlIgnoreCase(unit, "d"))
        magnitude * 60.0 * 60.0 * 24.0
    else if (std.ascii.eqlIgnoreCase(unit, "w"))
        magnitude * 60.0 * 60.0 * 24.0 * 7.0
    else
        return error.InvalidDuration;

    if (!std.math.isFinite(seconds)) return error.InvalidDuration;
    return seconds;
}

pub fn parseTimestampSeconds(text: []const u8) LiteralParseError!f64 {
    var cursor: usize = 0;
    const year = try parseDigits(text, &cursor, 4);
    try expectChar(text, &cursor, '-');
    const month = try parseDigits(text, &cursor, 2);
    try expectChar(text, &cursor, '-');
    const day = try parseDigits(text, &cursor, 2);

    const month_u8: u8 = @intCast(month);
    const day_u8: u8 = @intCast(day);
    if (month_u8 < 1 or month_u8 > 12) return error.InvalidTimestamp;
    if (day_u8 < 1 or day_u8 > daysInMonth(year, month_u8)) return error.InvalidTimestamp;

    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var fractional: f64 = 0.0;

    if (cursor < text.len) {
        const marker = text[cursor];
        if (marker != 'T' and marker != 't') return error.InvalidTimestamp;
        cursor += 1;
        hour = try parseDigits(text, &cursor, 2);
        try expectChar(text, &cursor, ':');
        minute = try parseDigits(text, &cursor, 2);
        try expectChar(text, &cursor, ':');
        second = try parseDigits(text, &cursor, 2);
        if (hour > 23 or minute > 59 or second > 60) return error.InvalidTimestamp;

        if (cursor < text.len and text[cursor] == '.') {
            cursor += 1;
            const frac_start = cursor;
            while (cursor < text.len and std.ascii.isDigit(text[cursor])) : (cursor += 1) {}
            if (cursor == frac_start) return error.InvalidTimestamp;
            const frac_digits = text[frac_start..cursor];
            const scale = pow10(frac_digits.len);
            const frac_value = std.fmt.parseFloat(f64, frac_digits) catch return error.InvalidTimestamp;
            fractional = frac_value / scale;
        }
    }

    var offset_seconds: i64 = 0;
    if (cursor < text.len) {
        switch (text[cursor]) {
            'Z', 'z' => cursor += 1,
            '+', '-' => {
                const sign: i64 = if (text[cursor] == '+') 1 else -1;
                cursor += 1;
                const offset_hour = try parseDigits(text, &cursor, 2);
                var offset_minute: i64 = 0;
                if (cursor < text.len and text[cursor] == ':') {
                    cursor += 1;
                    offset_minute = try parseDigits(text, &cursor, 2);
                } else if (cursor + 2 <= text.len and std.ascii.isDigit(text[cursor]) and std.ascii.isDigit(text[cursor + 1])) {
                    offset_minute = try parseDigits(text, &cursor, 2);
                }
                if (offset_hour > 23 or offset_minute > 59) return error.InvalidTimestamp;
                offset_seconds = sign * (offset_hour * 3600 + offset_minute * 60);
            },
            else => {},
        }
    }

    if (cursor != text.len) return error.InvalidTimestamp;

    const days = daysFromCivil(year, month_u8, day_u8);
    const base_seconds = @as(f64, @floatFromInt(days * std.time.epoch.secs_per_day + hour * 3600 + minute * 60 + second - offset_seconds));
    return base_seconds + fractional;
}

fn parseDigits(text: []const u8, cursor: *usize, count: usize) LiteralParseError!i64 {
    if (cursor.* + count > text.len) return error.InvalidTimestamp;
    for (text[cursor.* .. cursor.* + count]) |ch| {
        if (!std.ascii.isDigit(ch)) return error.InvalidTimestamp;
    }
    const value = std.fmt.parseInt(i64, text[cursor.* .. cursor.* + count], 10) catch return error.InvalidTimestamp;
    cursor.* += count;
    return value;
}

fn expectChar(text: []const u8, cursor: *usize, expected: u8) LiteralParseError!void {
    if (cursor.* >= text.len or text[cursor.*] != expected) return error.InvalidTimestamp;
    cursor.* += 1;
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const adj_year = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(adj_year, 400);
    const yoe = adj_year - era * 400;
    const month_index: i64 = @as(i64, @intCast(month)) + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * month_index + 2, 5) + @as(i64, @intCast(day)) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn pow10(count: usize) f64 {
    var out: f64 = 1.0;
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) out *= 10.0;
    return out;
}

test "parse duration literals to seconds" {
    try std.testing.expectApproxEqAbs(@as(f64, 300.0), try parseDurationSeconds("5m"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try parseDurationSeconds("500ms"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5400.0), try parseDurationSeconds("1.5h"), 1e-9);
}

test "parse timestamp literals to epoch seconds" {
    try std.testing.expectApproxEqAbs(@as(f64, 1_648_099_200.0), try parseTimestampSeconds("2022-03-27T00:00:00Z"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1_648_099_200.0), try parseTimestampSeconds("2022-03-27T01:00:00+01:00"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1_648_099_200.25), try parseTimestampSeconds("2022-03-27T00:00:00.25Z"), 1e-9);
}
