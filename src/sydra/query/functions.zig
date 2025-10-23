const std = @import("std");

pub const FunctionKind = enum {
    scalar,
    aggregate,
    window,
};

pub const ArgumentType = enum {
    integer,
    float,
    boolean,
    duration,
    timestamp,
    value,
    tags,
    any,
};

pub const ReturnType = enum {
    integer,
    float,
    boolean,
    timestamp,
    value,
    void,
};

pub const FunctionSignature = struct {
    name: []const u8,
    kind: FunctionKind,
    args: []const ArgumentType,
    return_type: ReturnType,
};

const builtin_registry = [_]FunctionSignature{
    .{
        .name = "avg",
        .kind = .aggregate,
        .args = &.{.value},
        .return_type = .float,
    },
    .{
        .name = "sum",
        .kind = .aggregate,
        .args = &.{.value},
        .return_type = .float,
    },
    .{
        .name = "count",
        .kind = .aggregate,
        .args = &.{},
        .return_type = .integer,
    },
    .{
        .name = "time_bucket",
        .kind = .scalar,
        .args = &.{ .duration, .timestamp },
        .return_type = .timestamp,
    },
};

pub fn registry() []const FunctionSignature {
    return builtin_registry[0..];
}

pub fn lookup(name: []const u8) ?*const FunctionSignature {
    for (builtin_registry, 0..) |_, idx| {
        const entry = &builtin_registry[idx];
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
    }
    return null;
}

test "lookup finds avg" {
    const maybe_entry = lookup("AVG");
    try std.testing.expect(maybe_entry != null);
    const entry = maybe_entry.?;
    try std.testing.expect(entry.kind == .aggregate);
    try std.testing.expectEqual(@as(usize, 1), entry.args.len);
}
