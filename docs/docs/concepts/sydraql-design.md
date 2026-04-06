---
sidebar_position: 2
tags:
  - sydraql
  - design
---

# sydraQL Design

This document defines the initial design for sydraQL, the native time-series query language for SydraDB. It complements the engineering roadmap in [Development: sydraQL roadmap](../development/sydraql-roadmap.md) and sets the scope for lexer/parser, planning, and execution work.

Implementation reference (current code):

- HTTP surface: [HTTP API – `POST /api/v1/sydraql`](../reference/http-api.md#post-apiv1sydraql) and [`handleSydraql`](../reference/source/sydra/http.md#fn-handlesydraql-void)
- Query pipeline: [overview](../reference/source/sydra/query/overview.md), [lexer](../reference/source/sydra/query/lexer.md), [parser](../reference/source/sydra/query/parser.md), [validator](../reference/source/sydra/query/validator.md)
- Planning/execution: [logical plan](../reference/source/sydra/query/plan.md), [optimizer](../reference/source/sydra/query/optimizer.md), [physical plan](../reference/source/sydra/query/physical.md), [operators](../reference/source/sydra/query/operator.md)
- PostgreSQL translation: [translator](../reference/source/sydra/query/translator.md) and [compatibility matrix](../reference/postgres-compatibility/compat-matrix-v0.1.md)

Note: this doc is a design target; the “Source Reference” pages describe what is implemented today.

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

## Stable v0 subset

For the current `v0.4.0` alpha cycle, the user-facing contract is intentionally narrower than the aspirational grammar sketches that follow.

Supported and exercised today:

- `SELECT` against one resolved series or `by_id(...)`
- projections over `time`, `value`, and `tag.*`
- raw-row scalar functions currently exercised on the compiled path:
  - `abs`, `ceil`, `floor`, `round`, `sqrt`, `ln`, `pow`, `coalesce`
- aggregate queries using:
  - `min`, `max`, `avg`, `sum`, `count`, `first`, `last`
- grouping by:
  - one `time_bucket(...)`
  - one selector tag such as `tag.host`
  - or the combination `time_bucket(...)` plus one selector tag
- ordering by projection aliases or projected expressions on the supported raw-row path
- `EXPLAIN BYTECODE` and `EXPLAIN TABLES_USED`

Explicitly out of the current compiled subset:

- selector `tag_filter` syntax on the `FROM` selector itself
- `fill(...)` on the compiled path
- broader window-function coverage (`moving_avg`, `ema`, `lag`, `lead`)
- regex predicates as part of the compiled VM path
- multi-series expressions / joins

When a query falls outside the compiled subset, the current contract is to fall back visibly or fail explicitly rather than pretend broader support.

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
- Keywords are case-insensitive.
- Unquoted identifiers follow `[A-Za-z_][A-Za-z0-9_]*`; dotted identifiers such as `weather.room1` and `tag.host` are accepted.
- Quoted identifiers are supported.
- Literals currently exercised in parser/tests:
  - integers and floats (`123`, `3.14`)
  - strings (`'foo'`)
  - durations (`5m`, `1h`)
  - ISO-8601 timestamps
  - booleans (`true`, `false`)
  - `null`
- Comments: `-- line comment`, `/* block comment */`.
- JSON literal handling remains restricted to insert-style payloads rather than general query expressions.

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

The current handwritten parser and generated shadow parser already implement a concrete precedence ladder for the supported subset.

## Expression precedence (current contract)

Highest to lowest:

1. parenthesized expressions and function calls
2. unary `+`, unary `-`, `not`
3. `*`, `/`, `%`
4. `+`, `-`
5. comparison operators: `=`, `!=`, `<`, `<=`, `>`, `>=`, `=~`, `!~`
6. logical `and` / `&&`
7. logical `or` / `||`

Notes:

- `ORDER BY` direction defaults to ascending when omitted.
- `LIMIT` may include `OFFSET`.
- `time_bucket(step, time [, origin])` is the only bucketed grouping form in the supported compiled subset.

## Function Library
- **Compiled today**
  - Aggregates: `min`, `max`, `avg`, `sum`, `count`, `last`, `first`
  - Scalar transforms: `abs`, `ceil`, `floor`, `round`, `pow`, `ln`, `sqrt`, `coalesce`
  - Time utility: `time_bucket(step, ts [, origin])`
- **Declared in metadata but not part of the supported compiled subset yet**
  - `percentile`, `rate`, `irate`, `delta`, `integral`, `moving_avg`, `ema`, `lag`, `lead`, `fill_forward`

The source of truth for the registry is [`src/sydra/query/functions.zig`](/Users/rexliu/sydradb/src/sydra/query/functions.zig), but the supported compiled subset above is the public contract for this alpha.

## Execution Semantics
- **Implicit ordering**: do not rely on implicit ordering as a stable contract; use `order by` when ordering matters.
- **Time zone**: all timestamps normalised to UTC; `now()` uses server clock in UTC.
- **Bucket exclusivity**: `time_bucket(step, ts)` aligns to `[start, start+step)` half-open intervals.
- **Fill evaluation**: `fill(...)` parses today but is not part of the supported compiled subset.
- **Null handling**: aggregates follow SQL semantics (`count` ignores nulls, `sum` returns null if all null).
- **Limits**: apply after aggregation/order by; planner should push down `LIMIT` when possible.

## Error Model
- Semantic errors map to dedicated codes (e.g., `ERR_TIME_RANGE_REQUIRED`, `ERR_UNSUPPORTED_FILL`).
- Parser surfaces helpful spans; translator remaps SQLSTATE to sydraQL codes where necessary.
- Hard caps on result points (`MAX_POINTS`) and runtime (`MAX_QUERY_DURATION`) fail with informative messages.

## Integration & Compatibility
- PostgreSQL translator targets sydraQL AST: only SQL constructs with direct translation are accepted; others produce explicit SQLSTATE warnings.
- Document mapping table: [PostgreSQL compatibility matrix](../reference/postgres-compatibility/compat-matrix-v0.1.md) enumerating supported SQL features and their sydraQL equivalents.
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
- How far do we want to widen the compiled subset before `v0.4.0` versus leaving the rest as explicit fallback?
- How do we expose rollup metadata (system tables vs. planner introspection) for users to inspect?
- Should inserts accept structured fields beyond a single numeric value in v0?
- What retention/TTL semantics should `DELETE` enforce when interacting with compaction?

Feedback welcome—update this document as decisions land or scope evolves.

## See also

- [Source: query errors and diagnostics](../reference/source/sydra/query/errors.md)
- [Development: sydraQL roadmap](../development/sydraql-roadmap.md)
