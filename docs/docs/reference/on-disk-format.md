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
- `objects/packs/*.rev` – reverse indexes that preserve physical pack object order
- `objects/packs/*.manifest` – per-pack manifests with checksums and per-type object counts
- `objects/info/store-format` – repository-wide storage format marker and feature defaults
- `objects/info/repository-id` – stable repository identity used by local bundle/fetch/push workflows
- `objects/info/alternates` – optional list of borrowed local repositories searched after local object lookup
- `objects/info/pack-inventory` – active pack inventory with pack paths, BLAKE3 digests, and object counts used by thin bundle/apply planning
- `objects/info/multi-pack-index` – optional pack-set fanout index across all active packs
- `objects/info/commit-graph` – optional commit ancestry side index with generation numbers and logical changed-path Bloom filters
- `objects/info/reachability-bitmap` – optional ref-keyed reachable-object side index for CAS maintenance fast paths
- `objects/info/object-refs` – optional explicit child-edge index keyed by object id for GC/fsck/bitmap refresh
- `objects/cruft/<timestamp>/...` – quarantined unreachable CAS content retained until the GC grace window expires
- `refs/` – loose compatibility refs and reflogs for pre-migration repositories
- `reftable/` – append-only reftable stack for migrated/new repository refs and reflogs
  - `tables.list` – ordered active reftable stack
  - `state` – monotonic next-update counter for update-indexed table naming
  - `<min_update>-<max_update>.table` – update-indexed reftable files, including tombstones when refs are deleted
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
- `objects/info/store-format` version 2 marks repositories that default to the reftable ref backend and CAS-primary startup; version 1 remains the compatibility format for pre-migration repositories.
- `objects/info/multi-pack-index` provides an optional cross-pack fanout table so lookups can resolve mixed pack sets without scanning every individual `.idx` file first. Version 2 also records whether each active pack has a reverse index sidecar.
- `objects/info/object-refs` records typed object-to-child edges explicitly, so reachability, `fsck`, and bitmap refresh no longer need to infer every edge by reparsing arbitrary blob payloads.
- `objects/info/reachability-bitmap` caches the exact reachable object-id set for the current sorted ref snapshot, so `cas pack`, bundle selection, and non-reflog reachability checks can fall back to a side index instead of walking the full DAG every time.
- The current implementation stores whole objects in packs; it does not use delta compression.
- `cas pack` writes an additional pack/index/manifest set for the currently reachable loose object set, refreshes `objects/info/multi-pack-index`, and removes redundant loose copies for the newly packed objects without pruning older active packs.
- `cas gc --apply` preserves unreachable content by first copying active pack files and sealing unreachable loose objects into `objects/cruft/<timestamp>/packs/*.pack`, then pruning older cruft directories after the configured grace window.

Current typed metadata payloads include:

- segment descriptors with a canonical `segment_root` tree id, compatibility `ContentRef`, and optional mirror paths for exported `.seg` files
- tag snapshots
- series catalog snapshots
- WAL indexes with a canonical `journal_root` tree id, compatibility `ContentRef`, optional mirror names, and captured byte counts for mutable `current.wal`
- checkpoint-state blobs with per-series replay high-water and the ordered WAL capture set for the commit
- tree objects and commit objects that link the metadata DAG together

Native segment roots now store:

- a `meta` blob with series/hour/count/range/codec metadata plus optional selector strings
- a `blocks/` tree keyed by logical block number
- per-block trees containing `stats`, `ts`, and `values` entries
- `ts` and `values` payloads chunked into extent trees with 64 KiB leaf blobs by default

Native journal roots now store:

- a `meta` blob with file size and frame count
- a `frame_index` blob that records WAL frame offsets and lengths
- a `frames/` tree of immutable blob-backed WAL frames in replay order

`ContentRef` currently supports:

- `blob(<object id>)` for legacy compatibility payloads
- `extent_tree { root_id, size_bytes, chunk_bytes }` for chunked segment and WAL content stored as Merkle trees of chunk blobs

