---
sidebar_position: 3
title: src/sydra/compat/sqlstate.zig
---

# `src/sydra/compat/sqlstate.zig`

## Purpose

Defines a small, canonical subset of PostgreSQL SQLSTATE identifiers SydraDB aims to emulate and helpers for constructing error payloads.

This module is used by compatibility surfaces (e.g. pgwire translation failures) to return structured error codes.

## Public API

### `pub const Code = enum { ... }`

Enum values correspond to a fixed SQLSTATE string in an internal table, including:

- `successful_completion` → `00000`
- `unique_violation` → `23505`
- `not_null_violation` → `23502`
- `foreign_key_violation` → `23503`
- `check_violation` → `23514`
- `serialization_failure` → `40001`
- `deadlock_detected` → `40P01`
- `syntax_error` → `42601`
- `undefined_table` → `42P01`
- `undefined_column` → `42703`
- `insufficient_privilege` → `42501`
- `duplicate_object` → `42710`
- `feature_not_supported` → `0A000`
- `invalid_parameter_value` → `22023`

```zig title="Code enum (from src/sydra/compat/sqlstate.zig)"
pub const Code = enum {
    successful_completion, // 00000
    unique_violation, // 23505
    not_null_violation, // 23502
    foreign_key_violation, // 23503
    check_violation, // 23514
    serialization_failure, // 40001
    deadlock_detected, // 40P01
    syntax_error, // 42601
    undefined_table, // 42P01
    undefined_column, // 42703
    insufficient_privilege, // 42501
    duplicate_object, // 42710
    feature_not_supported, // 0A000
    invalid_parameter_value, // 22023
};
```

### `pub fn lookup(code: Code) Entry`

Returns the entry row for `code` (SQLSTATE string + severity + default message).

Implementation detail: `lookup` indexes the internal `entries` table by `@intFromEnum(code)`.

### `pub const ErrorPayload = struct { ... }`

Fields:

- `sqlstate: []const u8`
- `severity: []const u8` (e.g. `ERROR`, `NOTICE`)
- `message: []const u8`
- `detail: ?[]const u8 = null`
- `hint: ?[]const u8 = null`

### `pub fn buildPayload(code, message, detail, hint) ErrorPayload`

Builds an `ErrorPayload`:

- Uses the SQLSTATE and severity from `lookup(code)`.
- Uses `message` if provided, otherwise falls back to the entry’s default message.
- Passes through `detail` and `hint`.

```zig title="buildPayload (from src/sydra/compat/sqlstate.zig)"
pub fn buildPayload(code: Code, message: ?[]const u8, detail: ?[]const u8, hint: ?[]const u8) ErrorPayload {
    const entry = lookup(code);
    return .{
        .sqlstate = entry.sqlstate,
        .severity = entry.severity,
        .message = message orelse entry.default_message,
        .detail = detail,
        .hint = hint,
    };
}
```

### `pub fn writeHumanReadable(payload: ErrorPayload, writer) !void`

Formats a compact, human-readable string:

```
[23505] ERROR: duplicate key value violates unique constraint detail=... hint=...
```

Only includes `detail=` and `hint=` segments when set.

```zig title="writeHumanReadable (excerpt)"
try writer.print("[{s}] {s}: {s}", .{ payload.sqlstate, payload.severity, payload.message });
if (payload.detail) |d| try writer.print(" detail={s}", .{d});
if (payload.hint) |h| try writer.print(" hint={s}", .{h});
```

### `pub fn fromSqlstate(sqlstate: []const u8) ?Code`

Reverse lookup: scans the internal table and returns the matching `Code` enum value, or `null` if unknown.
