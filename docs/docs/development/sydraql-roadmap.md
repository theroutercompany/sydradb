# sydraQL Engineering Roadmap

This roadmap translates the sydraQL language vision into a sequenced engineering plan. It assumes the repository is already migrated to Zig 0.15 and that the storage, WAL, and HTTP layers match the current `main` branch. Each phase lists goals, scope boundaries, detailed work items, interfaces, artefacts, validation gates, and fallback considerations. Milestones are intentionally granular so we can parallelise efforts while keeping tight feedback loops.

## Phase 0 – Specification Lockdown & Readiness (1–2 weeks, prerequisite for all build phases)

- **Objectives**
  - Finalise the sydraQL surface area for v0 in alignment with [sydraQL Design](../concepts/sydraql-design.md) and the resolved open questions (single-series math, virtual rollup tables, numeric + JSON insert payloads, half-open delete windows).
  - Produce canonical examples that drive parser tests, planner expectations, and HTTP contract fixtures.
  - Ensure tooling (zig 0.15.x, nix shell, CI matrix) is green and repeatable.
- **Deliverables**
  - Updated [sydraQL Design](../concepts/sydraql-design.md) reflecting locked answers, grammar, and function catalogue with argument/return typing.
  - Expanded examples appendix with at least: range scan, downsample + fill, rate computation, insert with fields, delete retention case, error scenarios.
  - Issue breakdown in [sydraQL backlog](./sydraql-backlog.md) tagged with phase identifiers and size estimates.
- **Key Tasks**
  - Cross-reference Postgres compatibility doc to flag unsupported SQL forms and document translation fallbacks.
  - Define numeric limits (`MAX_POINTS`, `MAX_SERIES`, `MAX_QUERY_DURATION`) and failure codes in a shared Zig enum under `src/sydra/query/errors.zig`.
  - Align on telemetry schema for parse/plan/exec timings and log structure.
- **Acceptance Criteria**
  - Stakeholders sign off on spec in review PR; no open TODOs remain in design doc.
  - CI job `zig build test` passes with new tests covering enum additions.
  - Readiness checklist tracked in [sydraQL readiness](./sydraql-readiness.md) completed.
- **Risks & Mitigations**
  - *Risk*: Scope creep reintroducing multi-series math. *Mitigation*: document deferral in design, add follow-up issue.
  - *Risk*: Compatibility gaps discovered late. *Mitigation*: run translator spike queries early and log deltas.
- **Inputs & Dependencies**
  - Existing catalog schema description in [Catalog shim notes](../reference/postgres-compatibility/catalog-shim-notes.md) to confirm rollup exposure paths.
  - Storage retention behaviour outlined in [PostgreSQL compatibility architecture](../reference/postgres-compatibility/architecture.md); treat as source of truth for delete semantics.
  - Zig toolchain pinned in `flake.nix`; keep [Contributing](./contributing.md) and [Zig 0.15 migration checklist](./zig-0.15-migration-checklist.md) up to date.
- **Key Engineering Decisions to Capture**
  - Canonical enum names for error codes and whether they map 1:1 with HTTP status families.
  - Duration literal canonicalisation rules (store as `std.time.Duration` vs custom struct).
  - Default namespace/metric resolution order when both `series_id` and `(namespace, metric)` provided.
- **Artifacts & Templates**
  - Create `docs/sydraql/examples/` folder housing `.sydraql` files consumed by parser tests and HTTP fixtures.
  - Author `docs/adr/0005-sydraql-spec-finalization.md` summarising the locked decisions for archival.
  - Introduce `templates/error.json` for API error responses used in Phase 6 tests.

## Phase 1 – Lexer & Token Infrastructure (1 week, unblocks parser)

- **Objectives**
  - Implement a zero-allocation tokenizer that transforms query text into typed tokens with precise spans.
  - Establish reusable error reporting structures and diagnostics helpers.
- **Scope**
  - Covers Zig module `src/sydra/query/lexer.zig` plus unit tests.
  - Includes duration parsing, ISO-8601 handling, numeric/identifier lexing, comments, and keyword table.
  - Excludes AST construction and semantic validation (handled later).
- **Work Items**
  - Define `TokenKind` enum including punctuation, literals, keywords, operators (`=`, `!=`, `=~`, `!~`, `&&`, `||`, etc.).
  - Implement `Lexer.init(alloc, source)` returning iterator with `next()` that yields `Token` (kind, slice, line:col span).
  - Add helper `token.isKeyword("select")` using perfect-hash or binary search for deterministic keyword resolution.
  - Provide diagnostic type `LexError` with code (`ERR_INVALID_LITERAL`, `ERR_UNTERMINATED_STRING`) and span.
  - Integrate feature flags for JSON field detection (only active inside `INSERT` contexts, but lexed generically).
