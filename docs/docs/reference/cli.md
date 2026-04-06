---
sidebar_position: 2
tags:
  - cli
---

# CLI

The `sydradb` binary provides a small command surface. When invoked with no arguments, it runs the HTTP server.

Command result payloads are written to stdout. Interactive startup/status banners are reserved for stderr and only emitted when stderr is attached to a TTY.

Implementation reference:

- [`src/main.zig`](./source/entrypoints/src-main.md)
- [`src/sydra/server.zig`](./source/sydra/server.md) (command dispatch)

## `serve` (default)

```sh
./zig-out/bin/sydradb
./zig-out/bin/sydradb serve
```

Loads `sydradb.toml` from the current working directory and starts the configured listeners.

Listener modes:

- HTTP-only: `http_port != 0`, `ingest_socket_path = ""`
- socket-only: `http_port = 0`, `ingest_socket_path != ""`
- combined: both configured

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

Current support is intentionally narrow and should be treated as a preview alpha surface: startup/auth flow, simple query execution, and a preview prepared/extended flow. `COPY` and broader compatibility layers remain out of scope for the current alpha cycle.

When a direct prepared/extended query falls outside that preview subset, the current contract is to fail fast with PostgreSQL-style `0A000` (`feature not supported`) errors rather than silently widening support claims.

Implementation: [`cmdPgWire`](./source/sydra/server.md#fn-cmdpgwirealloc-stdmemallocator-args-0u8-void).

## `ingest`

Reads NDJSON from stdin and ingests into the local engine.

```sh
cat points.ndjson | ./zig-out/bin/sydradb ingest
cat points.ndjson | ./zig-out/bin/sydradb ingest --socket ./ingest.sock
```

Each line uses the same parser as `POST /api/v1/ingest`:

- `series` and `ts` are required
- `value` may be integer or float
- if `value` is absent, the first numeric field under `fields` is used
- `tags` participate in canonical series-id derivation

The command flushes before exit, so a successful return means the ingested points are queryable from the local repository state.

With `--socket <path>`, the CLI speaks the local binary ingest protocol instead of opening the repository directly. The current socket client batches declarations and append frames, then issues a queryable barrier before exit.

The human-readable success summary is only printed when stderr is attached to a TTY, which keeps noninteractive smoke runs and scripts quieter.

Implementation: [`cmdIngest`](./source/sydra/server.md#fn-cmdingestalloc-stdmemallocator-args-0u8-void).

## `query <series_id> <start_ts> <end_ts>`

Queries a single series over a time range and prints `ts,value` rows:

```sh
./zig-out/bin/sydradb query 123 1694290000 1694310000
```

The CSV rows are written to stdout.

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

The stats lines are written to stdout.

Implementation: [`cmdStats`](./source/sydra/server.md#fn-cmdstatshandle-alloc_modallocatorhandle-alloc-stdmemallocator-args-0u8-void).

See also:

- [Configuration](./configuration.md) (ports, data dir, auth)
- [HTTP API](./http-api.md) (server surface)
