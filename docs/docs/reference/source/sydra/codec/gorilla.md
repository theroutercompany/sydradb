---
sidebar_position: 2
title: src/sydra/codec/gorilla.zig
---

# `src/sydra/codec/gorilla.zig`

## Purpose

Implements two byte-oriented encodings inspired by Facebook’s Gorilla time-series compression paper:

1. **Timestamp delta-of-delta** encoded as ZigZag varints.
2. **Float64 XOR** encoding with per-value markers and variable payload size (byte-aligned for simplicity).

This codec is used by `src/sydra/storage/segment.zig` for the `SYSEG2` segment format.

## Public API

### Timestamp codec: delta-of-delta (DoD)

#### `pub fn encodeTsDoD(writer, start_ts: i64, points: []const types.Point) !void`

Encodes one varint per point:

- `prev_ts` starts at `start_ts`
- `prev_delta` starts at `0`
- For each point `p`:
  - `delta = p.ts - prev_ts`
  - `dod = delta - prev_delta`
  - encode `dod` as ZigZag varint and write it
  - update `prev_ts = p.ts`, `prev_delta = delta`

Practical note: in the segment writer, `start_ts` is typically `points[0].ts`, making the first `dod` value `0`.

#### `pub fn decodeTsDoD(alloc, reader, count: usize, start_ts: i64) ![]i64`

Decodes `count` timestamps:

- reads `count` ZigZag varints as `dod`
- reconstructs `delta` and `ts` with the same recurrence as the encoder
- returns an allocator-owned `[]i64`

Callers must `alloc.free()` the returned slice.

### Float codec: Gorilla-like XOR (byte aligned)

Encoding uses a 1-byte marker per value:

- `2` = first value written raw as 8 bytes
- `0` = same as previous value
- `1` = changed: XOR payload written

#### `pub fn encodeF64(writer, values: []const f64) !void`

- For index `0`, writes marker `2` + raw `u64` bits (little-endian).
- For subsequent values:
  - `x = bits ^ prev_bits`
  - if `x == 0`: writes marker `0`
  - else:
    - computes `lz = clz(x)`, `tz = ctz(x)`
    - computes significant bits: `sig_bits = 64 - lz - tz`
    - writes marker `1`, then:
      - `[lz:u8][tz:u8][nbytes:u8]`
      - `payload` as `nbytes` little-endian bytes, where `payload = x >> tz`

#### `pub fn decodeF64(alloc, reader, count: usize) ![]f64`

Decodes `count` values:

- marker `2`: reads raw 8-byte little-endian bits, sets `prev_bits`
- marker `0`: repeats `prev_bits`
- marker `1`:
  - reads `lz` (ignored by the current implementation), `tz`, `nbytes`
  - reads `nbytes` little-endian payload bytes
  - reconstructs `x = payload << tz`
  - `bits = prev_bits ^ x`

Returns an allocator-owned `[]f64` slice (caller frees).

## Key internal helpers

### ZigZag + varints

- `encodeZigZagVarint(buf: []u8, v: i64) usize`
  - 7-bit varint encoding with MSB continuation bit.
- `decodeZigZagVarint(reader) !i64`
  - reads bytes until a non-continuation byte.
- `zigZagEncode(v: i64) u64` and `zigZagDecode(uv: u64) i64`

### IO

- `readByte(reader) !u8` forwards to `reader.readByte()`.

## Tests

- `test "zigzag encode/decode round-trip"`
- `test "encodeTsDoD/decodeTsDoD preserves timestamps"`

