---
sidebar_position: 2
title: src/sydra/query/common.zig
---

# `src/sydra/query/common.zig`

## Purpose

Defines shared low-level utilities used throughout the sydraQL pipeline.

## Public API

### `pub const Span`

Represents a half-open byte range `[start,end)` into the original query text.

Methods:

- `Span.init(start, end)` – constructor
- `Span.width()` – length in bytes (clamped to `0` if invalid)
- `Span.clamp(len)` – clamps the span to a buffer length