- **Testing & Tooling**
  - Inline Zig tests covering: mixed whitespace, comment stripping, large numeric literals, duration forms, regex tokens.
  - Golden test file `tests/parser/lexer_cases.zig` verifying token stream snapshots (use `std.testing.expectEqualDeep`).
  - Add fuzz hook stub (delegate to Phase 7 for actual fuzz harness).
- **Acceptance Criteria**
  - 100% keyword coverage measured by table diff; `zig build test` passes with new suite.
  - Bench test (micro-benchmark) demonstrating < 15% allocation overhead vs baseline.
  - `Lexer` module documented with usage examples in doc comment.
- **Risks**
  - Regex literal ambiguity with `=~`/`!~`. Mitigate by dedicated state machine and tests.
  - Locale-dependent timestamp parsing: enforce ASCII-only processing and UTC normalization.
- **Inputs & Dependencies**
  - Token reference sheet from Phase 0 examples; convert into automated keyword table generator in `tools/gen-keywords.zig`.
  - `std.time` facilities for parsing durations; map unsupported units (weeks) to explicit errors.
  - Agreement with validator team on token span semantics (byte offsets vs UTF-8 codepoints).
- **Key Data Structures**
  - `Token` struct: `{ kind: TokenKind, lexeme: []const u8, span: Span, flags: TokenFlags }`.
  - `Span` struct: `{ start: usize, end: usize, line: u32, column: u32 }`.
  - `TokenFlags` bitset for immediate metadata (`is_numeric_literal`, `contains_escape`, `is_regex_delimited`).
- **Implementation Notes**
  - Reserve sentinel token `TokenKind.end_of_file` to simplify parser loops.
  - Normalise newline handling (`\r\n` vs `\n`) early in lexer; maintain offset translation table for diagnostics.
  - Use small lookup table for duration suffix to nanoseconds conversion, ensuring overflow guarded.
  - Plan for streaming interface (`Lexer.peekN(n)`) to support lookahead needed by parser error recovery.
- **Testing Extensions**
  - Add property test ensuring lexing followed by concatenation of lexeme slices reproduces original source (ignoring comments).
  - Include extremely long identifier case (>4k bytes) to stress span math.
  - Validate error tokenization for unterminated regex and string cases.

## Phase 2 – Parser & AST Construction (2–3 weeks, dependent on Phase 1)

- **Objectives**
  - Build a recursive-descent parser that produces a typed AST for `SELECT`, `INSERT`, `DELETE`, `EXPLAIN`.
  - Encode AST node variants using Zig tagged unions with source spans for later diagnostics.
- **Scope**
  - Files: `src/sydra/query/ast.zig`, `src/sydra/query/parser.zig`, plus tests under `tests/parser`.
  - Handles precedence climbing for arithmetic, boolean logic, function calls, and aggregated expressions.
- **Detailed Tasks**
  - Define AST structs: `SelectStmt`, `InsertStmt`, `DeleteStmt`, `ExplainStmt`, `Expr` union (Literal, Ident, Call, Binary, Unary, Selector, TimeBucket, FillSpec, etc.).
  - Implement Pratt-style expression parser to manage precedence, with table for operators.
  - Implement statement parsers with context-specific validation (e.g., `WHERE` for time range requirement but full semantic check deferred to Phase 3).
  - Attach `Span` to every node (start/end byte offsets) for error reporting.
  - Provide parse-time recovery heuristics (skip to next semicolon or keyword) to gather multiple errors per query when feasible.
  - Add AST formatting helpers for debugging (`fmt.ASTPrinter`).
- **Test Plan**
  - Unit tests per statement shape with both success and failure cases (invalid token, missing clause).
  - Golden snapshot tests: textual AST representation for representative queries (`tests/parser/select_basic.zig`, etc.).
  - Mutation tests: random token deletion/insertion ensuring parser either recovers or raises deterministic error.
- **Acceptance Criteria**
  - Parser handles all Phase 0 canonical examples.
  - Error messages include token spans and human-readable text; ensure coverage by verifying error strings.
  - Performance benchmark: parse 10k simple queries/second on dev hardware (document command in README dev notes).
- **Risks**
  - Precedence mistakes causing incorrect ASTs. Mitigate via targeted tests and cross-check with manual parse trees.
  - Recovery logic masking real errors. Mitigate by logging parse warnings in debug builds.
- **Inputs & Dependencies**
  - Lexer contract from Phase 1 specifying token kinds and spans.
  - Function catalogue from design doc to seed AST nodes for built-ins.
  - Agreement with planner on AST invariants (e.g., `SelectStmt.projections` order, `GroupBy` structures).
