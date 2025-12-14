---
sidebar_position: 3
title: src/sydra/query/errors.zig
---

# `src/sydra/query/errors.zig`

## Purpose

Defines diagnostic structures for sydraQL validation.

## Public API

### `pub const ErrorCode = enum { ... }`

Current codes:

- `time_range_required`
- `unsupported_fill_policy`
- `invalid_function_arity`
- `invalid_syntax`
- `unimplemented`

### `pub const Diagnostic`

- `code: ErrorCode`
- `message: []const u8` (owned allocation)
- `span: ?Span`

### `pub const DiagnosticList`

Alias: `std.ArrayListUnmanaged(Diagnostic)`

### `pub fn initDiagnostic(alloc, code, message, span) !Diagnostic`

Clones `message` into an owned allocation and returns a `Diagnostic`.

