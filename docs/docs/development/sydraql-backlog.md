---
sidebar_position: 7
---

# sydraQL backlog (snapshot)

This page captures a small, curated backlog for sydraQL work. It originated as a CSV export and is kept here as a linkable, searchable checklist.

Primary planning doc:

- [sydraQL Engineering Roadmap](./sydraql-roadmap.md)

Implementation reference:

- [Query pipeline overview](../reference/source/sydra/query/overview.md)
- [HTTP API – `POST /api/v1/sydraql`](../reference/http-api.md#post-apiv1sydraql)

## Items

### sydraQL: language goals & scope

- Labels: `sydraQL`, `docs`, `design`, `M2`
- Milestone: `M2 Core`
- Notes: Define sydraQL goals: TS-first query language with time windows, tag filters, rollups, math, joins on time, and alert expressions. Non-goals: arbitrary cross-series joins, complex UDFs v1.

### sydraQL: lexical syntax & tokens

- Labels: `sydraQL`, `parser`, `design`, `M2`
- Milestone: `M2 Core`
- Notes: Durations (`1s`, `5m`, `1h`, `1d`), timestamps (ISO8601/epoch), identifiers, string/number literals, comments, keywords.

### sydraQL: EBNF grammar v0

- Labels: `sydraQL`, `parser`, `design`, `M2`
- Milestone: `M2 Core`
- Notes: Write EBNF for `SELECT`, `FROM` series, `WHERE` (time & tag filters), `GROUP BY time()`, `FILL`, `ORDER/LIMIT/OFFSET`, functions.

### sydraQL: doc with examples

- Labels: `sydraQL`, `docs`, `M2`
- Milestone: `M2 Core`
- Notes: Examples for range scans, downsampling, tag filters, math, joins-on-time, alert predicates.

### sydraQL: lexer in Zig

- Labels: `sydraQL`, `parser`, `zig`, `M2`
- Milestone: `M2 Core`
- Notes: Implement zero-copy lexer with slice-based tokens; error spans and messages.

### sydraQL: parser + AST

- Labels: `sydraQL`, `parser`, `zig`, `M2`
- Milestone: `M2 Core`
- Notes: Recursive-descent parser building typed AST structs; recover from minor errors for better UX.

### sydraQL: duration/timezone parsing

- Labels: `sydraQL`, `time`, `M2`
- Milestone: `M2 Core`
- Notes: Support `s/m/h/d/w` durations; ISO8601 with timezone; default tz; `now()` builtin.

### Planner: logical plan

- Labels: `sydraQL`, `planner`, `M2`
- Milestone: `M2 Core`
- Notes: Translate AST to logical ops: Scan, Filter, Project, Agg(window), Sort, Limit, JoinTime.

### Planner: rule-based rewrites

- Labels: `sydraQL`, `planner`, `perf`, `M2`
- Milestone: `M2 Core`
- Notes: Predicate pushdown (time/tag), rollup selection, projection pruning, filter simplification.

### Execution: operators

- Labels: `sydraQL`, `engine`, `perf`, `M2`
- Milestone: `M2 Core`
- Notes: Implement operators for Scan/Filter/Project/Aggregate/Sort/Limit; streaming iterators.

### Execution: group-by time windows

- Labels: `sydraQL`, `engine`, `agg`, `M2`
- Milestone: `M2 Core`
- Notes: `time_bucket(step, ts[, origin])` and tumbling windows; partial agg combine for parallelism.

### Execution: downsample selection

- Labels: `sydraQL`, `planner`, `downsampling`, `M2`
- Milestone: `M2 Core`
- Notes: Planner chooses rollup series (1m/5m/1h) when query step >= rollup; fall back to raw.

### Execution: join on time

- Labels: `sydraQL`, `engine`, `join`, `M2`
- Milestone: `M2 Core`
- Notes: ALIGN JOIN: align two series by time bucket (nearest/forward-fill); constraints: same step/zone.

### Nulls & fill policy

- Labels: `sydraQL`, `engine`, `semantics`, `M2`
- Milestone: `M2 Core`
- Notes: `fill(prev|linear|null|number)` semantics; per-series and per-select-item control.

### Limits & quotas

- Labels: `sydraQL`, `engine`, `reliability`, `M2`
- Milestone: `M2 Core`
- Notes: `MAX_POINTS`, `MAX_SERIES` per query; timeout; memory budgeting; error codes.

### Function registry & type system

- Labels: `sydraQL`, `functions`, `M2`
- Milestone: `M2 Core`
- Notes: Register scalar funcs (abs, ln, pow), aggs (min,max,avg,sum,count,last,rate,irate,delta), and time funcs.

### Window/derivative functions

- Labels: `sydraQL`, `functions`, `agg`, `M2`
- Milestone: `M2 Core`
- Notes: `moving_avg`, exponential moving average, `rate/irate`, `delta/integral` with step-aware logic.

### Tag filter syntax

- Labels: `sydraQL`, `design`, `parser`, `M2`
- Milestone: `M2 Core`
- Notes: `AND/OR/NOT`, `=`, `!=`, `=~`, `!~` operators on tags; exact vs regex; case sensitivity doc.

### HTTP endpoint: `/api/v1/sydraql`

- Labels: `sydraQL`, `api`, `http`, `M2`
- Milestone: `M2 Core`
- Notes: `POST text/plain` sydraQL → JSON result; stream chunks; include query stats.

### CLI: `sydradb query`

- Labels: `sydraQL`, `cli`, `tooling`, `M2`
- Milestone: `M2 Core`
- Notes: `sydradb query -f query.sq` or stdin; table/CSV/JSON output; `--pretty` and `--raw` flags.

### Docs: compatibility notes

- Labels: `sydraQL`, `docs`, `M2`
- Milestone: `M2 Core`
- Notes: Compare sydraQL to InfluxQL/PromQL; mapping guide; what’s intentionally different.

### Conformance tests

- Labels: `sydraQL`, `testing`, `M2`
- Milestone: `M2 Core`
- Notes: Golden tests: query → result; fuzzing parser; randomized window/agg tests.

### Benchmarks

- Labels: `sydraQL`, `perf`, `benchmarks`, `M2`
- Milestone: `M2 Core`
- Notes: Microbenchmarks for parser, planner, and operator throughput; end-to-end query p50/p95.

