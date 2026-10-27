---
title: "ADR 0008: Native Market Storage"
sidebar_position: 8
---

# ADR 0008: Native Market Storage

## Status

Accepted for implementation.

## Delivery status

This ADR fixes the native market storage contracts across two delivery phases.

Phase 1 has locked and tested the reusable storage primitives:

- market-series identity, schema validation, and collision-checked catalog
  persistence
- WAL Type 3 and Type 4 codecs and frame parsing
- columnar market-memtable behavior
- the `SYMKT1` local segment reader, writer, validation, and golden-byte fixture

Phase 2 connects those primitives to the production engine:

- tagged writer batches, writer-assigned sequences, and registration-ordered
  recovery
- native ingest, query, projection, shadow comparison, and derived execution
- CAS market roots, snapshot reachability, repository-format guards, and
  revision queries
- compaction, migration, verification, and promotion

The format definitions in this ADR are stable inputs to Phase 2. Operational
claims are identified as Phase 2 requirements until that integration and its
acceptance gates are complete.

## Context

Market rows currently fan out each logical column into an independent scalar
series. That representation preserves the scalar engine's behavior, but it
multiplies WAL frames, loses row-level correction atomicity, and forces
multi-column queries to reconstruct rows. Native market storage needs one
durable logical row, column projection, revision-aware CAS reachability, and an
explicit path for format-3 repositories.

This decision builds on the existing CRC-framed WAL in `storage/wal.zig`, the
segment-root and block-cursor model in `storage/segment.zig`, and the snapshot,
object reachability, and atomic ref updates in `storage/cas.zig`.

## Identity and schema contract

`MarketSeriesId` is the seeded-zero XXH64 value of the exact byte sequence:

```text
metric || "|" || canonical_labels_json
```

Labels use the existing canonical JSON object rules from `series_catalog.zig`.
The market-series catalog stores the ID, metric, canonical labels, and schema
digest together. Registration recomputes the ID and compares the stored
identity. An ID already associated with different identity bytes fails with
`MarketSeriesConflict`; callers expose the stable API code
`market_series_conflict`.

Schemas contain a metric, ordered non-null `f64` columns, required labels, and a
storage mapping. They are immutable after registration. The schema digest is
BLAKE3-256 over this domain-separated sequence:

```text
frame("SYDRA_MARKET_SCHEMA_V1")
frame(metric)
u64_le(column_count) || frame(column_0) || ... || frame(column_n)
u64_le(required_label_count) || frame(label_0) || ... || frame(label_n)
frame(storage_mapping)
```

Each `frame(value)` is `u64_le(value.len) || value`. Persisted field order is
therefore significant and architecture-independent. Storage mappings are
`fanout_v1` and `native_v1`. Catalogs whose schema entries omit
`storage_mapping` load as `fanout_v1`.

Configuration accepts:

- `market_storage_mode = auto | fanout_v1 | dual_write_v1 | native_v1`
- `market_storage_read_mode = auto | fanout | shadow | native`

`auto` resolves per schema. Existing schemas retain their persisted mapping.
After Phase 2 promotion, fresh format-4 repositories register new schemas as
`native_v1`. Existing schema mappings change only through the migration and
promotion workflow.

## WAL contract

All integer and floating-point bit fields are little-endian. Frames retain the
existing envelope:

```text
u32 payload_length | payload | u32 crc32(payload)
```

Type 3, `MarketRow`, has this payload:

```text
u8  type = 3
u64 market_series_id
u64 write_sequence
i64 ts_ns
u16 column_count
u64 value_bits[column_count]
```

`value_bits` holds the exact IEEE-754 bits of each ordered `f64`. Column count
must be in `1...4096`, using the shared market-column limit. The framed WAL
payload limit remains 1 MiB.

Type 4, `MarketSeriesRegistration`, has this payload:

```text
u8   type = 4
u64  market_series_id
u8   schema_digest[32]
u32  metric_length
u32  canonical_labels_length
u8   metric[metric_length]
u8   canonical_labels[canonical_labels_length]
```