- **Key Data Structures**
  - `Expr` tagged union variants enumerated with explicit payload structs (`BinaryExpr`, `CallExpr`, `FieldAccessExpr`).
  - `SelectStmt` containing nested `Selector` (series reference + tag predicates) and `TemporalPredicate`.
  - `InsertPayload` structure capturing `(timestamp_literal, numeric_value, fields_json?)`.
- **Implementation Notes**
  - Introduce parser context stack to disambiguate `WHERE` inside selector vs statement-level.
  - Implement expect helpers `expectKeyword`, `expectPunctuation` returning `ParserError`.
  - Provide `ParserArena` using `std.heap.ArenaAllocator` to allocate AST nodes efficiently; ensure clear per-parse to avoid leaks.
  - Document and assert grammar LL(1) assumptions where we rely on single-token lookahead.
- **Extended Testing**
  - Round-trip tests: parse AST then serialise via `fmt.ASTPrinter` and ensure structure-conserving comparisons.
  - Stress test with queries approaching limit size (256 KB) to ensure parser handles long inputs.
  - Introduce fuzz corpus seeds stored in `tests/fuzz/corpus/parser/`.

## Phase 3 – Semantic Validation & Type Checking (1–2 weeks, depends on Phase 2)

- **Objectives**
  - Ensure parsed AST complies with language rules: required time ranges, valid aggregation contexts, function arity/type checks, fill policy constraints.
  - Prepare enriched AST for planning by annotating nodes with semantic info (resolved function pointers, inferred types).
- **Scope**
  - New module `src/sydra/query/validator.zig` with exported `analyze(ast, catalog)` routine.
  - Interacts with storage catalog metadata for rollups and series existence checks (via trait-based interface).
- **Tasks**
  - Define type system enums (`TypeTag.scalar`, `TypeTag.series`, `TypeTag.duration`, etc.).
  - Implement function registry in `src/sydra/query/functions.zig` mapping names to signatures and planner hints.
  - Validate `GROUP BY` usage: ensure grouped expressions align with select list or are aggregates.
  - Enforce single-series math rule for v0 by rejecting multi-selector expressions unless they share alias and bucket spec.
  - Annotate AST nodes with `SemanticInfo` (inferred type, constant folding opportunities, bucket step).
  - Provide diagnostics for missing time filters in `SELECT` and `DELETE`.
- **Testing**
  - Semantic unit tests using mock catalog to simulate available series, rollups, functions.
  - Negative tests: invalid fill combination, missing alias, unsupported function.
  - Ensure validator output includes actionable error codes aligning with `errors.zig`.
- **Acceptance Criteria**
  - 100% of canonical queries produce annotated AST with type info.
  - Validator rejects invalid constructs with documented error codes.
  - Coverage: `zig test src/sydra/query/validator.zig` >= 90% statements.
- **Risks**
  - Catalog interface churn: define minimal trait now, adapt later.
  - Function registry drift: incorporate doc generation to stay in sync (see Phase 7 tasks).
- **Inputs & Dependencies**
  - Storage catalog trait from `src/sydra/storage/catalog.zig` providing rollup metadata, retention policy, namespace validation.
  - Function metadata table (Phase 0/2) enumerating accepted argument types and evaluation hints.
  - Config defaults from `sydradb.toml.example` for limit enforcement.
- **Key Data Structures**
  - `TypeTag` enum with helper methods `isNumeric`, `isAggregatable`.
  - `SemanticInfo` struct: `{ type: TypeTag, isConstant: bool, rollupRequirement: ?Duration, function: ?*const FunctionDef }`.
  - `ValidationContext` capturing time filter state, aggregation depth, alias registry, fill policy.
- **Implementation Notes**
  - Enforce `DELETE` time window by verifying `TemporalPredicate` resolves to closed range; return `ERR_DELETE_REQUIRES_TIME`.
  - Constant fold literal arithmetic to reduce planner work; store folded value back into AST node.
  - Validate regex predicates compile by calling pre-check (without executing) using RE2-on-CPU fallback.
  - Record friendly hints for missing rollups (to surface in HTTP layer).
- **Extended Testing**
  - Table-driven tests enumerating function arity mismatches and verifying specific error codes.
  - Validate alias scoping rules (`SELECT avg(value) AS avg_value FROM ... HAVING avg_value > ...` future-proofing).
  - Simulate catalog with conflicting retention windows to ensure validator catches unsupported queries.

## Phase 4 – Logical Planning Layer (2–3 weeks, requires Phase 3)

- **Objectives**
  - Convert validated AST into logical plan tree describing high-level operators: `Scan`, `Filter`, `Project`, `Aggregate`, `JoinTime`, `Fill`, `Sort`, `Limit`.
  - Implement rule-based optimizer passes for predicate/fill pushdown and rollup selection.
