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

## Allocator Strategy Roadmap

SydraDB's ingest path continues to bias toward *many tiny writes* across
concurrent writers. The general-purpose Gpa allocator remains serviceable, but
tail-latency spikes surface whenever bursts contend for the global heap. We are
standardising on a layered allocator strategy purpose-built for this workload:

1. **mimalloc baseline**
   - Build targets now link mimalloc by default (still overridable via
     `-Dallocator-mode=default`) so per-thread caches and tight small-object
     classes become the fast path without extra flags.
   - Keep mimalloc's chunk recycling enabled for steady RSS and expose knobs to
     tune its release-to-OS behaviour in perf profiles.
2. **Sharded memory pools (SMP)**
   - Introduce shard-local fixed-size slabs for the common shapes on the write
     path (ingest headers, skip-list nodes, tombstones, metadata records).
   - Target initial bins at 16/24/32/48/64/96/128/192/256 bytes; trim once
     telemetry lands. Each shard owns its slab freelists to avoid cross-core
     locking.
   - Initial scaffolding (`src/sydra/alloc/slab_shard.zig`) now models shard
     configuration and lifetime management; pass `-Dallocator-shards=<N>` with
     `-Dallocator-mode=small_pool` to enable the sharded path.
   - Epoch APIs (`AllocatorHandle.enterEpoch/leaveEpoch/advanceEpoch`) and
     deferred free queues exist, forming the basis for QSBR reclamation.
3. **Append-only arenas**
   - WAL and memtable segments allocate via per-segment bump allocators;
     compaction or sealing drops the whole arena in one operation.
4. **Epoch/QSBR reclamation**
   - Writers recycle objects into a shard-local quarantine; a lightweight epoch
     counter ensures readers have advanced before slabs are returned to service.
   - Embed shard identifiers in headers to guarantee objects are freed on the
     owning shard.
5. **Instrumentation and guard rails**
   - Record allocation histograms, slab occupancy, and lock hold durations; emit
     metrics through the allocator benchmark and runtime telemetry.
   - In debug builds, poison freed slabs and assert shard ownership to catch
     violations early.

Success criteria: ≥30% improvement in p99 allocation latency and ≥20%
improvement in p999 ingest latency under the mixed read/write microbench, RSS
stability within ±10% over a 30‑minute churn test, and zero cross-shard free
violations in stress tests. Benchmarks must cover 2k/20k/200k op loads with the
new diagnostics to document regressions and wins.
