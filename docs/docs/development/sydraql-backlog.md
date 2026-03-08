---
sidebar_position: 7
---

# sydraQL backlog (current snapshot)

This page captures the remaining sydraQL work after the core query pipeline landed. It is intentionally short and focused on the gaps between the current implementation and a clearer v0 contract.

Primary planning doc:

- [sydraQL Engineering Roadmap](./sydraql-roadmap.md)

Implementation reference:

- [Query pipeline overview](../reference/source/sydra/query/overview.md)
- [HTTP API – `POST /api/v1/sydraql`](../reference/http-api.md#post-apiv1sydraql)

## Near-term backlog

### 1. Lock the public v0 surface

- Document the supported statement forms, expression grammar, ordering/limit behavior, and the currently supported function subset.
- Publish a small set of representative queries instead of treating the whole roadmap as shipping scope.

### 2. Close the implementation/documentation gap

- Bring the readiness checklist in line with actual code and keep it maintained.
- Document current non-goals clearly: broad joins, full rollup selection, rich parser recovery, and broad quota enforcement.

### 3. Finish the obvious execution gaps

- Tag filter syntax in the language surface
- Wider function execution coverage to match the registry
- Better query error normalization
- Stable plan/execution golden coverage

### 4. Keep later work explicitly deferred

These remain important, but they are not part of the current alpha contract:

- downsampling-aware planning
- richer derivative/window semantics
- broader quotas and memory budgeting
- deeper benchmark and fuzz infrastructure
- larger compatibility mapping work for the PostgreSQL bridge
