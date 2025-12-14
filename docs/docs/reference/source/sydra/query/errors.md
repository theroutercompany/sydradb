---
sidebar_position: 3
title: src/sydra/query/errors.zig
---

# `src/sydra/query/errors.zig`

## Purpose

Defines diagnostic structures for sydraQL validation.

## Definition index (public)

### `pub const ErrorCode = enum { ... }`

Current codes:

- `time_range_required`
- `unsupported_fill_policy`
- `invalid_function_arity`
- `invalid_syntax`
- `unimplemented`

Intended meaning (by convention in this repo):

- `time_range_required` — missing or insufficient `time` predicate
- `unsupported_fill_policy` — fill clause exists but the policy is not supported
- `invalid_function_arity` — a function was called with the wrong number of arguments
- `invalid_syntax` — generic “this construct is not valid” diagnostic used by the validator
- `unimplemented` — reserved for “recognized but not implemented yet”

### `pub const Diagnostic`

- `code: ErrorCode`
- `message: []const u8` — **owned allocation**
- `span: ?Span`

Ownership note:

- `initDiagnostic` clones `message` using the provided allocator.
- Callers are responsible for freeing `diag.message` (the validator does this in `Analyzer.deinit`).

### `pub const DiagnosticList`

Alias: `std.ArrayListUnmanaged(Diagnostic)`

### `pub fn initDiagnostic(alloc, code, message, span) !Diagnostic`

Clones `message` into an owned allocation and returns a `Diagnostic`.

## Tests

Inline tests validate that `initDiagnostic` clones the message buffer.
