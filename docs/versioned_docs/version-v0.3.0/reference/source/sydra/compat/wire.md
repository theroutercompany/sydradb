---
sidebar_position: 8
title: src/sydra/compat/wire.zig
---

# `src/sydra/compat/wire.zig`

## Purpose

Module aggregator for the Postgres wire-protocol (“pgwire”) server implementation.

## Public API

Re-exports submodules:

- `pub const protocol` → `wire/protocol.zig`
- `pub const session` → `wire/session.zig`
- `pub const server` → `wire/server.zig`

## Code excerpt

```zig title="src/sydra/compat/wire.zig"
pub const protocol = @import("wire/protocol.zig");
pub const session = @import("wire/session.zig");
pub const server = @import("wire/server.zig");
```
