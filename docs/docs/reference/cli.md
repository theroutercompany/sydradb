---
sidebar_position: 2
---

# CLI

The `sydradb` binary provides a small command surface. When invoked with no arguments, it runs the HTTP server.

## `serve` (default)

```sh
./zig-out/bin/sydradb
./zig-out/bin/sydradb serve
```

Loads `sydradb.toml` from the current working directory and starts the HTTP server.

## `pgwire [address] [port]`

Starts the PostgreSQL wire protocol listener.

```sh
./zig-out/bin/sydradb pgwire
./zig-out/bin/sydradb pgwire 127.0.0.1 6432
```

Defaults:

- `address`: `127.0.0.1`
- `port`: `6432`

## `ingest`

Reads NDJSON from stdin and ingests into the local engine.

```sh
cat points.ndjson | ./zig-out/bin/sydradb ingest
```

Each line must contain `series`, `ts`, and `value`.

## `query <series_id> <start_ts> <end_ts>`

Queries a single series over a time range and prints `ts,value` rows:

```sh
./zig-out/bin/sydradb query 123 1694290000 1694310000
```

## `compact`

Runs compaction over stored segments.

```sh
./zig-out/bin/sydradb compact
```

## `snapshot <dst_dir>`

Writes a snapshot to `dst_dir`:

```sh
./zig-out/bin/sydradb snapshot ./snapshots/2025-01-01
```

## `restore <src_dir>`

Restores from a snapshot directory:

```sh
./zig-out/bin/sydradb restore ./snapshots/2025-01-01
```

## `stats`

Prints basic counters (including segment counts). In `small_pool` allocator mode it also prints allocator stats.

```sh
./zig-out/bin/sydradb stats
```