The Phase 1 parser validates frame CRCs, payload lengths, known type tags, and
the Type 3 column-count limit before dispatching optional market callbacks. It
does not establish production recovery ordering or catalog authority by itself.

Phase 2 engine integration must provide these invariants:

- the writer assigns a repository-wide monotonically increasing sequence
- one Type 3 frame is the durable unit for one logical row
- dual-write appends that frame once, then derives native and fanout memtable
  entries after the append succeeds
- a Type 4 registration precedes the first Type 3 row for its series in total
  WAL order
- recovery validates canonical labels, recomputes the series ID, verifies the
  schema digest against the catalog, and rejects a row lacking a valid
  preceding registration

For `(market_series_id, ts_ns)` corrections, the complete row with the greatest
write sequence wins. Equal sequence and equal row bits are idempotent. Equal
sequence with different row bits is corruption. Phase 2 replay, reads, and
compaction must apply this rule to the entire row.

## `SYMKT1` segment contract

Segments partition one market series by signed UTC hour index. The index is
computed with floor division:

```text
hour_bucket = floor_div(ts_ns, 3_600_000_000_000)
```

Keeping the hour index as an `i64` supports negative timestamps and both `i64`
timestamp endpoints without multiplying the index back into nanoseconds. Rows
are ordered by `(ts_ns, write_sequence)`, and each block contains at most 4,096
rows.

Every integer is little-endian. The file prefix is:

```text
u8  magic[6] = "SYMKT1"
u16 version = 1
u32 header_body_length
u32 header_crc32
```

`header_crc32` covers the header body:

```text
u64 market_series_id
u8  schema_digest[32]
i64 hour_bucket
u64 row_count
i64 start_ts_ns
i64 end_ts_ns
u32 block_rows = 4096
u32 block_count
u32 column_count
u32 metric_length
u32 canonical_labels_length
u8  metric[metric_length]
u8  canonical_labels[canonical_labels_length]
repeated column_count times:
  u32 column_name_length
  u8  column_name[column_name_length]
```

Each block is independently framed:

```text
u8  magic[4] = "MBLK"
u32 block_body_length
u8  block_body[block_body_length]
u32 block_crc32
```

`block_crc32` covers only the block body. The block body is:

```text
u32 row_count
i64 min_ts_ns
i64 max_ts_ns
u32 timestamp_stream_length
u32 sequence_stream_length
u32 fingerprint_stream_length
repeated column_count times:
  u8  bounds_valid
  u64 min_value_bits
  u64 max_value_bits
  u32 value_stream_length
u8 timestamp_stream[timestamp_stream_length]
u8 sequence_stream[sequence_stream_length]
u8 fingerprint_stream[fingerprint_stream_length]
u8 value_streams[column_count][respective value_stream_length]
```

Timestamps use Gorilla delta-of-delta encoding seeded with `min_ts_ns`; the
first encoded delta is zero. Write sequences use absolute canonical unsigned
varints because timestamp order does not imply write-sequence order. Value
streams use Gorilla XOR encoding and preserve every `f64` bit.

The fingerprint stream contains one 32-byte value per row:

```text
BLAKE3(
  "SYDRA_MARKET_ROW_V1"
  || u32_le(column_count)
  || u64_le(value_0_bits)
  || ...
  || u64_le(value_n_bits)
)
```

The fingerprint covers the full row even when a query projects a subset of its
columns. A reader can therefore detect conflicting equal-sequence rows across
segments without decoding unrequested value streams.

Column bounds exclude NaNs. At least one ordered value sets
`bounds_valid = 1` and stores the exact minimum and maximum value bits. An
all-NaN column sets `bounds_valid = 0` and stores zero for both bound fields.

Local mirrors use the `.mseg` suffix. Their content suffix is the first
little-endian `u64` of BLAKE3 over the complete file bytes. Hot segment value
blocks contain binary streams only.

Segment metadata carries a schema digest, though it lacks the required-label
set and storage mapping needed to recompute that digest. Callers validate it
through `validateExpectedSchema` using expected catalog metadata. The catalog
remains the authority for the complete schema identity.

## Phase 2 CAS representation

