---
sidebar_position: 9
---

# Alpha reset snapshot

This page records the current alpha realignment at the documentation level. It exists because remote GitHub issue mutation is not available from this environment, so the repo needs a local record of the intended cleanup.

## Close now

- `#8` Decide concurrency model
- `#14` Time index v0
- `#44` Minor Release M1

## Partial / rewrite

- storage/runtime: `#6`, `#7`, `#26`, `#27`, `#30`, `#33`, `#43`, `#45`
- sydraQL/query: `#47`-`#53`
- PostgreSQL compatibility: `#54`-`#57`
- ops/release/perf: `#4`, `#10`, `#34`, `#35`, `#37`, `#46`, `#60`, `#61`

## Deferred

- `#9`, `#23`, `#24`, `#25`, `#28`, `#29`, `#31`, `#32`, `#36`, `#38`, `#58`, `#70`

## Current product statement

SydraDB alpha is a single-node time-series database with HTTP ingest, HTTP range queries, compiled sydraQL as the default execution path for the supported subset, CAS-backed snapshot/bundle/maintenance workflows, and a preview PostgreSQL wire surface.
