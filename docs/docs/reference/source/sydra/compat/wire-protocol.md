---
sidebar_position: 9
title: src/sydra/compat/wire/protocol.zig
---

# `src/sydra/compat/wire/protocol.zig`

## Purpose

Implements a minimal subset of the PostgreSQL startup negotiation plus helpers to write common backend messages.

This file is intentionally low-level: it reads/writes bytes and constructs big-endian length-prefixed pgwire frames.

## Public constants

- `pub const ssl_request_code: u32 = 80877103`
- `pub const cancel_request_code: u32 = 80877102`
- `pub const protocol_version_3: u32 = 3 << 16` (3.0, value `196608`)

## Startup types

### `pub const StartupOptions`

- `allow_ssl: bool = false`

When `allow_ssl` is `false`, SSL requests are explicitly declined.

### `pub const Parameter`

- `key: []const u8`
- `value: []const u8`

### `pub const StartupRequest`

- `protocol_version: u32`
- `parameters: []Parameter = &[_]Parameter{}`
- `ssl_request_seen: bool = false`

Methods:

- `pub fn deinit(self: *StartupRequest, alloc) void`
  - Frees `param.key`, `param.value`, and the `parameters` slice.
- `pub fn find(self: StartupRequest, key: []const u8) ?[]const u8`
  - Linear scan over `parameters`.

## Startup parsing

### `pub fn readStartup(alloc, reader, writer, options) !StartupRequest`

Consumes the Postgres startup negotiation and returns parsed parameters.

Behavior:

- Repeatedly reads frames of:
  - `[len:u32be][body:len-4]`
- If the first 4 bytes of the body equal `ssl_request_code`:
  - writes a single byte response:
    - `'S'` if `options.allow_ssl` (TLS is still “future work”)
    - `'N'` otherwise (current default)
  - continues to read the next frame as the real startup packet.
- If the protocol equals `cancel_request_code`:
  - returns `error.CancelRequestUnsupported`.
- Validates protocol major is 3 (`protocol & 0xFFFF0000 == protocol_version_3`), otherwise `error.UnsupportedProtocol`.
- Parses key/value parameters as NUL-terminated strings until a trailing empty key.
- Duplicates parameter key/value strings into allocator-owned memory.

Key errors surfaced by this function:

- `error.InvalidStartupLength` (len < 8)
- `error.MalformedStartupPacket` (missing NUL terminators, truncation)
- `error.UnsupportedProtocol`
- `error.CancelRequestUnsupported`

```zig title="SSL request handling loop (excerpt)"
while (true) {
    const total_len = try readU32(reader);
    if (total_len < 8) return error.InvalidStartupLength;
    const body_len = total_len - 4;

    var body = try alloc.alloc(u8, body_len);
    defer alloc.free(body);
    try reader.readNoEof(body);

    const protocol = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(body[0..4].ptr)), .big);

    if (protocol == ssl_request_code) {
        try writer.writeAll(if (options.allow_ssl) "S" else "N");
        ssl_seen = true;
        continue;
    }

    if (protocol == cancel_request_code) return error.CancelRequestUnsupported;
    if ((protocol & 0xFFFF0000) != protocol_version_3) return error.UnsupportedProtocol;
    // parse key/value parameters...
    break;
}
```

```zig title="Parameter parsing (excerpt)"
var idx: usize = 4;
while (idx < body.len) {
    const key_end = std.mem.indexOfScalarPos(u8, body, idx, 0) orelse return error.MalformedStartupPacket;
    if (key_end == idx) break; // trailing NUL

    const val_start = key_end + 1;
    if (val_start >= body.len) return error.MalformedStartupPacket;
    const val_end = std.mem.indexOfScalarPos(u8, body, val_start, 0) orelse return error.MalformedStartupPacket;

    const key_slice = body[idx..key_end];
    const value_slice = body[val_start..val_end];
    try appendParameter(alloc, &params, key_slice, value_slice);
    idx = val_end + 1;
}
```

## Message writers

All message writers write a complete backend message in one call.

### `pub fn writeAuthenticationOk(writer) !void`

Writes an AuthenticationOk message:

- Type byte: `'R'`
- Length: `8`
- Auth method: `0` (OK)

### `pub fn writeParameterStatus(writer, key, value) !void`

Writes:

- Type byte: `'S'`
- Payload: `key\0value\0`

### `pub fn writeReadyForQuery(writer, status: u8) !void`

Writes:

- Type byte: `'Z'`
- Payload: single status byte (commonly `'I'` for idle)

### `pub fn writeCommandComplete(writer, tag: []const u8) !void`

Writes:

- Type byte: `'C'`
- Payload: `tag\0`

### `pub fn writeEmptyQueryResponse(writer) !void`

Writes:

- Type byte: `'I'`
- Payload length: `4` (no payload)

### `pub fn writeErrorResponse(writer, severity, code, message) !void`

Writes an `ErrorResponse` with fields:

- `S` (severity)
- `C` (SQLSTATE code)
- `M` (message)

Each field is NUL-terminated; the entire message ends with an extra NUL byte.

```zig title="writeErrorResponse framing (excerpt)"
try writer.writeByte('E');
var length: u32 = 4 + 1; // length field + terminating zero
length += @intCast(severity.len + code.len + message.len + 3);

var buf: [4]u8 = undefined;
std.mem.writeInt(u32, buf[0..4], length, .big);
try writer.writeAll(buf[0..4]);

try writer.writeByte('S');
try writer.writeAll(severity);
try writer.writeByte(0);
try writer.writeByte('C');
try writer.writeAll(code);
try writer.writeByte(0);
try writer.writeByte('M');
try writer.writeAll(message);
try writer.writeByte(0);
try writer.writeByte(0);
```

### `pub fn writeNoticeResponse(writer, message) !void`

Writes a `NoticeResponse` with fields:

- `S = "NOTICE"`
- `M = message`

### `pub fn formatParameters(params: []Parameter, writer) !void`

Formats parameter pairs as `key=value, key=value, ...` (used for debugging/logging).
