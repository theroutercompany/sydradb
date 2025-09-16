# Compatibility Testing Strategy

This document sketches the guard-rails we need while the PostgreSQL compatibility layer comes online. It complements `docs/compatibility.md` by describing concrete test suites and the automation required to keep us close to upstream behaviour.

## Guiding Principles

1. **Confidence through layers** – run fast unit suites on every change, replay realistic SQL traces in CI, and bootstrap heavy regression runs nightly.
2. **Golden results** – anything we emulate from PostgreSQL must be exercised against a real Postgres reference and compared for both results and SQLSTATE/diagnostics.
3. **Observability baked in** – every suite should emit per-query metadata (stats, translation logs) so we can debug mismatches quickly.

## Test Layers

### 1. Translator Unit Tests (`zig test`)

- Cover SQL→sydraQL transformation rules directly.
- One fixture per SQL construct (DDL, DML, aggregates, JSONB ops, arrays, etc.).
- Assert both the generated sydraQL AST and the SQLSTATE metadata when a rule falls back.
- Lives under `src/sydra/translator/tests.zig` (to be added) and runs via `zig build test`.

### 2. Protocol Wire Tests

- Stand up the PG wire front-end inside a test harness.
- Use synthetic libpq/psql scripts to exercise startup, auth, simple + extended queries, COPY, transactions.
- Assert network-level behaviour (messages, SQLSTATE, parameter status).
- Execute inside CI using a dedicated `zig build compat-wire-test` step.

### 3. Trace Replay Harness

- Capture real SQL traffic by proxying a Postgres database during sample application runs (Django, Rails, Prisma, etc.).
- Store anonymised traces in `tests/traces/<app>/trace.jsonl` with metadata (session, parameters, expected results).
- Provide a replay tool (`zig build compat-replay --trace tests/traces/...`) that feeds the translator and compares results against a local Postgres instance.
- Failures should emit diff files with SQLSTATE, payload, execution stats.

### 4. ORM Smoke Suites

- Provision containerised sample apps (Django polls, Rails blog, Prisma todo, SQLAlchemy models).
- Each suite starts the sydra PG endpoint, runs the ORM migrations/tests, and records metrics.
- Managed via Nix flake outputs for reproducibility; triggered nightly and on release branches.

### 5. Postgres Regression Subset

- Vendor the relevant SQL files from the upstream PG regression suite (`src/test/regress/sql/*.sql`).
- Execute them through the translator, comparing outputs to a real Postgres run.
- Maintain a skiplist for features we intentionally do not support yet; log changes to keep the matrix updated.

### 6. Performance Budgets

- pgbench-style workloads (CRUD, COPY bulk load, analytics queries) executed against both sydra and Postgres.
- Capture latency/QPS metrics; fail CI if we regress relative to the baseline by more than a threshold.
- Export results to `docs/compatibility_matrix.md` for transparency.

## Tooling & Infrastructure Checklist

- `tests/README.md` describing how to run each suite locally.
- CLI to record/replay SQL traces (writes JSONL, redacts literals by default).
- Golden-result storage for translator unit tests (JSON fixtures) to simplify review.
- Utility to diff SQLSTATE/error payloads (`compat/sqlstate` provides mapping glue).
- Metrics sink (`compat/stats` + `/debug/compat/stats`) must be reset between suites to avoid crosstalk.

## Schedule & Ownership

| Milestone | Deliverable | Notes |
|-----------|-------------|-------|
| M1 | Translator unit suite + golden fixtures | Blocks translator development |
| M2 | Wire protocol harness | Needs PG client libs in CI |
| M3 | Trace replay tooling | Requires anonymisation rules |
| M4 | ORM smoke tests | Use docker-compose or Nix shells |
| M5 | Regression subset integration | Start with parser/aggregates JSON suites |
| M6 | Performance budgets | Reuse loadgen tooling |

## Immediate Next Steps

1. Scaffold `tests/README.md` with instructions for running translator and wire tests.
2. Build the translator unit test harness alongside the upcoming SQL parser work.
3. Prototype the trace recorder against a staging Postgres instance to validate data format.
4. Add CI jobs for `zig build test` (fast) and `zig build compat-wire-test` (medium) to gate PRs.

Feedback welcome; we will evolve this doc as the compatibility layer matures.
