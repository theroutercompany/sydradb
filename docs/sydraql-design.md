# sydraQL Design

This document defines the initial design for sydraQL, the native time-series query language for sydraDB. It expands on the backlog in `docs/sydraQL-issues.csv` and sets the scope for the parser, planner, and execution work.

## Goals
- **Time-series first**: expressive range scans, tag filters, downsampling, and rates without exposing the full SQL surface.
- **Deterministic**: explicit defaults (time zone, fill policy, ordering) to keep queries reproducible.
- **Composable**: modular AST and logical plan nodes that translate cleanly to execution iterators.
- **Translatable**: the PostgreSQL compatibility layer can map supported SQL fragments into sydraQL.
- **Optimisable**: language constructs map directly to storage features (rollups, tag indexes, WAL metadata).

## Non-Goals (v0)
- Arbitrary cross-series joins or cartesian products.
- User-defined functions, stored procedures, or arbitrary SQL expressions.
- Multi-statement transactions or DDL.
- Full SQL compatibility (handled by the translator with best-effort coverage).

## Data Model Assumptions
- **Series** addressed by `series_id` or `(namespace, metric)` plus tags.
- **Points** stored as `(timestamp, value[, field map])`.
- **Tags / Labels** represented as string key-values.
- **Rollups** (e.g. 1m, 5m, 1h) maintained in storage and selectable by the planner.

## Query Model
sydraQL exposes a small number of statement types:

| Statement | Shape | Notes |
|-----------|-------|-------|
| `SELECT` | `select <expr_list> from <selector> [where …] [group by …] [fill …] [order by …] [limit …]` | range scans, filtering, aggregation |
| `INSERT` | `insert into <series> [(tags)] values (<ts>, <value>[, <json>])` | streaming ingest |
| `DELETE` | `delete from <series> where time >= … and time < … [and tags …]` | retention / manual deletes |
| `EXPLAIN` | `explain <select>` | planner debugging (future) |

### Selectors
```
selector := series_ref [tag_filter]
series_ref := by_id(<int>) | 'namespace.metric'
tag_filter := where <tag_predicate>
```

### Temporal Predicates
```
time >= 2024-03-01T00:00:00Z and time < 2024-03-02T00:00:00Z
time between now() - 1h and now()
```

### Tag Predicates
```
tag.city = "ams" and tag.host != "cache-01"
tag.env =~ /prod|staging/ or tag.team !~ /^infra/
```

### Aggregations & Windows
```
group by time_bucket(5m, time [, origin]), tag.datacenter
select avg(value), max(value), percentile(value, 0.99)
```

### Fill Policies
```
fill(previous)      -- carry forward last value
fill(linear)        -- interpolate between buckets
fill(null)          -- default
fill(0)             -- constant
```

### Ordering & Limits
```
order by time asc
limit 1000 [offset N]
```

## Syntax Overview
- Case-insensitive keywords, case-sensitive identifiers unless quoted.
- Identifiers follow `[A-Za-z_][A-Za-z0-9_]*` or quoted `"mixed-case"`.
- Literals: numbers (`123`, `3.14`), strings (`'foo'`), durations (`1s`, `5m30s`, `2h`), ISO8601 timestamps, epoch ints.
- Comments: `-- line comment`, `/* block comment */`.
- Functions & operators use lower-case names: `avg`, `rate`, `delta`, `abs`, `ln`.
- JSON literal support restricted to insert payloads.

## Grammar Sketch (EBNF)
```
query          = select_stmt | insert_stmt | delete_stmt | explain_stmt ;
select_stmt    = "select" select_list "from" selector [where_clause] [group_clause]
                 [fill_clause] [order_clause] [limit_clause] ;
select_list    = select_item { "," select_item } ;
select_item    = expr [ "as" ident ] ;
selector       = series_ref [ tag_filter ] ;
series_ref     = ident | "by_id" "(" int_lit ")" ;
tag_filter     = "where" bool_expr ;
where_clause   = "where" bool_expr ;
group_clause   = "group" "by" group_item { "," group_item } ;
group_item     = "time_bucket" "(" duration "," expr ["," expr] ")" | expr ;
fill_clause    = "fill" "(" fill_spec ")" ;
order_clause   = "order" "by" order_item { "," order_item } ;
limit_clause   = "limit" int_lit [ "offset" int_lit ] ;
order_item     = expr [ "asc" | "desc" ] ;
bool_expr      = bool_term { ("or" | "||") bool_term } ;
bool_term      = bool_factor { ("and" | "&&") bool_factor } ;
bool_factor    = ["not"] bool_primary ;
bool_primary   = comparison | "(" bool_expr ")" ;
comparison     = expr comp_op expr | tag_predicate | time_predicate ;
comp_op        = "=" | "!=" | "<" | "<=" | ">" | ">=" | "=~" | "!~" ;
expr           = additive_expr ;
```

