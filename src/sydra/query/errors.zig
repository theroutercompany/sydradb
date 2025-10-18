const std = @import("std");
const common = @import("common.zig");

pub const ErrorCode = enum {
    time_range_required,
    unsupported_fill_policy,
    invalid_function_arity,
    invalid_syntax,
    unimplemented,
};

pub const Diagnostic = struct {
    code: ErrorCode,
    message: []const u8,
    span: ?common.Span = null,
};

pub const DiagnosticList = std.ArrayListUnmanaged(Diagnostic);

pub fn initDiagnostic(alloc: std.mem.Allocator, code: ErrorCode, message: []const u8, span: ?common.Span) !Diagnostic {
    const owned = try alloc.dupe(u8, message);
    return .{ .code = code, .message = owned, .span = span };
}

test "diagnostic init clones message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    const diag = try initDiagnostic(alloc, .unimplemented, "stub", null);
    defer alloc.free(diag.message);
    try std.testing.expectEqualStrings("stub", diag.message);
    try std.testing.expect(diag.span == null);
}
