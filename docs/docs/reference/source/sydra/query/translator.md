---
sidebar_position: 18
title: src/sydra/query/translator.zig
---

# `src/sydra/query/translator.zig`

## Purpose

Provides a string-based SQL → sydraQL translation layer for the PostgreSQL compatibility surface.

This is not a full SQL parser; it uses case-insensitive substring searches and simple parenthesis matching.

## Public API

### `pub const Result = union(enum)`

- `success: { sydraql: []const u8 }`
- `failure: { sqlstate: []const u8, message: []const u8 }`

### `pub fn translate(alloc: std.mem.Allocator, sql: []const u8) !Result`

Recognized patterns include:

- `SELECT 1`
- simple `SELECT <cols> FROM <table> [WHERE <cond>]`
- `INSERT INTO <table> [(cols)] VALUES (...) [RETURNING ...]`
- `UPDATE <table> SET ... [WHERE ...] [RETURNING ...]`
- `DELETE FROM <table> [WHERE ...] [RETURNING ...]`

On success:

- Produces a sydraQL string and records translation stats via `compat.clog.global().record(...)`.

On unsupported inputs:

- Returns `failure` with a SQLSTATE payload (feature-not-supported) and records a fallback.

