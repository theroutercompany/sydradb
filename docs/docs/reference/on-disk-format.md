---
sidebar_position: 5
tags:
  - storage
  - format
---

# On-disk format (as implemented)

SydraDB persists state under [`data_dir`](./configuration.md#data_dir-string) (default `./data`), using a small set of files/directories.

For module-level details, see:

- [`src/sydra/storage/wal.zig`](./source/sydra/storage/wal.md)
- [`src/sydra/storage/segment.zig`](./source/sydra/storage/segment.md)
- [`src/sydra/storage/manifest.zig`](./source/sydra/storage/manifest.md)
- [`src/sydra/storage/tags.zig`](./source/sydra/storage/tags.md)
- [`src/sydra/storage/object_store.zig`](./source/sydra/storage/object-store.md)
- [`src/sydra/snapshot.zig`](./source/sydra/snapshot.md)

## Directory layout

Under `data_dir`, the engine uses:

- `MANIFEST` – manifest of segment entries (per series + hour bucket)
- `wal/` – write-ahead log files
  - `current.wal`
  - rotated `*.wal` files named by epoch millis
- `segments/<hour_bucket>/*.seg` – per-series, per-hour segment files
- `tags.json` – tag index snapshot
- `objects/<prefix>/<hex>` – loose content-addressed objects
- `objects/packs/*.pack` – immutable packed object containers
- `objects/packs/*.idx` – fanout-based pack indexes for packed objects
- `objects/info/store-format` – repository-wide storage format marker and feature defaults
- `objects/info/multi-pack-index` – optional pack-set fanout index across all active packs
- `objects/info/commit-graph` – optional commit ancestry side index written by CAS maintenance
- `objects/cruft/<timestamp>/...` – quarantined unreachable CAS content retained until the GC grace window expires
- `refs/` – mutable plaintext refs and reflogs for the CAS head/branches/tags/checkpoints
- `lost-found/` – optional fsck output for dangling commit/blob/tree ids

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

See also: [`src/sydra/codec/gorilla.zig`](./source/sydra/codec/gorilla.md).

### v0: `SYSEG1` (back-compat)

- Timestamp deltas encoded as ZigZag varints
- Values encoded as raw `f64` bits

## Manifest

The manifest tracks segment entries and is used to:

- find candidate segments during range queries
- build per-series “highwater marks” during WAL recovery (so old WAL points aren’t duplicated)

When `metadata_read_mode = "primary"` and a CAS head exists, the runtime can rebuild its in-memory manifest, tag index, and series catalog directly from the CAS snapshot without recreating these mirror files on startup. In `cas_mode = "dual_write"`, `MANIFEST`, `tags.json`, and `series_catalog.jsonl` remain compatibility mirrors written by normal flush/maintenance flows and by explicit CAS export commands.

## CAS objects

The CAS layer stores immutable objects addressed by a BLAKE3 hash of `(type, payload)`.

- Loose objects live under `objects/<prefix>/<hex>`.
- Packed objects live in `objects/packs/*.pack` and are indexed by `objects/packs/*.idx`.
- `objects/info/multi-pack-index` provides an optional cross-pack fanout table so lookups can resolve mixed pack sets without scanning every individual `.idx` file first.
- The current implementation stores whole objects in packs; it does not use delta compression.
- `cas pack` writes an additional pack/index pair for the currently reachable loose object set, refreshes `objects/info/multi-pack-index`, and removes redundant loose copies for the newly packed objects without pruning older active packs.
- `cas gc --apply` preserves unreachable content by first copying active pack files and moving loose unreachable objects into `objects/cruft/<timestamp>/`, then pruning older cruft directories after the configured grace window.

Current typed metadata payloads include:

- segment descriptors with a canonical `ContentRef` plus optional mirror paths for exported `.seg` files
- tag snapshots
- series catalog snapshots
- WAL indexes with a canonical `ContentRef`, optional mirror names, and captured byte counts for mutable `current.wal`
- tree objects and commit objects that link the metadata DAG together

`ContentRef` currently supports:

- `blob(<object id>)` for legacy compatibility payloads
- `extent_tree { root_id, size_bytes, chunk_bytes }` for chunked segment and WAL content stored as Merkle trees of chunk blobs

See [`src/sydra/storage/manifest.zig`](./source/sydra/storage/manifest.md) for the in-memory model and load/save behavior.

## Snapshot/restore

`snapshot`/`restore` now operate on CAS bundles instead of directory-copying the live data directory.

A bundle directory currently contains:

- `bundle.manifest` – versioned bundle manifest with exported refs, prerequisite commits for incremental bundles, and object counts
- `objects/` – bundle-local loose and/or packed CAS objects
- `objects/packs/*.pack` and `objects/packs/*.idx` – immutable pack payloads plus fanout indexes
- `refs/` – created by the object-store bootstrap, but ref updates are sourced from `bundle.manifest` during apply

Operational notes:

- `snapshot` is a thin wrapper over `cas bundle create <dst_dir>`.
- `restore` is a thin wrapper over `cas bundle apply <src_dir>`.
- Applying a bundle restores `objects/` and `refs/` only; it does not recreate `MANIFEST`, `tags.json`, or `series_catalog.jsonl` unless an explicit CAS export command is run afterward.
- Incremental bundles list prerequisite commits in `bundle.manifest`; `cas bundle apply` rejects them unless the destination store already contains those prerequisite objects.

## Integrity and cleanup

- `cas fsck` is reflog-aware by default, so commits only referenced by reflogs are still considered reachable.
- `cas fsck --connectivity-only` limits validation to refs, reflogs, reachable objects, commit-graph consistency, and dangling detection.
- `cas fsck --lost-found` writes dangling commit/blob/tree ids into `lost-found/`.
- `cas gc --no-reflogs` ignores reflog protection when deciding what is unreachable.

See also:

- [Configuration](./configuration.md) (`data_dir`, retention)
- [Source: engine orchestration](./source/sydra/engine.md) (flush, compaction, retention triggers)
