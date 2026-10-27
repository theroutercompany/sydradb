# Application-neutral SydraDB core

Date: 2026-10-26
Status: implementation project active
Authority: the user requested a comprehensive plan, persistent goal, subagents,
and delivery. The user selected general time-series queries and asked to finish
the current native-storage work first. The user then rejected trading bias in
the database core.

## Outcome

SydraDB must store and query time-series data without requiring an application
vocabulary. Trading remains a supported application of the database. It must not
define generic schemas, validation, query execution, or storage behavior.

This project includes five milestones:

1. Validate and stabilize the existing native-storage implementation.
2. Separate application policy from database mechanisms.
3. Enforce per-query resource limits.
4. Complete general label selection and compiled metric-family execution.
5. Add generic persisted time-bucket rollups.

Each milestone delivers usable behavior, tests, and current documentation. The
project continues across turns until its acceptance criteria are met. A plan,
green smoke test, or passing harness does not establish project completion.

## Evidence and decisions

These locations describe the starting working tree at commit `42fbd55` with
pre-existing uncommitted changes. Line numbers can change during implementation.

| Observed issue | Decision | Starting evidence |
| --- | --- | --- |
| Native storage has substantial uncommitted work and existing recovery gates. | Preserve the work and establish a current baseline before refactoring it. | `git diff --stat`; `docs/docs/development/native-market-release-gates.md`; `src/runtime_tests.zig`; `src/storage_tests.zig` |
| The core seeds trading schemas and validates literal trading metric names. | Extract application policy, then make generic initialization and validation independent of that policy. | `market_catalog.zig:400,1024`; `engine.zig:4587,4600` |
| Native rows already support arbitrary numeric columns. | Reuse the native format and column reader. Do not create another storage engine. | `market_segment.zig:25`; `market_identity.zig:29`; `http.zig:4499` |
| Query scans load complete point ranges, and bytecode execution collects result rows. | Add enforced resource limits before expanding query breadth. | `operator.zig:412`; `vm.zig:156`; `exec.zig:201` |
| Selector filters are absent from parsing and rejected by binding. Legacy metric-family selection exists. | Extend the current language and execution paths using the existing selection semantics. | `parser.zig:349`; `compiler/binder.zig:29`; `operator.zig:444` |
| Rollup definitions expose only three trading transforms. Automatic scan selection is a stub. | Add explicit generic bucket aggregation before automatic rollup planning. | `market_catalog.zig:22`; `physical.zig:174` |

## Boundaries

### Database mechanisms

The core owns schemas, numeric columns, labels, series identity, timestamps,
ordering, corrections, WAL acknowledgement, segments, projection, CAS revisions,
compaction, retention, and query execution. It validates schema structure and
data types without interpreting metric or label names as application identity.

The derived runtime owns scheduling, definition versions, retries, checkpoints,
publication, and provenance. These mechanisms must work for non-trading data.

### Application policy

An explicit trading module owns trade, quote, and bar schemas; OHLC/VWAP and
spread transforms; trading session rules; and trading analysis. Extract existing
behavior before changing it. Keep error handling and validation during moves.

Generic catalog initialization must not require trading defaults. Compatibility
entrypoints may request trading defaults explicitly. Tests and demos must state
when they require the trading application. Existing stored schemas must remain
available after restart, migration, snapshot, and restore.

Do not introduce dynamic plugins, a registry framework, a new dependency, or a
second query language. Add only the direct interfaces required by these modules.

### Compatibility

Preserve series identifiers, schema digests, serialized enum strings, file magic,
format versions, CAS object identities, revision behavior, and current API routes.
Names embedded in storage are compatibility identifiers, even when they contain
`market`. An internal rename must not change their bytes.

Existing market routes remain supported. A neutral public surface must delegate
to the same schema, ingest, and query implementation. Do not duplicate storage or
validation to provide an alias. Document the alias relationship explicitly.

## Query contract

Limits apply to ordinary queries, prepared queries, legacy execution, compiled
physical execution, and the VM. Query text length limits remain separate from
execution resource limits.

Account for query-owned allocations and scanned points. Apply checks before
unbounded accumulation. Release resources after a limit failure, cancellation,
cursor destruction, prepared-statement reset, and finalization. The next query
must succeed after a previous query reaches a limit.

Use explicit errors and stable protocol mappings. A response that already sent
rows cannot change its HTTP status. Define and test the terminal behavior for
that case instead of returning a success-shaped partial result.

Selector equality and inequality filters operate on labels and preserve missing
label semantics. Combine them with time and value predicates. Respect grouping,
ordering, limits, and offsets. Do not expand destructive multi-series statements
as an accidental consequence of expanding read selection.

Compiled execution must report its actual path. A supported metric-family query
must not claim compiled execution while silently using the legacy path.

## Generic rollup contract

The first generic definition identifies its source metric, source columns,
grouping labels, bucket interval, output metric, and aggregate operations.
Support `sum`, `count`, `min`, `max`, and `avg` through existing aggregate logic.
Persist sufficient state for correct averages, rather than averaging averages.

Define bucket boundaries, timestamp units, empty buckets, late points,
same-timestamp corrections, and restart behavior. Repeated processing must not
duplicate results. Historical revision queries must remain deterministic.

Use explicit rollup reads initially. Automatic selection remains a later task
within the roadmap and requires proof of equivalence to raw-data aggregation.
This project does not require automatic selection to complete its first generic
persisted-rollup milestone.

## Verification

Use one contract across three fixture families: sensor measurements, service
metrics, and trading records. Each fixture must exercise schema registration,
ingest, projection, query, correction, restart, snapshot, and restore. Aggregate
checks must use independently computed expected values.

Use the existing Zig 0.15.1 toolchain, storage/runtime tests, wire tests, demos,
and evidence runners. Run focused causal checks before broad suites. Preserve
the native-storage crash, migration, projection, and scalar guardrails.

Linux and macOS are supported targets. Local macOS evidence does not establish
Linux runtime correctness or hosted release acceptance. Cross-builds establish
build compatibility only. Record every unexecuted gate explicitly.

## Authority and completion

Local source, tests, documentation, builds, and temporary test repositories are
authorized. Preserve unrelated user work and never operate on the real `data/`
directory during tests. Do not commit, push, open pull requests, dispatch hosted
CI, publish, or change third-party state without explicit authority.

Use GPT-6 Luna with max reasoning for subagents. Give each task bounded ownership.
Validate agent evidence. Record runtime failures instead of claiming delegation
succeeded. Continue independent work when delegation is unavailable.

Completion requires implemented behavior, current documentation, passing relevant
local checks, and a requirement-by-requirement audit. Keep the persistent goal
active while authorized work remains. Hosted and release acceptance remain
separate from completion of the local engineering deliverables.
