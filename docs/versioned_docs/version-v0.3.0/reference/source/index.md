---
sidebar_position: 1
---

# Source reference

This section documents SydraDB’s source tree at the module level, with a focus on:

- What each file/module does
- Public surfaces and key internal helpers
- Key types, constants, and invariants
- How modules interact

This is written against the repository sources (e.g. `src/**`, `cmd/**`) without modifying them.

## Conventions used in these pages

- **Module path** refers to the repository-relative path, e.g. `src/sydra/server.zig`.
- **Public API** refers to `pub` declarations exported by the module.
- “Definitions” include: functions, structs/enums/unions, variables, and constants.

## Where to start

- For process startup and CLI routing: `Entrypoints`.
- For HTTP endpoints: `src/sydra/http.zig` (under `src/sydra`).
- For core ingest/query mechanics: `src/sydra/engine.zig` (under `src/sydra`).

