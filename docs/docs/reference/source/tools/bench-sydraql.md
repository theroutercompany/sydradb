---
title: tools/bench_sydraql.zig
---

# `tools/bench_sydraql.zig`

Compiled sydraQL benchmark harness for the `v0.4.0` alpha cycle.

Example:

```sh
zig build bench-sydraql -- --points-per-series 32 --iterations 5
```

The harness prints dataset-level ingest details and one line per query scenario with parse/validate/bind/compile/logical/optimize/physical/pipeline timings plus fallback counts.
