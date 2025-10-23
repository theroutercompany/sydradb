const std = @import("std");

pub const FunctionKind = enum {
    scalar,
    aggregate,
    window,
    fill,
};

pub const TypeTag = enum {
    any,
    null,
    boolean,
    integer,
    float,
    numeric,
    value,
    string,
    timestamp,
    duration,
    tags,
};

pub const Type = struct {
    tag: TypeTag,
    nullable: bool,

    pub fn init(tag: TypeTag, nullable: bool) Type {
        return .{ .tag = tag, .nullable = nullable };
    }

    pub fn nonNull(self: Type) Type {
        return .{ .tag = self.tag, .nullable = false };
    }
};

pub const Expectation = struct {
    label: []const u8,
    allowed: []const TypeTag,
    allow_nullable: bool = true,

    pub fn matches(self: Expectation, actual: Type) bool {
        if (!self.allow_nullable and actual.nullable) return false;
        if (self.allowed.len == 0) return true;
        for (self.allowed) |expected_tag| {
            if (tagAccepts(expected_tag, actual.tag)) return true;
        }
        return false;
    }

    fn tagAccepts(expected: TypeTag, actual: TypeTag) bool {
        if (expected == .any or actual == .any) return true;
        return switch (expected) {
            .numeric => actual == .numeric or actual == .float or actual == .integer or actual == .value,
            .value => actual == .value or actual == .numeric or actual == .float or actual == .integer,
            .duration => actual == .duration or actual == .numeric or actual == .float or actual == .integer or actual == .value,
            .timestamp => actual == .timestamp or actual == .value,
            else => expected == actual,
        };
    }
};

pub const ParamSpec = struct {
    expectation: Expectation,
    optional: bool = false,
    variadic: bool = false,
};

pub const ReturnStrategy = union(enum) {
    fixed: Type,
    same_as: struct {
        index: usize,
        force_non_nullable: bool = false,
    },
};

pub const PlannerHints = struct {
    streaming: bool = true,
    requires_sorted_input: bool = false,
    needs_window_frame: bool = false,
    bucket_sensitive: bool = false,
};

pub const FunctionSignature = struct {
    name: []const u8,
    kind: FunctionKind,
    params: []const ParamSpec,
    return_strategy: ReturnStrategy,
    hints: PlannerHints = .{},

    pub fn requiredArgs(self: *const FunctionSignature) usize {
        var count: usize = 0;
        for (self.params) |param| {
            if (param.variadic) {
                if (!param.optional) count += 1;
            } else if (!param.optional) {
                count += 1;
            }
        }
        return count;
    }

    pub fn maxArgs(self: *const FunctionSignature) ?usize {
        var count: usize = 0;
        for (self.params) |param| {
            if (param.variadic) return null;
            count += 1;
        }
        return count;
    }

    pub fn infer(self: *const FunctionSignature, args: []const Type) TypeCheckError!Type {
        const min_args = self.requiredArgs();
        if (args.len < min_args) return TypeCheckError.ArityMismatch;

        if (self.maxArgs()) |max_args| {
            if (args.len > max_args) return TypeCheckError.ArityMismatch;
        }

        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const spec = try self.specForIndex(idx);
            if (!spec.expectation.matches(args[idx])) {
                return TypeCheckError.TypeMismatch;
            }
        }

        return switch (self.return_strategy) {
            .fixed => |t| t,
            .same_as => |info| blk: {
                if (info.index >= args.len) return TypeCheckError.ArityMismatch;
                var ty = args[info.index];
                if (info.force_non_nullable) {
                    ty = ty.nonNull();
                }
                break :blk ty;
            },
        };
    }

    fn specForIndex(self: *const FunctionSignature, arg_index: usize) TypeCheckError!*const ParamSpec {
        if (arg_index < self.params.len) {
            return &self.params[arg_index];
        }
        if (self.params.len == 0) return TypeCheckError.ArityMismatch;
        const last = &self.params[self.params.len - 1];
        if (last.variadic) return last;
        return TypeCheckError.ArityMismatch;
    }
};

