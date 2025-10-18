# sydraDB Architecture & Engineering Design (Supplementary, Oct 18 2025)

This document extends the existing design records to describe recently introduced
query planning and execution components.

## SydraQL Query Pipeline

1. **Parsing** (`src/sydra/query/parser.zig`)
   - Parses sydraQL statements into a high-level AST. Projections now capture
     optional aliases (`ast.Projection`) to preserve user-facing column names.
   - Temporal predicates, grouping clauses, fill options, and orderings surface
     in the AST for downstream stages.

2. **Logical Planning** (`src/sydra/query/plan.zig`)
   - Builder converts AST into a logical plan DAG (`Scan`, `Filter`, `Project`,
     `Aggregate`, `Sort`, `Limit`).
   - Logical nodes store detailed metadata (column info, rollup hints,
     conjunctive predicates). `plan.nodeOutput` exposes column schemas for
     consumers.

3. **Optimization** (`src/sydra/query/optimizer.zig`)
   - Performs projection pruning and predicate pushdown across projects, sorts,
     limits, and aggregates. Uses structural expression matching to recognize
     grouping predicates (including alias-based and computed expressions).
   - Ensures rollup hints and filter metadata stay consistent through rewrites.

4. **Physical Planning** (`src/sydra/query/physical.zig`)
   - Translates logical nodes into execution-oriented nodes carrying operator
     hints: filter time bounds, aggregate hash/fill requirements, sort
     stability, limit offsets, etc.
   - Propagates filter-derived time ranges down to scans to aid storage
     selection.

5. **Execution** (`src/sydra/query/executor.zig`)
   - Executor now operates on an existing `Engine` instance supplied by the
     caller. It walks the physical plan, builds iterator-style operators, and
     surfaces an `ExecutionCursor` (columns + lazy row stream) so downstream
     surfaces can consume results without pre-buffering everything.
- Operator coverage:
  * `Scan`: pulls points via `Engine.queryRange`, mapping them into the
    canonical `[time,value]` column schema with new row value wrappers.
  * `Filter`: evaluates full boolean expressions (including alias/lookups)
    against streaming rows using the shared expression resolver.
  * `Project`: reshapes rows via the same resolver, handling multiple
    projections, aliases, and scalar function calls.
  * `Aggregate`: supports grouped aggregations (`avg`, `sum`, `count`) and
    synthesises grouping keys into iterator output.
  * `Sort`: still spools when no limit is present, but cooperates with
    downstream limits to retain only the required top-N rows before emitting.
  * `Limit`: streaming pass-through (offset + take) so cursors no longer buffer
    entire result sets when pagination is requested.

## Engine Integration Notes

- The executor reuses the server's long-lived `Engine` instance and defers
  materialisation to the iterator chain returned to callers.
- Shared expression evaluation now underpins filter/project/aggregate stages,
  enabling alias-aware lookup and arithmetic without duplicating logic per
  operator.
- Scan execution still leverages `Engine.queryRange`, but the surrounding
  operator pipeline now preserves lazy semantics for downstream streaming.
- HTTP `/api/v1/sydraql` streams rows and appends execution stats (row count,
  stream duration, parse/validate/plan timings, trace id) in-line, while the
  pgwire bridge forwards row metadata and includes the same counts/timings +
  trace id in the `CommandComplete` tag for correlation.

## Next Steps

1. Refine materialising operators (`Sort`, `Limit`) to operate in a streaming
   fashion or push work down into storage primitives.
2. Enrich HTTP/PG responses with execution metadata (timings, trace ids) while
   keeping the streamed row contract intact.
3. Introduce operator fusion opportunities (e.g., scan+filter pushdown) once
   correctness is locked in.
