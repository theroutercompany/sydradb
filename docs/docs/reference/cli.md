---
sidebar_position: 2
tags:
  - cli
---

# CLI

The `sydradb` binary provides a small command surface. When invoked with no arguments, it runs the HTTP server.

Implementation reference:

- [`src/main.zig`](./source/entrypoints/src-main.md)
- [`src/sydra/server.zig`](./source/sydra/server.md) (command dispatch)

## `serve` (default)

```sh
./zig-out/bin/sydradb
./zig-out/bin/sydradb serve
```

Loads `sydradb.toml` from the current working directory and starts the HTTP server.

Implementation: [`server.run` dispatch](./source/sydra/server.md#pub-fn-runhandle-alloc_modallocatorhandle-void).

## `pgwire [address] [port]`

Starts the PostgreSQL wire protocol listener.

```sh
./zig-out/bin/sydradb pgwire
./zig-out/bin/sydradb pgwire 127.0.0.1 6432
```

Defaults:

- `address`: `127.0.0.1`
- `port`: `6432`

Implementation: [`cmdPgWire`](./source/sydra/server.md#fn-cmdpgwirealloc-stdmemallocator-args-0u8-void).

## `ingest`

Reads NDJSON from stdin and ingests into the local engine.

```sh
cat points.ndjson | ./zig-out/bin/sydradb ingest
```

Each line must contain `series`, `ts`, and `value`.

Implementation: [`cmdIngest`](./source/sydra/server.md#fn-cmdingestalloc-stdmemallocator-args-0u8-void).

Note: CLI ingest hashes only the series name; see [Series IDs](./series-ids.md) for how HTTP derives IDs when tags are present.

## `query <series_id> <start_ts> <end_ts>`

Queries a single series over a time range and prints `ts,value` rows:

```sh
./zig-out/bin/sydradb query 123 1694290000 1694310000
```

Implementation: [`cmdQuery`](./source/sydra/server.md#fn-cmdqueryalloc-stdmemallocator-args-0u8-void).

## `compact`

Runs compaction over stored segments.

```sh
./zig-out/bin/sydradb compact
```

Implementation: [`cmdCompact`](./source/sydra/server.md#fn-cmdcompactalloc-stdmemallocator-args-0u8-void).

## `snapshot <dst_dir>`

Writes a snapshot to `dst_dir`:

```sh
./zig-out/bin/sydradb snapshot ./snapshots/2025-01-01
```

Implementation: [`cmdSnapshot`](./source/sydra/server.md#fn-cmdsnapshotalloc-stdmemallocator-args-0u8-void).

## `restore <src_dir>`

Restores from a snapshot directory:

```sh
./zig-out/bin/sydradb restore ./snapshots/2025-01-01
```

Implementation: [`cmdRestore`](./source/sydra/server.md#fn-cmdrestorealloc-stdmemallocator-args-0u8-void).

## `stats`

Prints basic counters (including segment counts). In `small_pool` allocator mode it also prints allocator stats.

```sh
./zig-out/bin/sydradb stats
```

Implementation: [`cmdStats`](./source/sydra/server.md#fn-cmdstatshandle-alloc_modallocatorhandle-alloc-stdmemallocator-args-0u8-void).

See also:

- [Configuration](./configuration.md) (ports, data dir, auth)
- [HTTP API](./http-api.md) (server surface)
