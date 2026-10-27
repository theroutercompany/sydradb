# Application-neutral core implementation plan

> For agentic workers: use `superpowers:subagent-driven-development` for bounded
> independent tasks and `superpowers:executing-plans` for controller-owned tasks.
> Read the design and progress ledger before continuing. Do not repeat completed
> work or replace the project with a smaller objective.

**Goal:** Deliver an application-neutral time-series core with stable native
storage, bounded queries, general label selection, and generic persisted rollups.

**Architecture:** Reuse the existing storage and query machinery. Extract trading
policy behind explicit application entrypoints. Preserve on-disk identifiers and
existing public routes while adding general behavior at shared boundaries.

**Tech stack:** Zig 0.15.1, existing vendored mimalloc, Python 3.13 for evidence
runners, Nix, and the existing Docusaurus documentation site.

**Spec:** `docs/superpowers/specs/2026-10-26-application-neutral-core-design.md`

**Progress:** `docs/superpowers/plans/2026-10-26-application-neutral-core-progress.md`

## Global constraints

- Preserve pre-existing changes and the real `data/` directory.
- Preserve serialized identifiers, schema digests, file formats, and API routes.
- Use GPT-6 Luna with max reasoning for every subagent.
- Add no dependencies or speculative extension framework.
- Do not commit or perform remote mutations without explicit user authority.

## Review focus

- Allocation failure and query-limit failure must release owned resources.
- Restart and publication races must preserve acknowledged data and checkpoints.
- Empty, missing, and conflicting labels must produce deterministic selection.
- Corrections and late points must not produce duplicate or stale rollup output.
- Old repositories and API clients must retain their stored identities and data.

## Execution order and ownership

| Milestone | Deliverable | Dependency | Initial owner |
| --- | --- | --- | --- |
| M1 | Current native-storage baseline and resolved correctness failures | None | Controller; independent storage review |
| M2 | Explicit trading policy and a general schema/row contract | M1 correctness baseline | Controller; application-boundary reviewer |
| M3 | Query allocation and scan limits with protocol contracts | M1; can overlap isolated M2 work | Query implementer and reviewer |
| M4 | Selector filters and compiled family queries | M3 execution lifecycle | Query implementer and reviewer |
| M5 | Generic persisted bucket aggregates and final evidence | M2, M3, M4 | Controller; independent correctness review |

The controller assigns exact files and reviews, integrates, tests, and publishes
the results. Workers own all source and test edits, including shared engine edits.
Read-only design reviews can run in parallel. Do not run competing
whole-repository builds or benchmarks.

## M1: Stabilize current native storage

### Task 1: Preserve and validate the baseline

**Files:** inspect the six dirty files, `build.zig`, `flake.nix`, `scripts/zigw`,
`src/storage_tests.zig`, `src/runtime_tests.zig`, and native release evidence tools.

**Interfaces:** consume the existing `storage-test`, `runtime-test`,
`compat-wire-test`, `native-market-ci`, and release-script targets. Preserve all
existing public interfaces.

- [x] Record HEAD, dirty paths, file checksums, and a copy of the starting diff.
- [x] Run storage and runtime baselines with the pinned Zig environment.
- [x] Run the release-script suite with Python 3.13 and retain terminal results.
- [x] Classify failures as environment, harness, or product failures using logs.
- [x] Record exact commands and evidence paths in the ledger.

Expected: successful terminal exits, or a specific reproducible blocker with its
affected scope. A started process or partial log does not count as a pass.

### Task 2: Resolve storage correctness failures

**Files:** only failing production paths and their nearest causal tests in
`engine.zig`, `storage/*.zig`, and `tools/native_market_soak_driver.zig`.

**Interfaces:** preserve WAL acknowledgement, publication, migration, row identity,
and revision-query contracts. Treat existing dirty code as the starting source.

- [ ] Reproduce each material failure with the smallest relevant test.
- [ ] Inspect the failing function, all callers, and cleanup paths.
- [ ] Apply one root-cause fix and prove the reproducer changes from fail to pass.
- [ ] Run adjacent recovery, migration, and runtime checks.
- [ ] Record unresolved gates without weakening their assertions or thresholds.

No production change is required when the baseline passes. This task does not
authorize speculative storage rewrites.

### Task 3: Establish integration evidence

**Files:** existing evidence runners, fixtures, and current readiness documents.

- [ ] Run `native-market-ci -Doptimize=ReleaseSafe --summary all` locally.
- [ ] Run the existing bounded restart soak with a newly built driver.
- [ ] Retain crash, migration, shadow, and projection smoke evidence.
- [ ] Reconcile stale native-storage statements in current readiness documents.
- [ ] Distinguish smoke evidence from full release-scale evidence in the ledger.

Use empty temporary repositories. Run scale/performance work serially after
correctness passes. Hosted Linux/macOS release evidence requires separate authority.

## M2: Separate application policy

### Task 4: Extract trading schema definitions

**Files:** create `src/sydra/applications/trading/schema.zig`; modify
`src/sydra/storage/market_catalog.zig`; update the existing storage test graph.