- **Scope**
  - Modules: `src/sydra/query/plan.zig`, `src/sydra/query/optimizer.zig`.
  - Introduce plan visitor utilities for future transformations.
- **Work Items**
  - Define logical operator structs with metadata: `Scan(series_ref, time_range, rollup_hint)`, `Aggregate(step, functions, group_keys)`, etc.
  - Build planner pipeline: `Planner.build(ast, catalog, statistics)` returning plan plus diagnostics.
  - Implement cost heuristic for rollup choice: prefer highest resolution rollup meeting requested bucket, fall back to raw segments.
  - Add predicate simplifier merging adjacent time filters, constant-folding boolean expressions.
  - Attach `Limit` pushdown logic to reduce data scanned.
  - Document plan serialization for `EXPLAIN`.
- **Testing**
  - Golden plan tests stored as JSON or Zig struct dumps in `tests/planner/*.zig`.
  - Scenario tests using synthetic catalog snapshots representing different rollup availability.
  - Negative tests ensuring unsupported constructs produce planner errors (e.g., requesting rollup not present).
- **Acceptance Criteria**
  - Planner produces expected logical trees for design doc scenarios and additional stress cases (large tag filters, nested functions).
  - Rollup heuristic selects correct resolution in >95% of synthetic cases; fallback path logged.
  - `EXPLAIN` outputs human-readable plan text aligning with logical tree.
- **Risks**
  - Heuristic mis-selection causing performance regressions; mitigate with metrics and ability to override (future phases).
  - Complexity explosion; keep plan nodes minimal and document invariants.
- **Inputs & Dependencies**
  - Semantic output enriched AST with type annotations.
  - Storage statistics interface providing cardinality estimates, rollup availability.
  - Config toggles for optimizer (e.g., disable predicate pushdown for debugging).
- **Key Data Structures**
  - `LogicalPlan` tagged union with variants `Scan`, `Filter`, `Project`, `Aggregate`, `JoinTime`, `Fill`, `Sort`, `Limit`, `Delete`.
  - `Predicate` structure normalised into CNF/DNF for easier pushdown decisions.
  - `PlanProperties` metadata (estimated rows, cost, order, projection set).
- **Implementation Notes**
  - Use builder pattern: `Planner.init(alloc, catalog)` returning struct with methods per AST node.
  - Implement transformation framework with rule registry so future rules plug in easily.
  - Track provenance of predicates (origin clause) for debugging and EXPLAIN output.
  - Expose `PlanInspector` debugging tool to print plan plus annotations for CLI `--explain-raw`.
- **Extended Testing**
  - Simulate conflicting rollup hints (user-specified vs heuristic) and ensure resolution logic deterministic.
  - Regression tests for predicate pushdown across nested filters ensuring idempotence.
  - Serialize logical plans into JSON for golden tests and diff across commits to detect changes.

## Phase 5 – Physical Execution Engine (3–4 weeks, builds on Phase 4)

- **Objectives**
  - Implement iterators/operators that execute logical plans against storage segments with streaming semantics.
  - Support aggregation, fill policies, rate computations, and deletion operations.
- **Scope**
  - Modules under `src/sydra/query/engine/`: `scan.zig`, `filter.zig`, `aggregate.zig`, `fill.zig`, `rate.zig`, `delete.zig`.
  - Integrate with storage APIs from `src/sydra/storage`.
- **Detailed Tasks**
  - Build `Cursor` abstraction returning `PointBatch` structures (timestamp/value arrays plus tag metadata).
  - Implement `ScanCursor` reading from WAL + rollup segments with respect to time range and rollup selection.
  - `FilterOperator` applying tag/time predicates using vectorized evaluation.
  - `AggregateOperator` supporting `min`, `max`, `avg`, `sum`, `count`, `percentile`, `first`, `last`; implement bucket management keyed by `time_bucket`.
  - `FillOperator` handling `fill(previous|linear|null|const)` with interpolation logic, leveraging last seen values.
  - `RateOperator` computing `rate/irate/delta/integral` with monotonicity checks.
  - Implement deletion executor performing range tombstoning across raw/rollup segments, coordinating with compactor interface.
  - Provide metrics instrumentation for batches processed, time spent, memory usage.
- **Testing**
  - Extensive unit tests using in-memory storage fixtures under `tests/engine`.
  - Integration tests combining planner + engine for end-to-end queries over synthetic datasets.
  - Benchmark harness measuring throughput for typical queries (document command).
