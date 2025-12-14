---
sidebar_position: 1
---

# Glossary

## Core data and storage terms

### Series

A logical time series identified by:

- A `series` string (for example `weather.room1`)
- Optional `tags` (a JSON object) that become part of the series identity in HTTP surfaces

### `series_id`

A stable `u64` identifier derived from `series` (and tags) using a hash.

See: [Series IDs](../reference/series-ids).

### Point

A single data point: timestamp + value. Most storage structures ultimately store a sequence of points per series.

### WAL (write-ahead log)

An append-only log used for crash safety. SydraDB records ingested points to the WAL before making them durable in segment files.

### Memtable

An in-memory buffer that holds recent points before they are flushed to disk.

### Segment

An on-disk file containing points for a single series within a time bucket (currently hour-aligned). Range queries scan relevant segments for the requested time window.

### Manifest

An on-disk index of which segment files exist and what time ranges they cover. It is used for segment selection during reads and for “highwater” timestamps during WAL recovery.

### Compaction

A background process that rewrites and merges segment files to reduce redundancy and improve read efficiency (for example: de-duplicating points with the same timestamp).

### Retention

A best-effort deletion pass that removes old segment files beyond a configured TTL (`retention_days`).

## Query and compatibility terms

### sydraQL

SydraDB’s query language and query execution pipeline. It is exposed over HTTP at `POST /api/v1/sydraql`.

### pgwire / PostgreSQL compatibility

An optional surface that aims to support PostgreSQL clients and ORMs over the PostgreSQL v3 wire protocol by translating SQL and emulating catalog/introspection.

