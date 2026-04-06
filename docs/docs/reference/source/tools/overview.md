---
sidebar_position: 1
title: tools overview (tools)
---

# `tools` overview (`tools/*`)

This directory contains developer tools used for profiling, benchmarking, and diagnostics.

Current contents:

- `tools/bench_alloc.zig` – concurrent ingest benchmark with allocator and queue metrics reporting
- `tools/bench_sydraql.zig` – compiled sydraQL benchmark covering constant reads, scans, grouped aggregates, selector tag reads, and fallback visibility
- `tools/bench_cas.zig` – CAS lifecycle benchmark covering bundle/create/apply, upgrade/fsck/vacuum, and local clone/fetch/push flows
