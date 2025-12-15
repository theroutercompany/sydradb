---
sidebar_position: 2
title: src/sydra/compat.zig
---

# `src/sydra/compat.zig`

## Purpose

Acts as a single import point for SydraDB’s PostgreSQL compatibility layer, re-exporting submodules under a stable namespace.

## Public API

This file exports module aliases:

- `pub const stats` → [`compat/stats.zig`](./stats.md)
- `pub const sqlstate` → [`compat/sqlstate.zig`](./sqlstate.md)
- `pub const clog` → [`compat/log.zig`](./log.md)
- `pub const fixtures.translator` → [`compat/fixtures/translator.zig`](./fixtures-translator.md)
- `pub const catalog` → [`compat/catalog.zig`](./catalog.md)
- `pub const wire` → [`compat/wire.zig`](./wire.md)

Notes:

- The alias is named `clog` to avoid colliding with `std.log` usage elsewhere.

## Code excerpt

```zig title="src/sydra/compat.zig"
pub const stats = @import("compat/stats.zig");
pub const sqlstate = @import("compat/sqlstate.zig");
pub const clog = @import("compat/log.zig");
pub const fixtures = struct {
    pub const translator = @import("compat/fixtures/translator.zig");
};
pub const catalog = @import("compat/catalog.zig");
pub const wire = @import("compat/wire.zig");
```
