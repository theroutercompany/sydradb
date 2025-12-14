---
sidebar_position: 10
title: src/sydra/compat/wire/session.zig
---

# `src/sydra/compat/wire/session.zig`

## Purpose

Implements the pgwire handshake and constructs a `Session` object containing startup metadata (user/database/app name + raw parameters).

This is used by `wire/server.zig` before entering the per-message loop.

## Public API

### `pub const SessionConfig`

Backend “ParameterStatus” defaults:

- `server_version: []const u8 = "15.2"`
- `server_encoding: []const u8 = "UTF8"`
- `client_encoding: []const u8 = "UTF8"`
- `date_style: []const u8 = "ISO, MDY"`
- `time_zone: []const u8 = "UTC"`
- `integer_datetimes: []const u8 = "on"`
- `standard_conforming_strings: []const u8 = "on"`
- `default_database: ?[]const u8 = null`
- `application_name_prefix: []const u8 = "sydradb"`

### `pub const Session`

Fields:

- `alloc: std.mem.Allocator`
- `user: []const u8`
- `database: []const u8`
- `application_name: []const u8`
- `parameters: []protocol.Parameter` (allocator-owned copies)

Methods:

- `pub fn deinit(self: Session) void` frees all owned allocations (including `parameters` keys/values).
- `pub fn borrowedUser/borrowedDatabase/borrowedApplicationName(self: Session) []const u8`

### `pub const HandshakeError = error{ MissingUser, InvalidStartup, UnsupportedProtocol, CancelRequestUnsupported, OutOfMemory }`

### `pub fn performHandshake(alloc, reader, writer, config) HandshakeError!Session`

Handshake steps:

1. Calls `protocol.readStartup(alloc, reader, writer, .{})`.
   - Maps `error.UnsupportedProtocol` and `error.CancelRequestUnsupported` into `HandshakeError`.
2. Requires a `user` startup parameter.
   - If missing, writes a `FATAL` pgwire error (`28000`, `"user parameter required"`) and returns `HandshakeError.MissingUser`.
3. Derives:
   - `database` = startup `database` or `config.default_database` or `user`
   - `application_name` = startup `application_name` or `config.application_name_prefix`
4. Duplicates `user`, `database`, `application_name` into allocator-owned strings.
5. Duplicates all startup parameters into allocator-owned `[]protocol.Parameter`.
6. Writes backend responses:
   - `AuthenticationOk`
   - multiple `ParameterStatus` entries (from `SessionConfig`)
   - `ReadyForQuery('I')`

The function returns an owned `Session` whose `deinit()` must be called by the caller.

```zig title="User parameter required (excerpt)"
const user_param = startup.find("user") orelse {
    protocol.writeErrorResponse(writer, "FATAL", "28000", "user parameter required") catch return HandshakeError.InvalidStartup;
    return HandshakeError.MissingUser;
};
```

```zig title="Backend handshake responses (excerpt)"
protocol.writeAuthenticationOk(writer) catch return HandshakeError.InvalidStartup;

for (status_pairs) |pair| {
    protocol.writeParameterStatus(writer, pair.key, pair.value) catch return HandshakeError.InvalidStartup;
}

protocol.writeReadyForQuery(writer, 'I') catch return HandshakeError.InvalidStartup;
```

## Key internal helpers

- `duplicateParameters(alloc, params) ![]protocol.Parameter` deep-copies startup parameters and frees partially-constructed output on error.

```zig title="duplicateParameters (excerpt)"
fn duplicateParameters(alloc: std.mem.Allocator, params: []protocol.Parameter) ![]protocol.Parameter {
    const out = try alloc.alloc(protocol.Parameter, params.len);
    var idx: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < idx) : (i += 1) {
            alloc.free(@constCast(out[i].key));
            alloc.free(@constCast(out[i].value));
        }
        alloc.free(out);
    }
    while (idx < params.len) : (idx += 1) {
        out[idx] = .{
            .key = try alloc.dupe(u8, params[idx].key),
            .value = try alloc.dupe(u8, params[idx].value),
        };
    }
    return out;
}
```
