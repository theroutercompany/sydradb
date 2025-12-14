---
sidebar_position: 5
---

# On-disk format (as implemented)

SydraDB persists state under `data_dir` (default `./data`), using a small set of files/directories.

For module-level details, see:

- `Reference/Source Reference/src/sydra/storage/wal.zig`
- `Reference/Source Reference/src/sydra/storage/segment.zig`
- `Reference/Source Reference/src/sydra/storage/manifest.zig`
- `Reference/Source Reference/src/sydra/storage/tags.zig`
- `Reference/Source Reference/src/sydra/storage/object_store.zig`
- `Reference/Source Reference/src/sydra/snapshot.zig`

## Directory layout

Under `data_dir`, the engine uses:

- `MANIFEST` – manifest of segment entries (per series + hour bucket)
- `wal/` – write-ahead log files
  - `current.wal`
  - rotated `*.wal` files named by epoch millis
- `segments/<hour_bucket>/*.seg` – per-series, per-hour segment files
- `tags.json` – tag index snapshot
- `objects/<prefix>/<hex>` – content-addressed object store (used by some subsystems)

## WAL format (v0)

WAL files are append-only streams of records.

Each record is encoded as:

```
[len:u32][type:u8][series_id:u64][ts:i64][value:f64bits][crc32:u32]
```

Notes:

- `len` is the payload byte length (`type..value`) and is little-endian.
- `type` currently uses:
  - `1` = Put
- `series_id`, `ts`, and `value_bits` are little-endian.
- `crc32` is computed over the payload (`type..value`) and stored little-endian.

Replay order:

- All `*.wal` files under `wal/` are replayed in filename sort order, with `current.wal` forced to replay last.

## Segment format

Segment files store points for a single `(series_id, hour_bucket)` group.

### v1: `SYSEG2`

Header:

```
[magic:6 "SYSEG2"]
[series_id:u64][hour:i64][count:u32]
[start_ts:i64][end_ts:i64]
[ts_codec:u8][val_codec:u8]
```

Default codecs written by the engine:

- `ts_codec = 1` – delta-of-delta + ZigZag varint (`src/sydra/codec/gorilla.zig.encodeTsDoD`)
- `val_codec = 1` – Gorilla-style XOR encoding (`src/sydra/codec/gorilla.zig.encodeF64`)

### v0: `SYSEG1` (back-compat)

- Timestamp deltas encoded as ZigZag varints
- Values encoded as raw `f64` bits

## Manifest

The manifest tracks segment entries and is used to:

- find candidate segments during range queries
- build per-series “highwater marks” during WAL recovery (so old WAL points aren’t duplicated)

See `Reference/Source Reference/src/sydra/storage/manifest.zig` for the in-memory model and load/save behavior.

## Snapshot/restore

The snapshot mechanism is a directory copy of:

- `MANIFEST`
- `wal/`
- `segments/`
- `tags.json`

See `Reference/Source Reference/src/sydra/snapshot.zig`.
