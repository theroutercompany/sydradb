---
sidebar_position: 9
title: src/sydra/tooling.zig
---

# `src/sydra/tooling.zig`

## Purpose

Provides a small “tooling import surface” that re-exports commonly used SydraDB modules for scripts/tools.

## Public API

Re-exports:

- `pub const alloc = @import("alloc.zig")`
- `pub const config = @import("config.zig")`
- `pub const engine = @import("engine.zig")`
- `pub const types = @import("types.zig")`

