---
sidebar_position: 1
title: Codec overview (src/sydra/codec)
---

# Codec overview (`src/sydra/codec/*`)

This directory contains encoding/compression helpers used by on-disk formats (notably segments).

Current usage:

- `src/sydra/storage/segment.zig` v1 (`SYSEG2`) uses:
  - timestamp codec `1` → `src/sydra/codec/gorilla.zig.encodeTsDoD`
  - value codec `1` → `src/sydra/codec/gorilla.zig.encodeF64`

Important: several codec modules are currently placeholders/stubs.

## Modules

- `src/sydra/codec/gorilla.zig` – delta-of-delta timestamps + Gorilla-like float XOR encoding
- `src/sydra/codec/bitpack.zig` – bit-packing stub
- `src/sydra/codec/rle.zig` – run-length encoding stubs
- `src/sydra/codec/zstd.zig` – placeholder zstd wrapper (currently returns empty slices)

## Code excerpt (integration point)

Segments currently hard-code codec IDs `1` and dispatch directly to Gorilla helpers:

```zig title="src/sydra/storage/segment.zig (codec bytes + encoder calls)"
try writer.writeByte(1); // ts codec: 1=dod-zzvar
try writer.writeByte(1); // val codec: 1=gorilla-xor

try @import("../codec/gorilla.zig").encodeTsDoD(writer, points[0].ts, points);

var vals = try alloc.alloc(f64, points.len);
defer alloc.free(vals);
for (points, 0..) |p, i| vals[i] = p.value;
try @import("../codec/gorilla.zig").encodeF64(writer, vals);
```
