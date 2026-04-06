---
sidebar_position: 2
tags:
  - architecture
  - telemetry
  - api
  - operators
---

# Operator-first user-facing surface

This document defines the next user-facing SydraDB surface after the current `v0.4.0` alpha query and discovery endpoints. It is a **future-facing design target**, not a statement that the routes below already exist. The shipped contract remains the one documented in [HTTP API](../reference/http-api.md), [CLI](../reference/cli.md), and [sydraQL Design](../concepts/sydraql-design.md).

The design assumption is that SydraDB already has substantial lifecycle and storage internals in place: checkpointing, rollback, CAS-backed history, retention enforcement, and a compiled/legacy query split. The next outward-facing work should therefore make the database more useful for operators and SREs doing service health analysis, incident debugging, deploy/change correlation, and fleet-level telemetry exploration.

## Audience and priorities

Priority order for this milestone:

1. Operators and SREs
2. Application developers consuming operational telemetry
3. Platform and integration work

Delivery order for this milestone:

1. Query + HTTP API
2. Thin CLI wrappers over the same APIs where that materially improves workflows
3. UI later, reusing the same API contracts rather than inventing a parallel console-only model

## Current baseline

Implemented today:

- Exact-series ingestion and range reads over [`POST /api/v1/ingest`](../reference/http-api.md#post-apiv1ingest) and [`/api/v1/query/range`](../reference/http-api.md#post-apiv1queryrange)
- Basic discovery endpoints:
  - [`POST /api/v1/metrics/find`](../reference/http-api.md#post-apiv1metricsfind)
  - [`POST /api/v1/series/find`](../reference/http-api.md#post-apiv1seriesfind)
  - [`POST /api/v1/labels/values`](../reference/http-api.md#post-apiv1labelsvalues)
- Power-user query execution over [`POST /api/v1/sydraql`](../reference/http-api.md#post-apiv1sydraql)
- Telemetry-first ingest metadata backed by the current storage descriptors:
  - metric metadata in [`src/sydra/storage/metric_catalog.zig`](../reference/source/sydra/storage/overview.md)
  - series catalog metadata in [`src/sydra/storage/series_catalog.zig`](../reference/source/sydra/storage/overview.md)

Current gaps relative to operator workflows:

- Discovery is still narrow and mostly “find” oriented rather than inventory oriented.
- The public query surface still centers exact-series reads and a power-user sydraQL endpoint instead of stable operational result shapes.
- Query stats expose fallback and selector information, but not a complete operator-facing explanation of what data was scanned and why.
- There is no first-class annotation API for deploys, incidents, or maintenance windows.
- Retention and downsampling behavior exist operationally but are not yet exposed as user-facing query metadata.
- The CLI is still storage-heavy and exact-series-heavy rather than operator-workflow-heavy.

## Design principles

- **Telemetry first**: the default identity model is `metric` + flat `labels`.
- **Operator first**: optimize for “what changed?”, “who is failing?”, and “what exists?” rather than storage inspection.
- **One metric family per query**: keep the current scope boundary unless a separate multi-metric model is explicitly designed later.
- **HTTP before UI**: a future console should consume the same APIs the CLI and automation use.
- **Exact compatibility where already shipped**: preserve `series_id`, legacy `series` + `tags`, and existing `query/find` behavior.
- **Stable result shapes**: expose a small number of documented response envelopes instead of requiring users to reverse-engineer arbitrary table outputs.
- **Visible execution semantics**: queries should report selector mode, fallback, scanned rows/series, and storage tier in operator language.

## Identity model

The public identity model becomes:

- Primary: `metric` + flat `labels`
- Escape hatch: `series_id`
- Compatibility: legacy `series` + `tags`

Rules:

- `metric` identifies a metric family.
- `labels` remain a flat string map. No resource hierarchy is introduced in this milestone.
- `series_id` stays valid for exact lookups, bookmarks, and lower-level tooling, but it stops being the lead story in user-facing docs.
- Legacy `series` + `tags` remain supported until a later deprecation plan exists.

## Public descriptor types

The current metadata surface already contains the seeds of the future public types. The next API pass should make them explicit and stable.

### `MetricDescriptor`

Recommended public fields:

- `metric`
- `kind`
- `unit`
- `description`
- `label_keys`
- `active_series_count`
- `first_ts`
- `last_ts`
- `derived_from` (optional)
  - `metric`
  - `field`

Notes:

- `kind` should expand from the current `counter | gauge` model to also describe derived sibling relationships where applicable.
- The current metric catalog already records `source_metric` and `source_field`; this should become the basis of `derived_from`.

### `SeriesDescriptor`

Recommended public fields:

- `series_id`
- `metric`
- `labels`
- `first_ts`
- `last_ts`
- `recent_sample_count`
- `activity`
  - `status`: `active | inactive`
  - `lookback_seconds`

Notes:

- `activity.status` should be derived from a configured or request-provided lookback window instead of treated as immutable stored state.

### `LabelValueSummary`

Recommended public fields:

- `key`
- `value`
- `series_count`
- `metric_count`
- `first_ts`
- `last_ts`

### `Annotation`

Recommended public fields:

- `annotation_id`
- `kind`
- `title`
- `message`
- `start_ts`
- `end_ts`
- `labels`
- `links`
- `created_at`

## API families

The current live endpoints should stay supported. The next design pass should add higher-level API families that treat operator workflows as first-class.

### `/api/v1/metrics/*`

Purpose: catalog, health, inventory, and metadata quality.

Recommended endpoints:

| Endpoint | Purpose |
| --- | --- |
| `/api/v1/metrics/catalog` | list metric families with `MetricDescriptor` fields |
| `/api/v1/metrics/cardinality/top` | top high-cardinality metrics over a time window |
| `/api/v1/metrics/inactive` | metrics or metric families inactive for a time window |
| `/api/v1/metrics/metadata-gaps` | metrics missing `kind`, `unit`, or `description` |
| `/api/v1/metrics/retention` | retention/downsampling policy introspection for a metric family |

### `/api/v1/series/*`

Purpose: exact series discovery plus activity state.

Recommended endpoints:

| Endpoint | Purpose |
| --- | --- |
| `/api/v1/series/catalog` | enumerate exact series for one metric family |
| `/api/v1/series/active` | series active in a lookback window |
| `/api/v1/series/inactive` | series missing samples in a lookback window |
| `/api/v1/series/top` | most active or highest-volume series by metric family |

### `/api/v1/labels/*`

Purpose: label key/value discovery and cardinality hints.

Recommended endpoints:

| Endpoint | Purpose |
| --- | --- |
| `/api/v1/labels/keys` | list label keys, optionally scoped to one metric family |
| `/api/v1/labels/values` | list values for one key, with prefix filtering |
| `/api/v1/labels/cardinality` | report rough or exact series counts per value |

### `/api/v1/annotations/*`

Purpose: deployment, incident, maintenance, and arbitrary operator markers.

Recommended endpoints:

| Endpoint | Purpose |
| --- | --- |
| `/api/v1/annotations/write` | create deploy, incident, maintenance, or free-form annotations |
| `/api/v1/annotations/query` | fetch annotations by time window, label filter, and kind |
| `/api/v1/annotations/delete` | optional later lifecycle management |

### `/api/v1/query/*`

Purpose: stable operational query shapes built on one metric family at a time.

Recommended endpoints:

| Endpoint | Purpose |
| --- | --- |
| `/api/v1/query/range` | exact-series or grouped raw/bucket reads |
| `/api/v1/query/summary` | label-grouped summaries over a window |
| `/api/v1/query/rank` | ranked top-N outputs by label or series |
| `/api/v1/query/compare` | previous-window or baseline-window comparison |
| `/api/v1/query/saved/*` | named query definitions and replayable query ids |

`POST /api/v1/sydraql` remains the power-user and low-level programmable surface. The JSON endpoints above become the primary operator path.

## Query model

The query contract stays centered on **one metric family per query**. What changes is the set of supported operator-oriented shapes and the clarity of failure behavior.

### Stable result shapes

Documented, supported shapes should be:

| Shape | Description | Typical consumer |
| --- | --- | --- |
| `raw_points` | raw `(ts, value)` rows for one exact series | scripts, debugging |
| `time_buckets` | grouped buckets over one metric family, optionally partitioned by label | charts, alerts, CLI |
| `label_summaries` | one row per label value or label-set partition | fleet analysis |
| `rankings` | ranked series or label tables (top-N / bottom-N) | operations triage |
| `comparisons` | current window vs previous/baseline window | deploy and incident review |

### Supported operators

The useful operator subset should explicitly include:

- `rate`
- `irate`
- `delta`
- `percentile`
- `fill(previous)`
- `fill(0)`
- top-N aggregation by label
- group by label
- group by bucket + label
- previous-window comparison
- baseline-window comparison

Simple forecast or trend projection remains deferred.

### Query stats

Every operational query response should include enough metadata for a user to understand what happened without reading internal code or guessing from timings.

Recommended additions:

- `execution_mode`
- `selector_mode`
- `selected_series_count`
- `metric_kind`
- `storage_tier`
  - `raw`
  - `downsampled`
  - `mixed`
- `legacy_fallback`
- `fallback_reason`
- `rows_scanned`
- `rows_emitted`
- `series_scanned`

The current `selector_mode`, `selected_series_count`, and fallback fields already exist on the sydraQL path and should become part of the stable operator-facing contract rather than implementation detail.

### Failure semantics

Operator-facing failures should be explicit and stable.

Required rules:

- Raw row reads over multiple matching series must fail unless the request adds grouping, ranking, or aggregation.
- Unsupported shapes must return stable error codes rather than a generic query failure.
- Error payloads should recommend the next supported shape.

Recommended stable codes:

- `exact_series_required`
- `multi_series_raw_requires_grouping`
- `unsupported_query_shape`
- `metric_family_not_found`
- `label_not_found`
- `annotation_conflict`

## Discovery and inventory workflows

This milestone should turn basic discovery into full operator inventory.

First-class workflows:

- “What metrics exist for this service?”
- “Which label keys and values exist for this metric family?”
- “Which series are currently active?”
- “Which hosts stopped reporting?”
- “Which metrics are missing `kind`, `unit`, or `description`?”
- “Which metrics have suspiciously high label cardinality?”

The current `find` endpoints remain useful building blocks, but they should no longer be the full public discovery story.

## Annotations and adjacent TSDB features

Annotations are in scope because they directly support operator reasoning even though they are not raw metric data.

Supported annotation classes should include:

- deploy markers
- incident markers
- maintenance windows
- free-form operator notes

Constraints:

- Annotation overlays must never alter stored raw metric values.
- Annotation queries should filter by time window, kind, and labels.
- Saved queries should be able to link to annotations so an incident review can open the exact investigative query that was used.

## Retention and downsampling introspection

Retention and downsampling should become inspectable user-facing metadata.

Operator-visible questions:

- What retention policy applies to this metric family?
- Will this query hit raw data or downsampled data?
- What data will expire soon?

Recommended public fields:

- `retention_days`
- `raw_resolution`
- `downsample_resolutions`
- `query_storage_tier`
- `expires_before_ts`

The goal is visibility, not a full retention-management UI in this milestone.

## Saved queries and playbooks

Saved query primitives are in scope because they make operator workflows repeatable and shareable without requiring a separate console contract.

Minimum design:

- named query definitions
- typed parameters
- stable query ids
- replayable links
- optional annotation links

These should be transport-neutral: HTTP first, CLI wrappers second, UI later.

## CLI posture

The CLI should stay thin and map directly onto the HTTP contracts above. It should not grow a different business model from the API.

Recommended commands:

- `sydradb metric inspect`
- `sydradb labels values`
- `sydradb series top`
- `sydradb query compare`
- `sydradb annotation write`

The current exact-series `sydradb query <series_id> <start_ts> <end_ts>` command remains useful but should stop being the lead example for day-to-day operational usage.

## Documentation shift

The default product narrative should move from “hash a series and fetch rows” toward operator tasks:

- What changed after deploy?
- Which services are erroring fastest?
- Which hosts are missing metrics?
- What labels exist for this metric family?
- Show p95 latency by route for the last 30 minutes.
- Overlay incident or deploy annotations on this metric.

Storage lifecycle, CAS, rollback, and checkpointing docs remain important, but they should sit under internals and operations reference rather than as the default product story.

## Compatibility and scope boundaries

This design deliberately preserves the following:

- existing `/api/v1/query/find`
- existing `series_id` workflows
- legacy `series` + `tags`
- current single-series sydraQL behavior
- one metric family per query

This design deliberately defers:

- logs and traces
- full cross-signal observability
- multi-metric algebra
- forecasting and trend prediction
- hierarchical label/resource models
- a separate UI-only contract

## Suggested implementation slices

The work can be delivered incrementally without blocking on a UI:

### Slice 1: discovery and inventory

- widen metric, series, and label metadata
- add inventory endpoints for cardinality, inactivity, and metadata gaps
- promote `MetricDescriptor`, `SeriesDescriptor`, and `LabelValueSummary` to documented API types

### Slice 2: stable operator query shapes

- keep one-metric-family query scope
- add ranking, grouped summary, and compare endpoints
- formalize result-shape contracts and failure codes
- expose selector, fallback, and scanned-row stats everywhere

### Slice 3: annotations and retention visibility

- write/query annotations
- query-side annotation overlays
- retention/downsampling introspection

### Slice 4: saved queries, thin CLI, and docs rewrite

- stable saved query ids
- CLI wrappers for common operator workflows
- update getting-started and narrative docs around real operational tasks

## Validation plan

Core acceptance coverage should include:

- discovery tests for metric catalog fields, label vocabulary, and exact series activity windows
- query tests for exact-series selection, metric-family grouping, ranking, compare shapes, and explicit multi-series raw failures
- annotation tests ensuring overlays are queryable but never mutate metric values
- regression coverage for `series_id`, legacy `series` + `tags`, `query/find`, and existing single-series sydraQL results

## Relationship to existing docs

- Shipped API contract: [HTTP API](../reference/http-api.md)
- Current language design and supported query subset: [sydraQL Design](../concepts/sydraql-design.md)
- Runtime map: [Architecture overview](./overview.md)
- Storage and lifecycle internals: [Supplementary design](./supplementary-design-2025-10-18.md)

The intended outcome is simple: the next SydraDB surface should feel like an operations product with a time-series engine underneath it, not a storage engine that happens to have an HTTP port.