pub const TypeCheckError = error{
    UnknownFunction,
    ArityMismatch,
    TypeMismatch,
};

pub const FunctionMatch = struct {
    signature: *const FunctionSignature,
    return_type: Type,
};

const type_float_nullable = Type.init(.float, true);
const type_float_nonnull = Type.init(.float, false);
const type_integer_nonnull = Type.init(.integer, false);
const type_timestamp_nonnull = Type.init(.timestamp, false);

const expect_any = Expectation{
    .label = "any",
    .allowed = &.{.any},
};

const expect_numeric = Expectation{
    .label = "numeric",
    .allowed = &.{ .value, .numeric, .float, .integer },
};

const expect_numeric_nonnull = Expectation{
    .label = "numeric",
    .allowed = &.{ .value, .numeric, .float, .integer },
    .allow_nullable = false,
};

const expect_float_nonnull = Expectation{
    .label = "float",
    .allowed = &.{.float},
    .allow_nullable = false,
};

const expect_integer_nonnull = Expectation{
    .label = "integer",
    .allowed = &.{.integer},
    .allow_nullable = false,
};

const expect_duration_nonnull = Expectation{
    .label = "duration",
    .allowed = &.{.duration},
    .allow_nullable = false,
};

const expect_timestamp_nonnull = Expectation{
    .label = "timestamp",
    .allowed = &.{.timestamp},
    .allow_nullable = false,
};

