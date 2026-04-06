# Benchmark Suite

This directory holds the reproducible benchmark assets for the `v0.4.0` alpha release.

Current entrypoints:

- `zig build bench-alloc -- --ops 10000 --concurrency 4 --series 1`
- `zig build bench-alloc -- --ops 10000 --concurrency 4 --series 100`
- `zig build bench-alloc -- --ops 10000 --concurrency 4 --series 10000`
- `zig build bench-sydraql -- --points-per-series 32 --iterations 5`
- `zig build bench-cas`
- `zig build bench-ingest-transport -- --scenario one_hot_one_writer`
- `zig build bench-ingest-transport -- --scenario fanout_four_writers`
- `zig build bench-ingest-transport -- --scenario warm_declared_10k`
- `zig build bench-ingest-transport -- --scenario cold_declare_10k`
- `zig build bench-ingest-transport -- --scenario steady_state_100k`
- `zig build bench-preview-gates`

The scenario files under `benchmarks/*/scenarios.json` are the checked-in contract for what we intend to measure and publish.

The summary files [`benchmarks/v0.4.0-summary.md`](/Users/rexliu/sydradb/benchmarks/v0.4.0-summary.md) and [`benchmarks/v0.4.0-ingest-transport-summary.md`](/Users/rexliu/sydradb/benchmarks/v0.4.0-ingest-transport-summary.md) capture checked-in reference runs, including the commands used and the observed outputs.