**Interfaces:** the application module provides the existing built-in schema
descriptions. The catalog retains ownership, cloning, serialization, and storage
mapping. Preserve `MarketSchemaInput` field meanings and every digest input.

- [x] Pin current built-in columns, labels, mappings, and digest bytes in tests.
- [x] Move schema descriptions into the trading module without changing behavior.
- [x] Keep catalog insertion and allocation cleanup in the catalog.
- [x] Run built-in, identity, reload, migration, and snapshot tests.
- [x] Review the diff for changed serialized strings and accidental dependencies.

Expected: the same built-in schema bytes and digests, with application vocabulary
owned outside the storage implementation.

### Task 5: Extract trading validation and transforms

**Files:** create application modules under `src/sydra/applications/trading/`;
modify the corresponding methods in `engine.zig` and analysis handlers in
`http.zig` only when their code moves.

**Interfaces:** consume current schema, bar-policy, rollup, and signal definitions.
Preserve engine method signatures and existing error names during extraction.
Keep generic scheduling, retries, publication, and checkpoints in the runtime.

- [ ] Pin valid and invalid policy/transform cases before moving them.
- [ ] Extract literal metric rules and transform algorithms into application code.
- [ ] Pass only required data or operations across the boundary.
- [ ] Keep existing tests for retries, corrections, shutdown, and native emission.
- [ ] Verify application helpers do not acquire ownership that callers still hold.

Do not use a dynamic plugin registry or broad callback interface. Extract pure
validation first. Move stateful algorithms only after their data flow is mapped.

### Task 6: Make generic initialization and row APIs application-neutral

**Files:** `market_catalog.zig`, `engine.zig`, `http.zig`, trading schema module,
affected demo seeds, HTTP fixtures, and API documentation.

**Interfaces:** separate generic catalog loading from explicit trading-schema
registration. Preserve old market routes as compatibility entrypoints. Neutral
routes delegate to the same schema/ingest/query handlers.

- [ ] Add a fresh-catalog test that requires no trading schemas.
- [ ] Add compatibility tests for old catalogs and market API entrypoints.
- [ ] Move default registration to explicit application initialization.
- [x] Add neutral schema and row routes without duplicating validation or storage.
- [ ] Update fixtures and demos to register their required application schemas.

The exact public route names must be written into the ledger before implementation
and tested for parity with the compatibility routes. Existing catalog data must
never be deleted or rewritten merely to remove application defaults.

### Task 7: Prove a shared contract across applications

**Files:** existing runtime/storage tests and a small shared fixture helper only
if the same test sequence would otherwise be repeated.

- [ ] Run schema, ingest, projection, and query for sensor, service, and trade data.
- [ ] Apply same-timestamp corrections and verify independent expected values.
- [ ] Repeat reads after flush and restart.
- [ ] Snapshot, restore, and compare current and historical revision results.
- [ ] Verify none of the general fixtures require trading metric or label names.

Expected: the same database contract passes for all three fixture families.

## M3: Bound query resources

### Task 8: Define and implement the query resource owner

**Files:** create `src/sydra/query/limits.zig`; modify `config.zig`,
`query/exec.zig`, `query/executor.zig`, `query/prepared.zig`, and their tests.

**Interfaces:** one query-owned allocation budget and scan counter must survive
for the cursor or prepared execution lifetime. Existing execute/prepare callers
retain compatibility. Configuration supplies defaults through one shared path.

- [ ] Trace allocator ownership across arena, cursor, VM, and prepared reset.
- [ ] Record exact limit defaults, error names, and ownership interfaces.
- [ ] Write limit-boundary and allocation-failure tests before implementation.
- [ ] Enforce allocation accounting without preallocating the entire budget.
- [ ] Test reset, finalization, early destruction, and successful subsequent queries.

Reject arithmetic overflow. Do not share one mutable budget between concurrent
queries. Distinguish a configured limit from unrelated allocator exhaustion.

### Task 9: Enforce limits in all scan and execution paths

**Files:** `query/operator.zig`, `query/vm.zig`, `query/exec.zig`,
`query/prepared.zig`, and engine range-read interfaces if required.

- [ ] Add scan-ceiling tests for exact-series and metric-family reads.
- [ ] Check limits before materializing points, rows, groups, and sort buffers.
- [ ] Cover legacy, compiled physical, VM, and prepared execution.
- [ ] Verify a SQL `LIMIT` does not silently stand in for a scan budget.
- [ ] Verify cancellation and cleanup after a partial execution.

Expected: all paths observe the same configured contract and release resources.
Do not claim bounded storage decoding if temporary storage allocations remain
outside the query budget. Include those allocations or state and fix the gap.

### Task 10: Complete protocol contracts

**Files:** `http.zig`, `compat/wire/session.zig`, `compat/sqlstate.zig`,
query diagnostics, HTTP/wire tests, and API/configuration documentation.

- [ ] Define stable error payloads for failures before response headers.
- [ ] Define terminal behavior for failures after streamed rows begin.
- [ ] Map the same limit failures in prepared and simple wire queries.
- [ ] Test connection reuse and subsequent successful queries after failure.
- [ ] Document exact defaults, units, scope, and terminal error behavior.