(Full grammar will enumerate arithmetic, function calls, literals, and precedence levels.)

## Function Library
- **Aggregates**: `min`, `max`, `avg`, `sum`, `count`, `last`, `first`, `percentile(value, 0.99)`.
- **Transformations**: `abs`, `ceil`, `floor`, `round`, `pow`, `ln`, `sqrt`.
- **Time utilities**: `now()`, `time_bucket(step, ts, [origin])`, `lag`, `lead`.
- **Rates/Windows**: `rate`, `irate`, `delta`, `integral`, `moving_avg`, `ema(step, alpha)`.
- **Fill helpers**: `coalesce`, `fill_forward`.

Each function entry should specify argument types, return type, and planner capabilities (e.g., `rate` requires sorted series).

## Execution Semantics
- **Implicit ordering**: results are ordered by timestamp ascending unless `order by` given.
- **Time zone**: all timestamps normalised to UTC; `now()` uses server clock in UTC.
- **Bucket exclusivity**: `time_bucket(step, ts)` aligns to `[start, start+step)` half-open intervals.
- **Fill evaluation**: applied post-aggregation per `group by` bucket.
- **Null handling**: aggregates follow SQL semantics (`count` ignores nulls, `sum` returns null if all null).
- **Limits**: apply after aggregation/order by; planner should push down `LIMIT` when possible.

## Error Model
- Semantic errors map to dedicated codes (e.g., `ERR_TIME_RANGE_REQUIRED`, `ERR_UNSUPPORTED_FILL`).
- Parser surfaces helpful spans; translator remaps SQLSTATE to sydraQL codes where necessary.
- Hard caps on result points (`MAX_POINTS`) and runtime (`MAX_QUERY_DURATION`) fail with informative messages.

## Integration & Compatibility
- PostgreSQL translator targets sydraQL AST: only SQL constructs with direct translation are accepted; others produce explicit SQLSTATE warnings.
- Document mapping table (`compatibility.md` appendix) enumerating supported SQL features and their sydraQL equivalents.
- HTTP API responds with JSON: metadata (execution stats, trace ids) plus rows.

## Implementation Roadmap
1. **Language spec** – finalise this doc, publish examples, crosslink to backlog.
2. **Lexer & parser** – implement zero-copy tokenizer, recursive-descent parser, semantic validation hooks.
3. **AST → logical plan** – define nodes (`Scan`, `Filter`, `Project`, `Aggregate`, `JoinTime`, `Limit`, `Sort`).
4. **Planner passes** – predicate pushdown, rollup selection, projection pruning.
5. **Operator execution** – iterators leveraging storage segments, rollups, and in-memory aggregation buffers.
6. **HTTP & CLI** – expose `/api/v1/sydraql`, update CLI to submit queries, stream responses.
7. **Testing** – golden queries, fuzzing, planner snapshots, integration with storage fixtures.
8. **Observability** – metrics (parse/plan/exec timings), structured logs, explain output for debugging.

## Execution Telemetry
- HTTP responses from `/api/v1/sydraql` stream a `stats` object alongside rows. The object reports elapsed times for each pipeline phase (parse/validate/optimize/physical/pipeline), `rows_emitted`, `rows_scanned`, a random `trace_id`, and an `operators` array containing `{name, rows_out, elapsed_ms}` entries for every operator in the execution tree.
- pgwire command completion tags mirror the summary metrics (`rows`, `scanned`, `stream_ms`, `plan_ms`, optional `trace_id`). Additional `NOTICE` messages emit one line per operator with the same row counts and timings so libpq-compatible clients can surface diagnostics.
- These fields are intended for dashboards and tracing; clients should treat them as part of the public API.

## Open Questions
- Do we allow multi-series expressions in the first release (e.g., `select a.value / b.value` with alignment)?
- How do we expose rollup metadata (system tables vs. planner introspection) for users to inspect?
- Should inserts accept structured fields beyond a single numeric value in v0?
- What retention/TTL semantics should `DELETE` enforce when interacting with compaction?

Feedback welcome—update this document as decisions land or scope evolves.
