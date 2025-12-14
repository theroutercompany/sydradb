---
sidebar_position: 8
title: src/sydra/storage/memtable.zig
---

# `src/sydra/storage/memtable.zig`

## Status

This file currently contains only a placeholder comment:

> Memtable: skiplist by (series_id, ts) → iterator for flush

## Intended role

The runtime engine currently implements its own in-memory memtable as `Engine.MemTable` in `src/sydra/engine.zig`.

This module appears reserved for a future, more advanced memtable implementation (for example a skiplist keyed by `(series_id, ts)`).