- **Acceptance Criteria**
  - Throughput target: 1M points/sec for simple aggregates on dev hardware; 200k points/sec for rate computations.
  - Fill and rate operators verified against known sequences; ensure correct behavior on missing data.
  - Delete operations produce expected tombstones and interact correctly with compaction simulator.
- **Risks**
  - Memory pressure from large group-by results: design pooling and backpressure (defer to Phase 7 for stress harness).
  - Numerical instability in rate/integral; rely on double precision and guard rails.
- **Inputs & Dependencies**
  - Logical plan definitions finalised in Phase 4.
  - Storage iterators and WAL readers (`src/sydra/storage/log_reader.zig`, `memtable` APIs).
  - Retention/compaction behaviour from storage team (document interface for tombstoning).
- **Key Data Structures**
  - `PointBatch` struct: arrays for timestamps, values, optional fields map pointer, tag view ID.
  - `Cursor` trait with methods `nextBatch()`, `rewind()`, `close()`.
  - Aggregation buckets stored in `AggState` union per function (e.g., `SumState`, `PercentileSketch`).
  - `FillContext` carrying previous bucket value, interpolation slope, default fill constant.
- **Implementation Notes**
  - Design iterators to operate on columnar buffers to leverage SIMD (future optimisation).
  - Provide memory pool for `AggState` allocations; integrate with `std.heap.ArenaAllocator` plus freelist.
  - Ensure `RateOperator` handles wrap-around by verifying monotonic timestamps and counter resets.
  - Delete executor should batch tombstones and keep track of rollup segments touched for compactor.
  - Instrument all operators with RAII style timing (start/stop) hooking into metrics registry.
- **Extended Testing**
  - Use golden dataset under `tests/data/sydraql/basic_series.json` to assert aggregate outputs.
  - Run long-duration streaming test to surface memory leaks (wrap under `zig build engine-leakcheck`).
  - Concurrency tests simulating multiple query contexts reading same data to ensure shared structures safe.

## Phase 6 – API, CLI, and Translator Integration (2 weeks, after Phase 5 MVP operators exist)

- **Objectives**
  - Expose sydraQL through HTTP (`/api/v1/sydraql`) and CLI (`zig build run -- query` or similar).
  - Integrate PostgreSQL compatibility translator to map supported SQL queries into sydraQL AST.
- **Scope**
  - Modules in `src/sydra/http/`, CLI command in `cmd/`.
  - Update compatibility documentation and quickstart.
- **Tasks**
  - Implement HTTP handler that accepts plain text sydraQL, enforces limits, streams JSON result rows (`[{time, value, tags, fields}]`) with metadata.
  - Add pagination/limit enforcement on server side.
  - Wire CLI command `sydradb query <file|inline>`.
  - Hook translator: `sql_to_sydraql(sql)` returning AST or error; share error codes.
  - Update the [PostgreSQL compatibility matrix](../reference/postgres-compatibility/compat-matrix-v0.1.md) with a mapping table; add CLI examples to [CLI](../reference/cli.md) and [Quickstart](../getting-started/quickstart.md).
- **Testing**
  - HTTP integration tests under `tests/http/` using in-memory server harness.
  - CLI snapshot tests verifying output formatting.
  - Translator regression suite referencing `compatibility` doc.
- **Acceptance Criteria**
  - HTTP endpoint passes contract tests, including streaming multi-chunk responses and error payloads.
  - CLI shell command returns zero exit code and prints JSON lines for queries.
  - Translator round-trips at least 80% of targeted Postgres fragments; unsupported features log actionable errors.
- **Risks**
  - Streaming complexity; ensure backpressure by leveraging existing HTTP chunked encoder.
  - Translator drift from actual grammar; maintain shared AST definitions.
- **Inputs & Dependencies**
  - Execution engine API returning streaming batches.
  - Existing HTTP server utilities in `src/sydra/http/server.zig` and CLI infra `cmd/sydradb/main.zig`.
  - Authentication/authorization mechanisms already in runtime ensure queries run under correct tenant.
- **Key Data Structures**
  - HTTP response envelope: `{ statement: string, stats: QueryStats, rows: []Row }` stream-encoded.
  - `QueryStats` struct capturing parse/plan/exec durations, scanned points, rollup selection, cache hits.
  - CLI output struct for table/JSON toggles; support `--format json|table`.
- **Implementation Notes**
  - Reuse existing task scheduler for asynchronous execution; ensure query cancellation on client disconnect.
  - Provide health endpoint exposing last query metrics for observability dashboards.
  - Translator should share AST definitions via `pub const` to avoid duplication; compile-time flag to disable translator in minimal builds.
  - Add rate limiting (per IP or API key) hooking into existing middleware.
