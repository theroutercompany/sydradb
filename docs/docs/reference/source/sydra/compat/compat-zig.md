---
sidebar_position: 2
title: src/sydra/compat.zig
---

# `src/sydra/compat.zig`

## Purpose

Acts as a single import point for SydraDB’s PostgreSQL compatibility layer, re-exporting submodules under a stable namespace.

## Public API

This file exports module aliases:

- `pub const stats` → `compat/stats.zig`
- `pub const sqlstate` → `compat/sqlstate.zig`
- `pub const clog` → `compat/log.zig`
- `pub const fixtures.translator` → `compat/fixtures/translator.zig`
- `pub const catalog` → `compat/catalog.zig`
- `pub const wire` → `compat/wire.zig`

Notes:

- The alias is named `clog` to avoid colliding with `std.log` usage elsewhere.

