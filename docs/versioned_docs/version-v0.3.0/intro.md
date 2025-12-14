---
sidebar_position: 1
---

# SydraDB

SydraDB is a database engine written in Zig.

This documentation site is intended to be both:

- A practical onboarding guide (how to build/run/query)
- A source-linked reference (what each module does and how the system fits together)

## Fast path (first 30 minutes)

1. Build and run: [Quickstart](./getting-started/quickstart)
2. Server surfaces and endpoints: [Running the server](./getting-started/running-the-server)
3. How ingest/query works at the API level: [Ingest and query](./getting-started/ingest-and-query)
4. Configuration knobs (and parser gotchas): [Configuration](./reference/configuration)

If you are here to read code with context:

- Start with the high-level map: [Architecture overview](./architecture/overview)
- Then browse the module-by-module index: [Source reference](./reference/source)

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

## Where the docs live

- Getting started: `docs/docs/getting-started/`
- Concepts: `docs/docs/concepts/`
- Reference: `docs/docs/reference/`
- Architecture notes: `docs/docs/architecture/`
- Development notes: `docs/docs/development/`
- Source reference (module index): `docs/docs/reference/source/`

## Next

- Follow the sidebar, starting with **Start Here**.
- For day-to-day usage, bookmark: [HTTP API](./reference/http-api) and [CLI](./reference/cli).