- **Extended Testing**
  - HTTP contract tests verifying chunk boundaries and `Content-Type: application/json`.
  - CLI integration using expect scripts to assert interactive prompts behave correctly.
  - Translator parity suite comparing SQL inputs vs expected sydraQL AST; log unsupported features.

## Phase 7 – Tooling, Observability, and Quality Gates (1–2 weeks, parallelisable after Phase 3)

- **Objectives**
  - Provide developer tooling, instrumentation, and automated verification to keep sydraQL stable.
  - Establish fuzzing, golden fixtures, and metrics dashboards.
- **Scope**
  - Tools under `tools/` or `cmd/`, docs updates, CI pipeline changes.
- **Tasks**
  - Build lexer/parser fuzz harness (e.g., `zig build fuzz-lexer` using libFuzzer integration).
  - Add plan snapshot regression tests triggered via `zig build planner-golden`.
  - Implement `scripts/gen-function-docs.zig` to export function registry into Markdown in `docs/sydraql-functions.md`.
  - Wire query execution metrics into Prometheus exporter: parse latency, plan latency, execution time, memory usage.
  - Configure CI jobs: unit tests, integration tests, fuzz smoke (short run), benchmark smoke (with tolerated variance).
  - Document developer workflow in [Contributing](./contributing.md) and [Docusaurus toolbox](./docusaurus-toolbox.md).
- **Acceptance Criteria**
  - CI pipeline includes new checks and passes on main branch.
  - Fuzz harness runs nightly (document job) with flakes tracked.
  - Observability endpoints expose documented metrics; add to ops runbook.
- **Risks**
  - Fuzz harness complexity; start with lexing then expand to parser.
  - Benchmark noise; mitigate by using controlled dataset and measuring relative deltas.
- **Inputs & Dependencies**
  - Parser and planner stable interfaces to allow harness reuse.
  - Metrics registry and logging infrastructure produced earlier.
  - CI pipeline definition (`.github/workflows/*.yml` or equivalent) ready for augmentation.
- **Key Data Structures & Tools**
  - Fuzz harness entrypoints `fuzz_lexer` and `fuzz_parser` returning `std.os.Executor.FuzzResult`.
  - Benchmark scenario descriptors `benchmarks/sydraql/*.json` capturing query plus dataset pointer.
  - Metrics exporter registry mapping names to gauge/counter/histogram types.
- **Implementation Notes**
  - Integrate with OSS-Fuzz style corpus; ensure reproducibility by storing seeds in repo.
  - Build doc generator from `functions.zig` to Markdown with auto-updated table (hook into CI diff check).
  - Add `zig fmt` hook as pre-commit to keep docs consistent; document it in [Contributing](./contributing.md).
  - Provide `./tools/sydraql-lint` script to run subset of checks locally.
- **Extended Testing**
  - Nightly fuzz results summarised in `docs/sydraql-fuzz-report.md`.
  - Benchmark run compared against baseline threshold stored in repo; fail if regression >10%.
  - Validate metric names with static analysis (no collisions, proper naming scheme).

## Phase 8 – Hardening, Performance Tuning & Release Prep (2 weeks, final)

- **Objectives**
  - Validate sydraQL under load, perform stress testing, and prepare release artefacts/documentation.
  - Capture any deferred features or gaps into follow-up backlog.
- **Scope**
  - Focused on QA, docs, packaging; minimal new features.
- **Tasks**
  - Run large-scale load tests using synthetic and replayed production traces (document dataset sourcing).
  - Profile hot functions (lexer, planner, aggregate loops); apply targeted optimisations.
  - Conduct failure-mode testing: malformed queries, exceeding limits, storage failures.
  - Update `docs/sydraql-design.md` with any learnings; produce `CHANGELOG.md` entry.
  - Review security posture: ensure no injection or path traversal via queries, confirm auth integration with HTTP layer.
  - Prepare release checklist: version bump, binary packaging (zig release build, nix result).
- **Acceptance Criteria**
  - Load test metrics meet or exceed targets (documented in results appendix).
  - All known P0/P1 issues resolved or waived with justification.
  - Release candidate tagged and smoketested via CLI & HTTP.
- **Risks**
  - Performance regressions discovered late; keep profiling instrumentation on by default in dev builds.
  - Documentation debt; allocate dedicated writer time.
- **Inputs & Dependencies**
  - Full pipeline (lexer through API) feature-complete and merged into integration branch.
  - Load tooling (possibly `cmd/replay` or external load generator) configured with dataset.
  - Observability dashboards defined in Phase 7.
- **Key Activities**
  - Conduct chaos testing injecting storage latency, partial failures, and ensure query retries behave.
  - Validate cancellation flow by aborting long-running HTTP requests and verifying resource cleanup.
  - Review security: ensure regex filters bounded to prevent ReDoS, confirm JSON payload limits enforced.
