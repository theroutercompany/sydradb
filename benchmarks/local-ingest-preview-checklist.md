# Local Ingest Preview Checklist

Use this checklist before calling the exact-series local ingest socket preview-ready.

## Current Gate Status

Reference state from the latest `zig build bench-preview-gates` run on April 6, 2026:

- transport-bound scenarios pass
- `warm_declared_10k` passes
- `cold_declare_10k` remains the only failing preview gate

## Required Verification

- `nix develop -c zig build test -Doptimize=ReleaseSafe`
- `zig build demo-smoke`
- `zig build bench-smoke`
- `zig build bench-preview-gates`
- `zig build bench-ingest-transport -- --scenario one_hot_one_writer`
- `zig build bench-ingest-transport -- --scenario fanout_four_writers`
- `zig build bench-ingest-transport -- --scenario warm_declared_10k`
- `zig build bench-ingest-transport -- --scenario cold_declare_10k`
- `zig build bench-ingest-transport -- --scenario steady_state_100k`

## Promotion Gates

Transport-bound scenarios:

- `one_hot_one_writer`
- `fanout_four_writers`
- `steady_state_100k`

Required:

- warm UDS stays within 25% of direct-engine throughput
- warm UDS beats live HTTP by at least 1.5x

Storage-bound scenarios:

- `warm_declared_10k`
- `cold_declare_10k`

Required:

- warm/cold UDS stays within 10% of direct-engine throughput
- live HTTP remains a reference number, not a promotion blocker

## Correctness Checklist

- live HTTP multiline ingest still passes
- live HTTP `Expect: 100-continue` uploads still pass
- socket handshake/version/declaration/unknown-decl/timeout tests still pass
- socket-only and combined HTTP+socket demos still pass
- concurrent live HTTP fanout smoke still passes
- market-row ingest is still documented as HTTP-only

## Source Of Truth

- benchmark commands and scenario contract: [`benchmarks/README.md`](/Users/rexliu/sydradb/benchmarks/README.md)
- transport summary and gate readout: [`benchmarks/v0.4.0-ingest-transport-summary.md`](/Users/rexliu/sydradb/benchmarks/v0.4.0-ingest-transport-summary.md)
- operator/runtime contract: [`docs/docs/reference/local-ingest.md`](/Users/rexliu/sydradb/docs/docs/reference/local-ingest.md)
