---
sidebar_position: 1
title: src/sydra/storage/wal.zig
---

# `src/sydra/storage/wal.zig`

## Purpose

Implements a simple write-ahead log (WAL) for crash safety.

The engine appends every ingested point to the WAL before it is flushed into segments.

## Record format (WAL v0)

Each record is:

```
[len:u32][type:u8][series_id:u64][ts:i64][value:f64bits][crc32:u32]
```

- `len` is the byte length of the payload (`type..value`), little-endian.
- `type` currently uses:
  - `1` = Put
- `crc32` is computed over the payload.

## Public API

### `pub const WAL = struct { ... }`

Key fields:

- `dir: std.fs.Dir` – open handle to the data directory
- `fsync: cfg.FsyncPolicy` – fsync policy (always/interval/none)
- `file: std.fs.File` – current WAL file handle (`wal/current.wal`)
- `bytes_written: usize` – tracked to trigger rotation

### `pub fn open(alloc, data_dir, policy) !WAL`

- Ensures `wal/` exists under `data_dir`.
- Opens `wal/current.wal` for read/write, creating it if missing.
- Seeks to end and initializes `bytes_written` based on the existing file length.

### `pub fn append(self, series_id: u64, ts: i64, value: f64) !u32`

Appends a single Put record:

- Payload is encoded as:
  - `type` byte (`1`)
  - `series_id` (`u64`, little-endian)
  - `ts` (`i64`, little-endian)
  - `value` as raw IEEE754 bits (`u64`, little-endian)
- Appends `crc32(payload)` after the payload.
- Applies fsync depending on `fsync` policy:
  - `always` calls `file.sync()`
  - `interval` and `none` do not sync here

Returns the total bytes written for the record.

```zig title="append record encoding (excerpt)"
pub fn append(self: *WAL, series_id: u64, ts: i64, value: f64) !u32 {
    var buf: [1 + 8 + 8 + 8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try w.writeByte(1); // type = Put
    try w.writeInt(u64, series_id, .little);
    try w.writeInt(i64, ts, .little);
    const uv: u64 = @bitCast(value);
    try w.writeInt(u64, uv, .little);

    const payload = fbs.getWritten();

    // [u32 payload_len][payload][u32 crc32(payload)]
    // ...
}
```

### `pub fn rotateIfNeeded(self: *WAL) !void`

When `bytes_written >= 64 MiB`:

- Closes the current file.
- Renames `wal/current.wal` to `wal/<epoch_ms>.wal`.
- Creates a new `wal/current.wal`.
- Resets `bytes_written`.

### `pub fn replay(self: *WAL, alloc: std.mem.Allocator, ctx: anytype) !void`

Replays all `.wal` files in `wal/`, in filename sort order with `current.wal` forced to be last.

Replay contract:

- `ctx` must provide:
  - `onRecord(series_id: types.SeriesId, ts: i64, value: f64) !void`
- Corruption checks include:
  - Short reads
  - Payload length bounds (rejects `0` and `> 1<<20`)
  - CRC32 mismatch

```zig title="replay corruption checks (excerpt)"
const payload_len = std.mem.readInt(u32, &len_buf, .little);
if (payload_len == 0 or payload_len > (1 << 20)) return error.CorruptWal;

try readExact(reader, payload);
try readExact(reader, crc_buf[0..4]);

const expected_crc = std.mem.readInt(u32, &crc_buf, .little);
var crc = std.hash.Crc32.init();
crc.update(payload);
if (crc.final() != expected_crc) return error.CorruptWal;
```