- **Implementation Notes**
  - Profile with `zig build profile-release` plus `perf`/`heaptrack` to spot hotspots; document patches.
  - Hard-code compile-time guards for feature flags; confirm disabled features compile out cleanly.
  - Perform final API review ensuring error codes documented and stable.
- **Extended Testing**
  - Multi-tenant tests verifying namespace isolation in queries, retention enforcement per tenant.
  - Backwards compatibility test suite ensuring old CLI still interacts with new server.
  - Run incremental upgrade test (old version to new) verifying WAL compatibility.

## Cross-Phase Considerations

- **Parallelisation Strategy**
  - Lexer (Phase 1) can start immediately; planner/engine teams prepare by studying storage APIs.
  - Tooling (Phase 7) can begin once parser AST stabilises to avoid churn.
  - API integration (Phase 6) should wait for minimal execution path (Phase 5) but can stub responses using plan formatting for early CLI work.
- **Phase Exit Criteria Template**
  - `Design` column cleared (all TODOs resolved, doc updates merged).
  - `Implementation` column: all mandatory issues closed, optional items moved to backlog.
  - `Verification` column: associated tests passing on CI, benchmark thresholds recorded.
  - `Docs & Ops` column: docs merged, runbook entries updated, observability dashboards adjusted.
- **Branching & Release Mgmt**
  - Use feature branches per phase (`feature/sydraql-phase1-lexer`, etc.), merging into `feature/sydraql` integration branch before main.
  - Maintain rolling integration tests to avoid merge debt; nightly rebase onto main.
  - Introduce `sydraql-phase-status.md` at repo root summarising current phase, owners, and blocked items.
- **Documentation Sync**
  - Every phase must update relevant docs: grammar changes (Phase 2), functions (Phase 3), plan semantics (Phase 4), API usage (Phase 6).
  - Keep `docs/sydraql-roadmap.md` updated with status per phase; add checkboxes with dates in follow-up PR.
  - Add doc lints verifying examples compile or parse (hook into Phase 2 parser as doc test harness).
- **Testing Matrix**
  - Unit tests (per module), integration (planner+engine), end-to-end HTTP, fuzz (lexer/parser), property tests (aggregations), benchmark tests.
  - Ensure `zig build test` remains umbrella target; create subcommands `zig build test-parser`, `zig build test-engine`.
  - Maintain test inventory spreadsheet (or markdown table) linking each requirement to test location for auditability.
- **Observability & Metrics**
  - Adopt standard metric naming (`sydraql_parse_latency_ms`, `sydraql_points_scanned_total`).
  - Provide structured logs with trace IDs to correlate HTTP and engine events.
  - Configure alert thresholds (parse latency >500ms, execution latency >5s, error rate >1%) and document runbooks.
- **Operational Readiness**
  - Define on-call handoff doc for sydraQL incidents including common error codes and remediation steps.
  - Coordinate with infra team to allocate dashboard panels and alert channels before API launch.
  - Prepare sample Grafana dashboards referencing new metrics for customer success.

## Core Module Architecture

- **High-Level Package Layout**
  - `src/sydra/query/lexer.zig`: tokenization logic, exported `Lexer`.
  - `src/sydra/query/parser.zig`: recursive-descent parser returning AST rooted at `Statement`.
  - `src/sydra/query/ast.zig`: node definitions and formatting helpers.
  - `src/sydra/query/functions.zig`: registry of built-in functions with type metadata.
  - `src/sydra/query/validator.zig`: semantic analysis producing annotated AST.
  - `src/sydra/query/plan.zig`: logical plan structures.
  - `src/sydra/query/optimizer.zig`: rule framework and phases.
  - `src/sydra/query/engine/`: physical operators and execution runtime.
  - `src/sydra/query/translator/postgres.zig`: SQL to sydraQL conversion layer.
  - `src/sydra/http/sydraql_handler.zig`: HTTP surface.
  - `tests/`: unit/integration suites mirroring modules.
- **Core Interfaces**
  - `pub fn execute(query: []const u8, ctx: *ExecutionContext) !ResultStream` entrypoint bridging API to engine.
  - `Catalog` trait: `resolveSeries`, `listRollups`, `retentionPolicy`.
  - `Operator` trait: `open`, `next`, `close`, `statistics`.
  - `QueryContext`: encapsulates allocator, tenant info, limit configuration, telemetry handles.
- **Data Flow Overview**
  1. HTTP/CLI receives query string and constructs `QueryContext`.
  2. Lexer tokenizes into `[]Token`.
  3. Parser builds AST inside arena allocator.
  4. Validator annotates AST with types using Catalog and Function registry.
  5. Planner translates AST to logical plan, runs optimization passes.
  6. Engine constructs operator pipeline, streams batches to caller.
  7. Results encoded into JSON/CLI output while collecting metrics.
