---
sidebar_position: 4
tags:
  - ingest
  - socket
  - local
---

# Local Ingest Socket

The local ingest socket is the same-host ingestion path for Sydra-owned clients that want lower overhead than NDJSON over HTTP.

Current scope:

- Unix-domain stream sockets only
- exact-series / telemetry point ingest only
- connection-scoped declarations plus append batches
- alpha, Sydra-owned protocol contract

The current implementation uses the shared ingest service under [`src/sydra/ingest/service.zig`](./source/sydra/ingest/service.md) and the socket transport in [`src/sydra/ingest/socket.zig`](./source/sydra/ingest/socket.md).

## Why Use It

Compared to `POST /api/v1/ingest`, the socket path lets clients:

- declare a series once per connection
- append `{ts,value}` batches without repeating names and tags each point
- request a queryable barrier with `FLUSH_DRAIN`
- use filesystem permissions as the local auth boundary

HTTP stays the default remote/operator surface. The socket path is for colocated producers on the same machine.

## Config

```toml
data_dir = "./data"
http_port = 8080
ingest_socket_path = "./ingest.sock"
ingest_socket_max_frame_bytes = 8388608
fsync = "none"
flush_interval_ms = 5
memtable_max_bytes = 8388608
mem_limit_bytes = 268435456
auth_token = ""
enable_influx = false
enable_prom = true
retention_days = 0
```

Key settings:

- `ingest_socket_path = ""` disables the local listener.
- `http_port = 0` gives a socket-only server.
- Setting both enables combined HTTP + socket mode.
- `ingest_socket_max_frame_bytes` bounds a single protocol frame.

See also: [Configuration](./configuration.md).

## CLI

The simplest client is the built-in CLI:

```sh
cat points.ndjson | ./zig-out/bin/sydradb ingest --socket ./ingest.sock
```

Behavior:

- parses the same NDJSON envelopes accepted by `POST /api/v1/ingest`
- batches declarations and append frames
- fails loudly if the socket cannot be used
- issues `FLUSH_DRAIN` before exit, so success means points are queryable

## Status and Metrics

`GET /status` includes:

- `runtime.local_ingest_enabled`
- `runtime.local_ingest_connections_current`
- `runtime.local_ingest_append_points_total`
- `runtime.local_ingest_rejected_total`
- `runtime.queue_pending_bytes_max`

`GET /metrics` adds counters and gauges such as:

- `sydradb_local_ingest_connections_total`
- `sydradb_local_ingest_declare_batches_total`
- `sydradb_local_ingest_declare_total`
- `sydradb_local_ingest_append_batches_total`
- `sydradb_local_ingest_append_points_total`
- `sydradb_local_ingest_append_batch_points_max`
- `sydradb_local_ingest_rejected_total`
- `sydradb_queue_pending_bytes_max`

## macOS Note

XPC is intentionally deferred. The current path is:

1. shared ingest service
2. Unix-domain socket transport
3. possible launchd or XPC adapters later if operator needs justify them

That keeps the core ingestion semantics transport-neutral instead of building a separate macOS-only engine path.
