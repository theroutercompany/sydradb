---
sidebar_position: 1
tags:
  - concepts
---

# Glossary

See also:

- [Architecture overview](../architecture/overview.md)
- [HTTP API](../reference/http-api.md), [CLI](../reference/cli.md), [Configuration](../reference/configuration.md)
- [Source reference](../reference/source/index.md) (module-by-module docs)

## Core data and storage terms

### Series

A logical time series identified by:

- A `series` string (for example `weather.room1`)
- Optional `tags` (a JSON object) that become part of the series identity in HTTP surfaces

See also:

- [HTTP ingest](../reference/http-api.md#post-apiv1ingest) (request shape)
- [Series IDs](../reference/series-ids.md) (how tags affect identity)

### `series_id`

A stable `u64` identifier derived from `series` (and tags) using a hash.

See:

- [Series IDs](../reference/series-ids.md)
- [Hashing helpers in `src/sydra/types.zig`](../reference/source/sydra/types.md)

### Point

A single data point: timestamp + value. Most storage structures ultimately store a sequence of points per series.

Implementation: [`types.Point`](../reference/source/sydra/types.md#pub-const-point--struct--ts-i64-value-f64-).

### WAL (write-ahead log)

An append-only log used for crash safety. SydraDB records ingested points to the WAL before making them durable in segment files.

See also:

- [On-disk WAL format](../reference/on-disk-format.md#wal-format-v0)
- [WAL module](../reference/source/sydra/storage/wal.md)

### Memtable

An in-memory buffer that holds recent points before they are flushed to disk.

See also:

- [Configuration: `memtable_max_bytes`](../reference/configuration.md#memtable_max_bytes-integer)
- [Memtable module](../reference/source/sydra/storage/memtable.md)

### Segment

An on-disk file containing points for a single series within a time bucket (currently hour-aligned). Range queries scan relevant segments for the requested time window.

See also:

- [On-disk segment format](../reference/on-disk-format.md#segment-format)
- [Segment module](../reference/source/sydra/storage/segment.md)

### Manifest

An on-disk index of which segment files exist and what time ranges they cover. It is used for segment selection during reads and for “highwater” timestamps during WAL recovery.

See also:

- [On-disk manifest overview](../reference/on-disk-format.md#manifest)
- [Manifest module](../reference/source/sydra/storage/manifest.md)

### Compaction

A background process that rewrites and merges segment files to reduce redundancy and improve read efficiency (for example: de-duplicating points with the same timestamp).

See also:

- [CLI: `compact`](../reference/cli.md#compact)
- [Compaction module](../reference/source/sydra/storage/compact.md)

### Retention

A best-effort deletion pass that removes old segment files beyond a configured TTL (`retention_days`).

See also:

- [Configuration: `retention_days`](../reference/configuration.md#retention_days-integer) and namespace overrides
- [Retention module](../reference/source/sydra/storage/retention.md)

## Query and compatibility terms

### sydraQL

SydraDB’s query language and query execution pipeline. It is exposed over HTTP at `POST /api/v1/sydraql`.

See also:

- [sydraQL Design](./sydraql-design.md)
- [HTTP API: `POST /api/v1/sydraql`](../reference/http-api.md#post-apiv1sydraql)
- [Query pipeline overview](../reference/source/sydra/query/overview.md)

### pgwire / PostgreSQL compatibility

An optional surface that aims to support PostgreSQL clients and ORMs over the PostgreSQL v3 wire protocol by translating SQL and emulating catalog/introspection.

See also:

- [CLI: `pgwire`](../reference/cli.md#pgwire-address-port)
- [Compatibility layer overview](../reference/source/sydra/compat/overview.md)
- [Wire protocol notes](../reference/source/sydra/compat/wire-protocol.md)
