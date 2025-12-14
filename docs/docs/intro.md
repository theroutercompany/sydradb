---
sidebar_position: 1
---

# SydraDB

SydraDB is a database engine written in Zig.

## Repository orientation

- Runtime entrypoint: `src/main.zig`
- Core orchestration: `src/sydra/`
  - Storage: `src/sydra/storage/`
  - Query: `src/sydra/query/`
  - Codec: `src/sydra/codec/`
- CLI tooling: `cmd/`
- Demos: `examples/`
- Tests and fixtures: `tests/`, `data/`

## Build & test (from repo root)

```sh
zig build
zig build test
```

## Next

- Getting started: see `Getting Started/Quickstart` in the sidebar.
- Configuration and CLI: see `Reference`.