## M4: Complete general selection

### Task 11: Parse and normalize selector filters

**Files:** `query/parser.zig`, `query/lexer.zig` as required,
`query/frontend/grammars/sydraql_core.zig`, normalization and semantic modules,
parser fixtures, language documentation.

**Interfaces:** use `ast.Selector.tag_filter`. Start with the documented bracket
selector form and label equality/inequality expressions. Keep regular
`WHERE tag.<name>` predicates supported.

- [ ] Specify syntax, missing-label behavior, and unsupported expressions.
- [ ] Add parser and normalization fixtures for success and malformed input.
- [ ] Preserve precedence when combining selector filters with WHERE predicates.
- [ ] Verify generated and hand-written frontends agree on the supported subset.
- [ ] Test escaping, empty labels, no matches, and exact-ID selectors.

### Task 12: Bind and execute compiled metric families

**Files:** `query/compiler/binder.zig`, `compiler/ir.zig`, `compiler/passes.zig`,
`compiler/lowerer.zig`, `physical.zig`, `operator.zig`, `codegen.zig`, and
`prepared.zig` where the changed selector representation reaches them.

**Interfaces:** preserve exact-series selectors and reuse existing descriptor
selection. Represent family selection explicitly. Use the compiled physical path
when the VM cannot yet execute a shape; report the actual execution path.

- [ ] Add differential tests for exact and family selection in all modes.
- [ ] Cover filters, aggregates, grouping, ordering, LIMIT, and OFFSET.
- [ ] Ensure family scans use the M3 limits and preserve missing-label semantics.
- [ ] Keep destructive multi-series writes outside this read-only extension.
- [ ] Verify selected-series statistics and fallback diagnostics are truthful.

## M5: Generic persisted rollups

### Task 13: Define a generic bucket-aggregate definition

**Files:** generic definition storage beside existing derived definitions;
`market_runtime.zig`, generic validation, register/list HTTP handlers, and docs.

**Interfaces:** definitions identify source metric/columns, grouping labels,
bucket interval, target metric, and aggregate operations. They use existing
definition versioning and provenance. Trading enum strings remain unchanged.

- [ ] Specify and test timestamp units, bucket boundaries, and output schema.
- [ ] Register, reload, and version generic definitions without trading policies.
- [ ] Validate source columns, aggregate types, intervals, and target conflicts.
- [ ] Reject cycles using the existing derived dependency rules or a bounded check.
- [ ] Preserve old catalog loading, snapshot, and migration behavior.

### Task 14: Execute and recover generic rollups

**Files:** generic aggregation runtime, shared aggregate operations,
`engine.zig` scheduling seams, runtime checkpoints, and causal tests.

- [ ] Reuse sum/count/min/max/avg semantics with independently expected results.
- [ ] Test boundary timestamps, empty buckets, and multi-label groups.
- [ ] Test late points, corrections, retries, and restart idempotence.
- [ ] Verify publication ordering, provenance, and revision-query consistency.
- [ ] Compare explicit rollup reads with raw aggregation for all fixture families.

Expected: persisted results survive recovery and match raw aggregation. Average
state must retain its sum and count. Automatic planner substitution is not part
of this first generic-rollup delivery.

### Task 15: Audit the complete project

**Files:** current README, readiness/backlog/API/configuration docs, project ledger,
relevant test graph, and existing release/performance evidence tools.

- [ ] Run the full relevant local Zig, wire, demo, and evidence suites.
- [ ] Run applicable crash, migration, shadow, and bounded soak checks after changes.
- [ ] Measure relevant query and storage guardrails using existing benchmarks.
- [ ] Obtain an independent review and resolve material findings with causal tests.
- [ ] Audit every design requirement against terminal evidence and current files.

Record hosted, cross-platform, and long release-scale checks separately. Do not
mark this goal complete while required locally authorized work is missing.

## Verification commands

Use the pinned Nix environment on macOS. The exact successful command and runtime
environment belong in the ledger. Put caches in writable task-local directories
when the parent sandbox restricts the user cache.

```sh
./scripts/zigw build storage-test -Doptimize=ReleaseSafe --summary all
./scripts/zigw build runtime-test -Doptimize=ReleaseSafe --summary all
./scripts/zigw build test -Doptimize=ReleaseSafe --summary all
./scripts/zigw build compat-wire-test -Doptimize=ReleaseSafe --summary all
python3 -m unittest discover -s scripts/tests -p 'test_native_market_*.py'
```

Run `native-market-ci` when its dependencies and changed runtime paths require
integration evidence. Follow the existing release-gates document for the crash,
migration, shadow, performance, and soak commands. Do not replace those commands
with a new project-specific verification framework.

## Checkpoint and continuation rules

After each completed task, update the ledger with changed paths, the exact test
result, evidence location, and next task. Preserve failure output and explain
whether it reflects product code or the environment. Mark partial tasks partial.

The user authorized implementation, atomic checkpoint commits, and scoped pull
requests. Commit each coherent change with its relevant evidence. Push feature
branches and open pull requests promptly. Do not push directly to main or merge
without explicit authority. Preserve unrelated work when preparing each checkpoint.