const builtin_registry = [_]FunctionSignature{
    .{
        .name = "avg",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .fixed = type_float_nullable },
    },
    .{
        .name = "sum",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .same_as = .{ .index = 0 } },
    },
    .{
        .name = "min",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .same_as = .{ .index = 0 } },
    },
    .{
        .name = "max",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .same_as = .{ .index = 0 } },
    },
    .{
        .name = "count",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_any, .optional = true }},
        .return_strategy = .{ .fixed = type_integer_nonnull },
    },
    .{
        .name = "last",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .same_as = .{ .index = 0 } },
        .hints = .{ .requires_sorted_input = true },
    },
    .{
        .name = "first",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .same_as = .{ .index = 0 } },
        .hints = .{ .requires_sorted_input = true },
    },
    .{
        .name = "percentile",
        .kind = .aggregate,
        .params = &.{
            ParamSpec{ .expectation = expect_numeric },
            ParamSpec{ .expectation = expect_float_nonnull },
        },
        .return_strategy = .{ .fixed = type_float_nullable },
        .hints = .{ .streaming = false, .requires_sorted_input = true },
    },
    .{
        .name = "abs",
        .kind = .scalar,
        .params = &.{ParamSpec{ .expectation = expect_numeric_nonnull }},
        .return_strategy = .{ .fixed = type_float_nonnull },
    },
    .{
        .name = "ceil",
        .kind = .scalar,
        .params = &.{ParamSpec{ .expectation = expect_numeric_nonnull }},
        .return_strategy = .{ .fixed = type_float_nonnull },
    },
    .{
        .name = "floor",
        .kind = .scalar,
        .params = &.{ParamSpec{ .expectation = expect_numeric_nonnull }},
        .return_strategy = .{ .fixed = type_float_nonnull },
    },
    .{
        .name = "round",
        .kind = .scalar,
        .params = &.{ParamSpec{ .expectation = expect_numeric_nonnull }},
        .return_strategy = .{ .fixed = type_float_nonnull },
    },
    .{
        .name = "pow",
        .kind = .scalar,
        .params = &.{
            ParamSpec{ .expectation = expect_numeric_nonnull },
            ParamSpec{ .expectation = expect_numeric_nonnull },
        },
        .return_strategy = .{ .fixed = type_float_nonnull },
    },
    .{
        .name = "ln",
        .kind = .scalar,
        .params = &.{ParamSpec{ .expectation = expect_numeric_nonnull }},
        .return_strategy = .{ .fixed = type_float_nonnull },
    },
    .{
        .name = "sqrt",
        .kind = .scalar,
        .params = &.{ParamSpec{ .expectation = expect_numeric_nonnull }},
        .return_strategy = .{ .fixed = type_float_nonnull },
    },
    .{
        .name = "now",
        .kind = .scalar,
        .params = &.{},
        .return_strategy = .{ .fixed = type_timestamp_nonnull },
    },
    .{
        .name = "time_bucket",
        .kind = .scalar,
        .params = &.{
            ParamSpec{ .expectation = expect_duration_nonnull },
            ParamSpec{ .expectation = expect_timestamp_nonnull },
            ParamSpec{ .expectation = expect_timestamp_nonnull, .optional = true },
        },
        .return_strategy = .{ .fixed = type_timestamp_nonnull },
        .hints = .{ .bucket_sensitive = true },
    },
    .{
        .name = "lag",
        .kind = .window,
        .params = &.{
            ParamSpec{ .expectation = expect_any },
            ParamSpec{ .expectation = expect_integer_nonnull, .optional = true },
        },
        .return_strategy = .{ .same_as = .{ .index = 0 } },
        .hints = .{ .requires_sorted_input = true, .needs_window_frame = true },
    },
    .{
        .name = "lead",
        .kind = .window,
        .params = &.{
            ParamSpec{ .expectation = expect_any },
            ParamSpec{ .expectation = expect_integer_nonnull, .optional = true },
        },
        .return_strategy = .{ .same_as = .{ .index = 0 } },
        .hints = .{ .requires_sorted_input = true, .needs_window_frame = true },
    },
    .{
        .name = "rate",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .fixed = type_float_nullable },
        .hints = .{ .requires_sorted_input = true, .bucket_sensitive = true },
    },
    .{
        .name = "irate",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .fixed = type_float_nullable },
        .hints = .{ .requires_sorted_input = true, .bucket_sensitive = true },
    },
    .{
        .name = "delta",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .fixed = type_float_nullable },
        .hints = .{ .requires_sorted_input = true },
    },
    .{
        .name = "integral",
        .kind = .aggregate,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .fixed = type_float_nullable },
        .hints = .{ .requires_sorted_input = true, .bucket_sensitive = true },
    },
    .{
        .name = "moving_avg",
        .kind = .window,
        .params = &.{
            ParamSpec{ .expectation = expect_numeric },
            ParamSpec{ .expectation = expect_duration_nonnull },
        },
        .return_strategy = .{ .fixed = type_float_nullable },
        .hints = .{ .requires_sorted_input = true, .needs_window_frame = true },
    },
    .{
        .name = "ema",
        .kind = .window,
        .params = &.{
            ParamSpec{ .expectation = expect_numeric },
            ParamSpec{ .expectation = expect_duration_nonnull },
            ParamSpec{ .expectation = expect_float_nonnull },
        },
        .return_strategy = .{ .fixed = type_float_nullable },
        .hints = .{ .requires_sorted_input = true, .needs_window_frame = true },
    },
    .{
        .name = "coalesce",
        .kind = .fill,
        .params = &.{ParamSpec{ .expectation = expect_any, .variadic = true }},
        .return_strategy = .{ .same_as = .{ .index = 0, .force_non_nullable = true } },
    },
    .{
        .name = "fill_forward",
        .kind = .fill,
        .params = &.{ParamSpec{ .expectation = expect_numeric }},
        .return_strategy = .{ .same_as = .{ .index = 0 } },
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

pub fn resolve(name: []const u8, args: []const Type) TypeCheckError!FunctionMatch {
    const entry = lookup(name) orelse return TypeCheckError.UnknownFunction;
    const return_type = try entry.infer(args);
    return FunctionMatch{ .signature = entry, .return_type = return_type };
}

pub fn displayName(ty: Type) []const u8 {
    return switch (ty.tag) {
        .any => "any",
        .null => "null",
        .boolean => "boolean",
        .integer => "integer",
        .float => "float",
        .numeric => "numeric",
        .value => "value",
        .string => "string",
        .timestamp => "timestamp",
        .duration => "duration",
        .tags => "tags",
    };
}

pub const PgTypeInfo = struct {
    oid: u32,
    len: i16,
    modifier: i32,
    format: u16 = 0,
};

pub fn pgTypeInfo(ty: Type) PgTypeInfo {
    return switch (ty.tag) {
        .boolean => .{ .oid = 16, .len = 1, .modifier = -1 },
        .integer => .{ .oid = 20, .len = 8, .modifier = -1 },
        .float => .{ .oid = 701, .len = 8, .modifier = -1 },
        .numeric => .{ .oid = 1700, .len = -1, .modifier = -1 },
        .timestamp => .{ .oid = 1114, .len = 8, .modifier = -1 },
        .duration => .{ .oid = 1186, .len = 16, .modifier = -1 },
        .tags => .{ .oid = 3802, .len = -1, .modifier = -1 }, // jsonb
        .string => .{ .oid = 25, .len = -1, .modifier = -1 },
        .value, .null, .any => .{ .oid = 25, .len = -1, .modifier = -1 },
    };
}

test "lookup is case insensitive" {
    const entry = lookup("AVG");
    try std.testing.expect(entry != null);
    try std.testing.expect(entry.?.kind == .aggregate);
}

test "resolve avg returns nullable float" {
    const args = [_]Type{Type.init(.value, true)};
    const match = try resolve("avg", &args);
    try std.testing.expectEqual(TypeTag.float, match.return_type.tag);
    try std.testing.expect(match.return_type.nullable);
}

test "resolve min propagates numeric type" {
    const args = [_]Type{Type.init(.integer, false)};
    const match = try resolve("min", &args);
    try std.testing.expectEqual(TypeTag.integer, match.return_type.tag);
    try std.testing.expect(!match.return_type.nullable);
}

test "count accepts zero arguments" {
    const match = try resolve("count", &[_]Type{});
    try std.testing.expectEqual(TypeTag.integer, match.return_type.tag);
    try std.testing.expect(!match.return_type.nullable);
}

test "percentile arity and type validation" {
    const args_one = [_]Type{Type.init(.float, false)};
    try std.testing.expectError(TypeCheckError.ArityMismatch, resolve("percentile", &args_one));

    const args_bad = [_]Type{
        Type.init(.float, false),
        Type.init(.integer, false),
    };
    try std.testing.expectError(TypeCheckError.TypeMismatch, resolve("percentile", &args_bad));
}

test "coalesce forces non-null result" {
    const args = [_]Type{
        Type.init(.float, true),
        Type.init(.float, false),
    };
    const match = try resolve("coalesce", &args);
    try std.testing.expectEqual(TypeTag.float, match.return_type.tag);
    try std.testing.expect(!match.return_type.nullable);
}

test "time_bucket supports optional origin" {
    const args_two = [_]Type{
        Type.init(.duration, false),
        Type.init(.timestamp, false),
    };
    const match_two = try resolve("time_bucket", &args_two);
    try std.testing.expectEqual(TypeTag.timestamp, match_two.return_type.tag);

    const args_three = [_]Type{
        Type.init(.duration, false),
        Type.init(.timestamp, false),
        Type.init(.timestamp, false),
    };
    const match_three = try resolve("time_bucket", &args_three);
    try std.testing.expectEqual(TypeTag.timestamp, match_three.return_type.tag);
}

test "lag optional offset" {
    const args_one = [_]Type{Type.init(.float, false)};
    const match_one = try resolve("lag", &args_one);
    try std.testing.expectEqual(TypeTag.float, match_one.return_type.tag);

    const args_two = [_]Type{
        Type.init(.float, false),
        Type.init(.integer, false),
    };
    const match_two = try resolve("lag", &args_two);
    try std.testing.expectEqual(TypeTag.float, match_two.return_type.tag);
}

test "rate rejects non numeric input" {
    const args = [_]Type{Type.init(.boolean, false)};
    try std.testing.expectError(TypeCheckError.TypeMismatch, resolve("rate", &args));
}
