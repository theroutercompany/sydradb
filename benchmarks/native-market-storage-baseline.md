# Native Market Storage Benchmark Baseline

Reference run date: **July 27, 2026**

Reference environment:

- OS: Darwin 25.5.0, arm64
- Toolchain: Zig 0.15.1 through `nix develop`
- Build mode: `ReleaseSafe`

This harness establishes the `fanout_v1` evidence contract before native market
segments are available. Each logical market row is persisted as one scalar
write per ordered column. The JSON-lines output keeps logical rows, physical
writes, storage bytes, and projected-query latency in the same record so a
later gate evaluator can compare `fanout_v1` and `native_v1` without changing
denominators.

## Commands

Smoke-sized defaults:

```sh
nix develop -c zig build bench-market-storage-smoke
nix develop -c zig build bench-market-storage -- --fsync none
```

Scale runs:

```sh
nix develop -c zig build bench-market-storage -- --rows 100000 --query-iterations 9 --fsync none
nix develop -c zig build bench-market-storage -- --rows 1000000 --query-iterations 9 --fsync none
nix develop -c zig build bench-market-storage -- --rows 100000 --query-iterations 9 --fsync always
```

Individual scenarios can be selected with `--scenario trade`, `--scenario
quote`, or `--scenario synthetic_8`. The `--batch-rows` flag controls logical
rows per ingest batch.

## Measurement Contract

- `--fsync` accepts `none`, `interval`, or `always`; the selected policy is
  recorded in every schema-version-2 JSONL record.
- `ingest_or_drain_logical_rows_per_second` and
  `ingest_or_drain_elapsed_ns` cover enqueue, writer drain, and final flush.
  `logical_rows_per_second` remains a compatibility alias with its scope
  declared in `measurement`.
- `durable_elapsed_ns` and `durable_logical_rows_per_second` are emitted only
  for `fsync=always`, where each acknowledged WAL append is synchronized.
- `fsync=none` and `fsync=interval` results make no crash-durability claim.
- `enqueue_logical_rows_per_second` isolates producer-side submission.
- `physical_writes` is the engine-confirmed scalar write count; it must equal
  logical rows multiplied by ordered columns for the fanout baseline.
- `wal_bytes` sums regular files beneath the generated `wal` directory.
  `wal_payload_bytes` retains the engine append-byte counter for diagnosing
  framing and registration overhead.
- `segment_bytes` sums regular files beneath the generated `segments`
  directory after the final flush.
- `storage_bytes` is `wal_bytes + segment_bytes` and is the input to the
  native-versus-fanout footprint gate.
- Query latency covers one complete projected read across four label series.
  One unmeasured warm-up precedes the measured iterations.
- The current scalar reader does not expose decoder input bytes.
  `bytes_decoded` is therefore `null`; `returned_point_bytes_estimate` reports
  selected scalar points multiplied by `sizeof(types.Point)`.
- `peak_resident_estimate_bytes` is the memtable limit plus the observed queue
  pending-byte high-water, capped by the configured memory limit. It is an
  engine-accounting upper bound rather than process RSS.

## Smoke Evidence

Command:

```sh
nix develop -c zig build bench-market-storage-smoke -Doptimize=ReleaseSafe
```

Policy: `fsync=none`; completion scope: `ingest_or_drain`.

| Scenario | Ingest/drain rows/s | Physical writes | WAL bytes | Segment bytes | Storage bytes | Query p50 ms | Query p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `trade` | 437,607 | 512 | 17,490 | 3,946 | 21,436 | 0.483 | 0.497 |
| `quote` | 282,249 | 1,024 | 34,996 | 7,904 | 42,900 | 0.962 | 0.979 |
| `synthetic_8` | 146,453 | 2,048 | 70,264 | 16,068 | 86,332 | 0.970 | 1.007 |

Each scenario used 256 logical rows, four label series, three measured query
iterations, and 64-row ingest batches. The engine-confirmed physical write
counts matched `logical_rows * ordered_columns` in all cases.

Performance acceptance gates belong to repeated 100K and 1M scale runs; smoke
validates schema, accounting invariants, output, flush, and projected reads.

## Scale-Path Validation

The eight-column path was also exercised at 100K logical rows with three
projected-query iterations and 1,024-row ingest batches. The run completed
800,000 physical scalar writes, returned 200,000 projected points per query,
and emitted a valid schema-version-2 result. This is a harness scalability
check; the recorded value is not a promotion baseline because it is a single
run.

## Known Gaps

- Native storage results and fanout/native ratio gates remain pending the native
  writer and reader.
- Decoder input-byte accounting needs an instrumentation counter in the native
  block reader.
- Peak process RSS requires a portable process sampler; the current field is an
  explicit storage-engine upper-bound estimate.
