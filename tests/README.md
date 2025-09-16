# Test Harness Overview

This directory will host reusable fixtures and scripting around the compatibility suites described in `docs/compatibility_testing.md`.

## Planned structure

- `traces/` – anonymised SQL replay logs captured from sample apps.
- `fixtures/` – golden results and JSON definitions for translator unit tests.
- `orm/` – docker-compose/Nix manifests for ORM smoke suites.
- `regression/` – curated subset of PostgreSQL regression SQL files.

For now it is a placeholder so tooling has a canonical landing zone.