The canonical `market_segment_root` is a tree containing:

- `meta`: binary segment metadata and ordered column names
- `block_index`: block ranges, counts, stream sizes, and column statistics
- `blocks`: a tree keyed by zero-padded block number

Each block tree contains `stats`, `timestamps`, `sequences`, and `values`.
Timestamp, sequence, and value streams use the existing extent-tree mechanism.
`values` is keyed by zero-padded column ordinal so column names cannot alter
tree path semantics.

Phase 2 snapshots add:

- `metadata/market_series_catalog`
- `metadata/market_segments`

Each market segment descriptor includes series ID, schema digest, hour, time
range, row count, and segment-root object ID. These roots participate in
snapshot, bundle, clone, fetch/push, diff, checkout, fsck, GC, and revision
queries through the same reachability traversal used by scalar segment roots.
Completion requires tests proving each lifecycle path; the Phase 1 local
segment module alone does not make these objects reachable.

## Phase 2 repository format guard

Native market roots require repository format 4. A format-3 repository remains
readable and writable through `fanout_v1`. Explicit native write or read mode
against format 3 fails with `RepositoryFormatMismatch`; it cannot silently use
fanout. A binary supporting format 4 rejects any repository version greater
than 4 before materializing catalogs or segments.

Format 4 initialization and enforcement become active only when Phase 2 CAS and
recovery integration pass their promotion gates. Until then, the repository
format remains 3 and native segment primitives are unconnected to production
repository state. Existing repositories advance through the migration state
machine below after Phase 2 lands.

## Phase 2 migration and promotion

The migration command will persist a CAS-backed state record with these states:

1. `inventory`: enumerate schemas and series; report incomplete timestamps.
2. `building`: reconstruct complete logical rows and write native roots,
   checkpointed after each series and hour.
3. `verifying`: compare native and fanout rows, labels, column order,
   timestamps, and exact numeric bits at the same revision.
4. `ready`: verification passed and a pre-promotion checkpoint ref exists.
5. `promoted`: a format-4 commit contains native descriptors, series catalog,
   and updated schema mappings.
6. `failed`: retain the last durable checkpoint and diagnostic.

`--resume` continues from the last durable schema/series/hour checkpoint.
Reprocessing a completed unit must produce the same content IDs. Missing
columns at a timestamp stop migration and identify metric, canonical labels,
timestamp, and missing columns.

Promotion first creates
`refs/checkpoints/market-storage/pre-v4-<timestamp>`. It then writes one CAS
commit containing format-4 metadata and the mapping updates and atomically
advances the repository's main ref. That ref update is the logical commit
point. The materialized repository-format marker is updated afterward; startup
reconciles an interrupted marker update from the committed main snapshot.
Fanout segments and WAL data remain reachable after promotion.

## Consequences

Phase 1 establishes:

- exact, versioned binary contracts for native WAL records and local segments
- collision-checked series and schema identities
- column projection with full-row fingerprints available for correction
  integrity
- per-header and per-block CRC validation plus content-derived local filenames

Phase 2 must establish:

- one WAL durability boundary for acknowledged native and dual-write rows
- row-atomic corrections across recovery, flush, reads, and compaction
- complete CAS reachability before format-4 promotion
- migration parity and resumability while retaining both representations;
  deleting fanout data requires a separate decision

## Implementation references

- `src/sydra/storage/wal.zig`: CRC frames and Type 3/Type 4 codecs and parsers
- `src/sydra/storage/segment.zig`: Gorilla codecs, segment roots, and block
  cursors
- `src/sydra/storage/cas.zig`: snapshots, extent trees, refs, bundles, fsck, and
  reachability
- `src/sydra/storage/market_identity.zig`: stable ID and schema-digest framing
- `src/sydra/storage/market_catalog.zig`: schema and collision-checked identity
  persistence
- `src/sydra/storage/market_memtable.zig`: columnar row and correction
  primitives
- `src/sydra/storage/market_segment.zig`: `SYMKT1` encoding, projection,
  integrity validation, and golden-byte format fixture
- `src/storage_tests.zig`: aggregate storage contract coverage
