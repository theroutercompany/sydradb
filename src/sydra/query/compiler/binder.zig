const std = @import("std");

const ast = @import("../ast.zig");
const common = @import("../common.zig");
const diagnostics = @import("diagnostics.zig");
const engine_mod = @import("../../engine.zig");
const errors = @import("errors.zig");
const ir = @import("ir.zig");

pub const BindResult = struct {
    selector: ?ir.BoundSelector,
    diagnostics: []const diagnostics.CompilationDiagnostic,
    fallback_reason: ?diagnostics.FallbackReason,
};

pub fn bindSelector(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    selector: ?ast.Selector,
) errors.CompileError!BindResult {
    if (selector == null) {
        return .{
            .selector = null,
            .diagnostics = &.{},
            .fallback_reason = null,
        };
    }

    if (selector.?.tag_filter != null) {
        const diag = try allocator.alloc(diagnostics.CompilationDiagnostic, 1);
        diag[0] = try diagnostics.makeDiagnostic(allocator, .unsupported_tag_filter, selector.?.span);
        return .{
            .selector = null,
            .diagnostics = diag,
            .fallback_reason = .unsupported_tag_filter,
        };
    }

    return switch (selector.?.series) {
        .by_id => |by_id| {
            const resolution = engine.resolveSelector(.{ .by_id = @intCast(by_id.value) }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            return .{
                .selector = ir.BoundSelector{
                    .source = .by_id,
                    .series_id = @intCast(by_id.value),
                    .name = resolution.series,
                    .canonical_tags = resolution.canonical_tags,
                    .span = by_id.span,
                },
                .diagnostics = &.{},
                .fallback_reason = null,
            };
        },
        .name => |ident| {
            const resolution = engine.resolveSelector(.{ .name = ident.value }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            return switch (resolution.status) {
                .resolved, .exact_match => .{
                    .selector = ir.BoundSelector{
                        .source = if (resolution.status == .exact_match) .exact_match else .unique_name,
                        .series_id = resolution.series_id.?,
                        .name = resolution.series orelse ident.value,
                        .canonical_tags = resolution.canonical_tags,
                        .span = ident.span,
                    },
                    .diagnostics = &.{},
                    .fallback_reason = null,
                },
                .not_found => try fallback(allocator, .series_not_found, ident.span),
                .ambiguous => try fallback(allocator, .ambiguous_selector, ident.span),
            };
        },
    };
}

fn fallback(
    allocator: std.mem.Allocator,
    reason: diagnostics.FallbackReason,
    span: common.Span,
) !BindResult {
    const diag = try allocator.alloc(diagnostics.CompilationDiagnostic, 1);
    diag[0] = try diagnostics.makeDiagnostic(allocator, reason, span);
    return .{
        .selector = null,
        .diagnostics = diag,
        .fallback_reason = reason,
    };
}
