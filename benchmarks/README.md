# Benchmark Suite

This directory holds the reproducible benchmark assets for the `v0.4.0` alpha release.

Current entrypoints:

- `zig build bench-alloc -- --ops 10000 --concurrency 4 --series 1`
- `zig build bench-alloc -- --ops 10000 --concurrency 4 --series 100`
- `zig build bench-alloc -- --ops 10000 --concurrency 4 --series 10000`
- `zig build bench-sydraql -- --points-per-series 32 --iterations 5`
- `zig build bench-cas`

The scenario files under `benchmarks/*/scenarios.json` are the checked-in contract for what we intend to measure and publish.

The summary file `benchmarks/v0.4.0-summary.md` captures one concrete run on a reference machine, including the commands used and the observed outputs.