See [`src/sydra/storage/manifest.zig`](./source/sydra/storage/manifest.md) for the in-memory model and load/save behavior.

## Snapshot/restore

`snapshot`/`restore` now operate on CAS bundles instead of directory-copying the live data directory.

A bundle directory currently contains:

- `bundle.manifest` – versioned bundle manifest with exported refs, prerequisite commits, repository-format metadata, preserved pack paths, and copied ref metadata files
- bundle manifests version 3 carry the source repository id and any borrowed local repositories referenced by the source bundle
- bundle manifests version 4 additionally record pack digests/object counts and prerequisite refs so apply/fetch can skip packs already present in the destination
- `objects/` – bundle-local reachable loose objects plus preserved active pack/index/manifest files
- `objects/packs/*.pack`, `*.idx`, `*.manifest` – immutable active-pack payloads plus indexes and manifests copied directly from the source repository
- `objects/info/*` – copied store-format and side-index files when present
- `reftable/` – copied reftable stack snapshot for migrated repositories
- `refs/` and `logs/refs/` – copied loose refs/reflogs for compatibility repositories

Operational notes:

- `snapshot` is a thin wrapper over `cas bundle create <dst_dir>`.
- `restore` is a thin wrapper over `cas bundle apply <src_dir>`.
- Applying a bundle now preserves pack files and ref metadata directly instead of re-inserting every object through the loose-object path.
- Restoring a bundle reapplies `objects/`, `objects/info/*`, and whichever ref backend snapshot (`reftable/` or loose `refs/`) the bundle was created from; it still does not recreate `MANIFEST`, `tags.json`, or `series_catalog.jsonl` unless an explicit CAS export command is run afterward.
- Borrowed repositories are configured through `objects/info/alternates`; object lookup stays local-first and falls back to borrowed repositories only when a local object is missing.
- Incremental bundles list prerequisite commits in `bundle.manifest`; `cas bundle apply` rejects them unless the destination store already contains those prerequisite objects.
- Bundle apply now skips pack copies when the destination already has the same pack path and digest, then rebuilds local side indexes after the merge instead of trusting copied commit-graph or bitmap state blindly.

## Integrity and cleanup

- `cas fsck` is reflog-aware by default, so commits only referenced by reflogs are still considered reachable.
- `objects/info/commit-graph` version 2 stores fixed-width Bloom filters for logical metadata paths such as `metadata/segments`, `metadata/tags`, `metadata/series_catalog`, and `wal/*`.
- Active packs now carry adjacent `.manifest` files with per-type object counts and pack checksums; `cas fsck` validates those manifests before trusting mixed-pack reachability.
- Reftable writes now use update-indexed table names, a persisted `reftable/state` counter, and block-indexed v3 tables with separate ref and reflog block indexes plus a footer checksum. Readers remain compatible with older flat v1/v2 tables and rewrite them into the current format during compaction or upgrade.
- `cas fsck --repair` only rebuilds derivable metadata: active-pack reverse indexes and manifests, `objects/info/*` side indexes, and `reftable/state` plus `reftable/tables.list`. It never rewrites commit, tree, or blob payloads.
- `cas fsck --connectivity-only` limits validation to refs, reflogs, reachable objects, commit-graph consistency, and dangling detection.
- `cas fsck --lost-found` writes dangling commit/blob/tree ids into `lost-found/`.
- `cas gc --no-reflogs` ignores reflog protection when deciding what is unreachable.
- `cas expire` applies the policy-only maintenance phase: reflog trimming, checkpoint-ref expiry, and optional borrowed-object materialization from `objects/info/alternates` into local storage.
- `cas prune` only deletes previously quarantined cruft directories after the grace window and removes stale mirror files; it does not create new cruft packs.
- `cas vacuum` runs `fsck`, optional repair, policy expiry/materialization, reachable-object repack, and then `cas gc` with the configured prune grace period.

See also:

- [Configuration](./configuration.md) (`data_dir`, retention)
- [Source: engine orchestration](./source/sydra/engine.md) (flush, compaction, retention triggers)
