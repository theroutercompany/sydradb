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

### `pub fn writeNoticeResponse(writer, message) !void`

Writes a `NoticeResponse` with fields:

- `S = "NOTICE"`
- `M = message`

### `pub fn formatParameters(params: []Parameter, writer) !void`

Formats parameter pairs as `key=value, key=value, ...` (used for debugging/logging).

