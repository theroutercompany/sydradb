---
title: "ADR 0007: Sharded Small-Pool Allocator Implementation Plan"
sidebar_position: 7
---

# ADR 0007: Sharded Small-Pool Allocator Implementation Plan

## Status
Accepted

## Context
We need a custom allocator that meets the performance and telemetry expectations outlined in [ADR 0006](./0006-git-inspired-data-model.md) and the [supplementary architecture design](../../architecture/supplementary-design-2025-10-18.md). The allocator must deliver predictable tail latency for tiny allocations, isolate shard contention, and provide strong instrumentation hooks. This document captures the detailed implementation plan before we start modifying the allocator core.

Implementation reference (current code):

- Allocator entrypoints and stats: [`src/sydra/alloc.zig`](../../reference/source/sydra/alloc/alloc-zig.md)
- Slab shard implementation: [`src/sydra/alloc/slab_shard.zig`](../../reference/source/sydra/alloc/slab-shard.md)
- Bench harness: [`tools/bench_alloc.zig`](../../reference/source/tools/bench-alloc.md)
- Telemetry surfaces: [CLI `stats`](../../reference/cli.md#stats) and [HTTP `/debug/alloc/stats`](../../reference/http-api.md#debug-endpoints)

## Workload & Constraints
- Hot objects: 16–256 B, bursty, multi-writer with many concurrent readers.
- Requirements:
  * Tail latency improvements (≥30% p99, ≥20% p999).
  * Predictable reclamation via epoch/QSBR.
  * Stable RSS during churn (±10%).
  * Rich telemetry (shard occupancy, contention, deferred queues).

## High-Level Architecture
- Per-core slab shards with fixed-size classes matched to hot object sizes.
- Thread-local shard selection (TLS) for constant-time lookup.
- Epoch-based deferred reclamation for cross-shard frees.
- Instrumentation across shards and fallback paths.
- Bench harness extensions to validate improvements.

## Implementation Phases

### Phase 1 – ShardManager & TLS Wiring
*Status: completed (`SmallPoolAllocator.ShardManager`, unit test “shard manager assigns per-thread shards”)*
**Decisions**
- `ShardManager` owns an array of `Shard` instances plus a fallback allocator.
- Threads obtain a shard ID via TLS; initial assignment can use round-robin on creation.
- `SmallPoolAllocator.init` optionally creates the `ShardManager` when sharding is enabled.

**Tasks**
1. Implement `ShardManager` (`init`, `deinit`, `currentShard`, `fallback`).
2. Add TLS helper (`threadlocal var thread_shard_id`) and atomic counter for round-robin.
3. Extend `SmallPoolAllocator` struct with optional `ShardManager`.
4. Expose configuration via build options (`-Dallocator-shards`, fallback for disabled state).

**Validation**
- Unit test confirming two threads map to different shard IDs.

### Phase 2 – Integrate Shard Alloc/Free into Fast Path
*Status: completed (`SmallPoolAllocator.allocInternal/freeFn`, stats surfaced via `snapshotSmallPoolStats()` and tested)*
**Decisions**
- Allocation order: shard → legacy bucket → GPA fallback.
- Free order mirrors allocation.
- Track counters for shard hits/misses and legacies.

**Tasks**
1. Update `slab_shard.Shard.allocate/free` to consume the shared GPA (ret_addr for debug).
2. Modify `SmallPoolAllocator.allocInternal`/`freeFn` to try shard manager first.
3. Record metrics (`shard_allocs`, `shard_frees`, `fallback_allocs`, etc.).

**Validation**
- Unit tests for shard allocation success, fallback on oversize requests, cross-shard free returning true.

### Phase 3 – Epoch/QSBR Reclamation
*Status: largely complete; debug assertions plus deferred snapshot tests added; remaining instrumentation tracked in Phase 4/5.*
**Decisions**
- Each shard keeps a `current_epoch`, `deferred` queue, and per-thread observation map.
- Writers push cross-shard frees into deferred list tagged with current epoch.
- `collectGarbage` moves nodes back to freelist once the minimum observed epoch surpasses the node’s epoch.
- Provide `enterEpoch/leaveEpoch` for readers, called around long-lived operations.

**Status**
- Implemented `Shard.freeDeferred`, aggregated epoch tracking (`global_epoch`, `thread_epoch`), and manager wrappers (`enterEpoch/leaveEpoch/advanceEpoch`).
- Cross-shard frees now enqueue into deferred lists and are recycled via `collectGarbage()`.

**Tasks**
1. Extend `FreeNode` with `class_state` (already present) and new `epoch` metadata.
2. Implement `Shard.deferFree` and `Shard.collectGarbage`.
3. Add manager-wide APIs to advance epochs and record thread observations (TLS map).
4. Debug assertions: ensure `FreeNode.class_state` matches target shard, no double-free.

**Validation**
- Unit test: thread A allocates, thread B frees, deferred queue increments, `collectGarbage` returns node after epoch advancement.

### Phase 4 – Instrumentation & Stats
**Decisions**
- Extend `SlabStats` to report:
  * `deferred_count`, `current_epoch`, `min_observed_epoch`.
  * Contention metrics (wait/hold time, attempted cross-shard frees).
- `snapshotSmallPoolStats` merges legacy buckets + shard stats.
- Expose new stats via `AllocatorHandle`.

**Status**
- Stats struct now aggregates shard hits/misses, deferred totals, and epoch bounds; bench driver emits the new metrics.

**Tasks**
1. Add atomic counters in `slab_shard`.
2. Update `alloc.zig` stats structs & HTTP/CLI telemetry surfaces.
3. Document metrics in README/supplementary doc.

**Validation**
- Tests verifying stats reflect usage after simulated workloads.
- Manual check via `zig build run -- stats`.

### Phase 5 – Benchmarks & Stress Tests
**Decisions**
- Extend `tools/bench_alloc` with options:
  * `--allocator=sharded` to drive new path.
  * Shard count selection.
  * Output p50/p95/p99/p999, deferred counts, fallback counts.
- Provide stress test scenario for cross-thread churn to validate epoch logic.

**Tasks**
1. Instrument bench to record new metrics.
2. Add multi-threaded Zig tests (guarded by `std.testing` concurrency allowances).
3. Optionally add debug-only slab poisoning to catch use-after-free.

**Validation**
- Compare metrics against acceptance criteria.
- Ensure regression checks fail loudly if deferred queue spikes or contention climbs.

**Status**
- `tools/bench_alloc` now emits latency percentiles, shard/fallback counters, and an optional `--stress-seconds` churn harness that records deferred backlog and latency drift. Outputs feed into regression comparisons.

### Phase 6 – Documentation & Cleanup
- Update README and design doc with new allocator options, metrics, expected behavior.
- Add diagrams or tables summarizing shard architecture.
- Ensure code comments describe tricky bits (TLS, epoch reclamation).
- Surfaced shard/fallback metrics through CLI `sydradb stats` and HTTP `/debug/alloc/stats` for live inspection.

## Risks & Mitigations
- **Cross-shard misuse**: rely on debug assertions and unit tests; document API expectations.
- **Epoch overhead**: keep TLS data lightweight; only long-lived operations call `enterEpoch`.
- **Fallback pressure**: monitor fallback counters; adjust slab classes once telemetry shows distribution.
- **Concurrency bugs**: use atomics and per-shard locks carefully; keep critical sections short.

## References
- [ADR 0006](./0006-git-inspired-data-model.md) (allocator section)
- [Supplementary architecture design](../../architecture/supplementary-design-2025-10-18.md)
- Current implementation: [`src/sydra/alloc.zig`](../../reference/source/sydra/alloc/alloc-zig.md), [`src/sydra/alloc/slab_shard.zig`](../../reference/source/sydra/alloc/slab-shard.md), [`tools/bench_alloc.zig`](../../reference/source/tools/bench-alloc.md)
