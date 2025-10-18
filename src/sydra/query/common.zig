const std = @import("std");

/// Span records a half-open byte range inside the original query text.
/// It is intentionally simple so we can extend with line/column metadata later.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn init(start: usize, end: usize) Span {
        return .{ .start = start, .end = end };
    }

    /// width returns the number of bytes covered by the span.
    pub fn width(self: Span) usize {
        return if (self.end >= self.start) self.end - self.start else 0;
    }

    /// clamp ensures the span stays within the provided buffer length.
    pub fn clamp(self: Span, len: usize) Span {
        const clamped_start = std.math.min(self.start, len);
        const clamped_end = std.math.min(std.math.max(self.end, clamped_start), len);
        return .{ .start = clamped_start, .end = clamped_end };
    }
};