- **Memory Management Notes**
  - Use arena allocators per query for AST and plan nodes; release at query end.
  - Engine operators share pooled buffers from `QueryContext.bufferPool`.
  - Avoid global state; pass handles explicitly to maintain testability.

## Detailed Testing Matrix

- **Lexer Tests**
  - Unit: token sequences, error cases, duration parsing.
  - Property: lex-then-concat equals original, random unicode rejection.
  - Fuzz: random bytes with sanitised survivors added to corpus.
- **Parser Tests**
  - Unit: statement shape variations, precedence scenarios.
  - Integration: parser + validator pipeline for canonical examples.
  - Mutational: minimal-change corpora to ensure resilience.
- **Validator Tests**
  - Table-driven: per function/aggregation rule.
  - Catalog-simulated: series existence, rollup coverage.
  - Error message compliance: assert codes and text.
- **Planner Tests**
  - Golden JSON: stable plan shapes.
  - Cost heuristic: synthetic catalog scenarios.
  - Pushdown invariants: ensure final plan order.
- **Engine Tests**
  - Unit: aggregator correctness, fill behaviours, rate edge cases.
  - Integration: planner + engine end-to-end on synthetic data.
  - Performance: microbench harness for each operator.
- **API/CLI Tests**
  - Contract: HTTP behaviour, status codes, streaming.
  - CLI UX: interactive prompts, exit codes, formatting toggles.
  - Translator: SQL fragment coverage.
- **Regression Strategy**
  - Maintain `tests/golden/` snapshots; diff in PR review.
  - Introduce release check `zig build sydraql-full-test` aggregating all suites.
  - Document manual validation steps for release candidate.

## Performance Targets by Query Class

- **Simple Range Scan (`SELECT value FROM series WHERE time BETWEEN ...`)**
  - Target latency < 50 ms for 100k points.
  - CPU utilisation < 1 core for single query.
- **Downsample with Aggregation (`GROUP BY time_bucket(1m, time)`)**
  - Target throughput 500k points/sec per core.
  - Memory footprint < 64 MB per query for default bucket sizes.
- **Rate Functions (`rate`, `irate`)**
  - Allow 200k points/sec, ensure accuracy vs double precision baseline.
- **Deletion (`DELETE`)**
  - Tombstone creation < 30 ms for 1h window on single series.
  - Compactor handoff metrics emitted within 5 s.
- **Translator Path (SQL → sydraQL)**
  - Translation latency < 5 ms for typical SELECT.
  - Report unsupported constructs with actionable hints in < 1 ms overhead.

## Data & Fixture Strategy

- **Synthetic Dataset Generation**
  - Use `tools/gen-timeseries.zig` to build deterministic datasets for tests (seeded RNG).
  - Provide multiple profiles: `dense_series`, `sparse_series`, `counter_series`, `multi_tag`.
- **Real Trace Replay**
  - Obtain anonymised production traces and store under `tests/data/replay/` encrypted (access controlled).
  - Build replay harness to feed traces through engine for performance and correctness.
- **Fixtures Naming Convention**
  - `series_<metric>_<granularity>.json` for raw points.
  - `rollup_<metric>_<bucket>.json` for rollup segments.
  - Document location in README for easy discovery.

## Toolchain & Developer Experience Enhancements

- Provide VS Code snippets/task configs for running parser/engine tests quickly.
- Add `justfile` or `Makefile` shortcuts (`just parser-tests`, `just engine-bench`).
- Integrate Zig language server diagnostics to highlight sydraQL doc grammar mismatches.
- Deliver onboarding guide via [Quickstart](../getting-started/quickstart.md) + [Contributing](./contributing.md) with step-by-step environment setup.

## Open Follow-Up Work (Post-v0 Backlog Seeds)

- Multi-series expression support beyond `JOIN TIME`.
- User-defined functions and macros.
- Materialized views / persisted rollups management commands.
- Query caching and result pagination beyond basic limits.
- Advanced security (row-level ACLs) for multi-tenant deployments.

## Governance & Communication

- Weekly sydraQL sync covering phase burndown, blockers, metrics.
- Shared dashboard tracking phase completion, test status, and performance targets.
- Release readiness reviews at Phase 4, Phase 6, and Phase 8 gates with stakeholders from storage, ops, and product.

This roadmap should be reviewed at the end of each phase and adjusted as implementation feedback arrives. Align issues in the [sydraQL backlog](./sydraql-backlog.md) with the phase headers above to keep backlog prioritisation transparent.
