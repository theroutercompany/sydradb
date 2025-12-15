---
sidebar_position: 3
title: AGENTS.md
slug: agents
---

# `AGENTS.md`

## Purpose

Defines repository-wide conventions for contributors, including:

- Project structure (`src/main.zig`, `src/sydra/*`, `cmd/*`, `examples/*`)
- Build and test commands (`zig build`, `zig build test`)
- Zig style rules (Zig 0.15.x, 4-space indent, naming conventions)
- Testing expectations (WAL replay/compaction/snapshot/restore/sydraQL planning)
- Docs expectations (update `docs/` and `sydradb.toml.example` when adding flags)

## How it affects this docs site

The documentation site is structured to mirror `AGENTS.md`:

- “Start Here” covers build/run and the HTTP/CLI surfaces.
- “Architecture” maps to `src/sydra/*` ownership boundaries.
- “Reference/Source Reference” documents each module and its exported surfaces.
