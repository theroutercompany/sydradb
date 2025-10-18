const std = @import("std");

pub const ConvertError = error{
    TypeMismatch,
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn asBool(self: Value) ConvertError!bool {
        return switch (self) {
            .boolean => |b| b,
            else => ConvertError.TypeMismatch,
        };
    }

    pub fn asFloat(self: Value) ConvertError!f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => ConvertError.TypeMismatch,
        };
    }

    pub fn asInt(self: Value) ConvertError!i64 {
        return switch (self) {
            .integer => |i| i,
            else => ConvertError.TypeMismatch,
        };
    }

    pub fn asString(self: Value) ConvertError![]const u8 {
        return switch (self) {
            .string => |s| s,
            else => ConvertError.TypeMismatch,
        };
    }

    pub fn equals(a: Value, b: Value) bool {
        return switch (a) {
            .null => b == .null,
            .boolean => |ab| switch (b) {
                .boolean => |bb| ab == bb,
                else => false,
            },
            .integer => |ai| switch (b) {
                .integer => |bi| ai == bi,
                .float => |bf| @as(f64, @floatFromInt(ai)) == bf,
                else => false,
            },
            .float => |af| switch (b) {
                .float => |bf| af == bf,
                .integer => |bi| af == @as(f64, @floatFromInt(bi)),
                else => false,
            },
            .string => |astr| switch (b) {
                .string => |bstr| std.mem.eql(u8, astr, bstr),
                else => false,
            },
        };
    }

    pub fn compareNumeric(a: Value, b: Value) ConvertError!std.math.Order {
        const left = try a.asFloat();
        const right = try b.asFloat();
        if (left < right) return .lt;
        if (left > right) return .gt;
        return .eq;
    }

    pub fn copySlice(allocator: std.mem.Allocator, values: []const Value) ![]Value {
        const out = try allocator.alloc(Value, values.len);
        std.mem.copy(Value, out, values);
        return out;
    }
};
