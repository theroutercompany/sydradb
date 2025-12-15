---
sidebar_position: 2
title: src/sydra/query/common.zig
---

# `src/sydra/query/common.zig`

## Purpose

Defines shared low-level utilities used throughout the sydraQL pipeline.

## Used by

- [Lexer](./lexer.md) (token spans)
- [Parser](./parser.md) and [AST](./ast.md) (node spans)
- [Errors](./errors.md) and [Validator](./validator.md) (diagnostic ranges)

## Public API

### `pub const Span`

Represents a half-open byte range `[start,end)` into the original query text.

Methods:

- `Span.init(start, end)` – constructor
- `Span.width()` – length in bytes (clamped to `0` if invalid)
- `Span.clamp(len)` – clamps the span to a buffer length

## Code excerpt

```zig title="src/sydra/query/common.zig"
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
```
