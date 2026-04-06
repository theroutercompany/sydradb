---
sidebar_position: 2
---

# Running the server

## Commands

From the repo root:

```sh
zig build
./zig-out/bin/sydradb         # same as: ./zig-out/bin/sydradb serve
```

Listener modes:

- HTTP-only: binds `0.0.0.0:<http_port>`
- socket-only: binds `ingest_socket_path`
- combined: starts both

In combined mode, Sydra keeps HTTP as the operator surface and adds the local socket for same-host producers.

See:

- [Configuration – `http_port`](../reference/configuration.md#http_port-integer)
- [Configuration – `ingest_socket_path`](../reference/configuration.md#ingest_socket_path-string)
- [Local Ingest Socket](../reference/local-ingest.md)
- [HTTP server implementation](../reference/source/sydra/http.md)

## Config file lookup

`sydradb` loads `sydradb.toml` from the current working directory (CWD). If it is missing or unreadable, the server uses built-in defaults (mirroring `sydradb.toml.example`).

Important: the current config loader is a minimal parser and does not reliably support inline comments after values. If you copy `sydradb.toml` or `sydradb.toml.example` from the repo, remove inline comments before running.

See: [Configuration](../reference/configuration).

## Authentication

If [`auth_token`](../reference/configuration.md#auth_token-string) is non-empty in config, all routes under `/api/*` require:

```
Authorization: Bearer <auth_token>
```

Non-`/api/` routes (for example `/metrics` and `/debug/*`) are not gated by this check.

## Endpoints

- [`/metrics`](../reference/http-api.md#get-metrics) (GET) – Prometheus-style text metrics
- [`/status`](../reference/http-api.md#get-status) (GET) – runtime and local-ingest health snapshot
- [`/api/v1/ingest`](../reference/http-api.md#post-apiv1ingest) (POST) – NDJSON ingest
- [`/api/v1/query/range`](../reference/http-api.md#post-apiv1queryrange) (GET/POST) – time range query by `series` or `series_id`
- [`/api/v1/query/find`](../reference/http-api.md#post-apiv1queryfind) (POST) – tag-based series lookup
- [`/api/v1/sydraql`](../reference/http-api.md#post-apiv1sydraql) (POST) – sydraQL query execution (request body is plain text)
- `/debug/compat/stats` (GET) – compatibility counters
- `/debug/compat/catalog` (GET) – compatibility catalog snapshot
- `/debug/alloc/stats` (GET) – allocator stats (only in `small_pool` allocator mode)

## PostgreSQL wire protocol (pgwire)

Run the pgwire listener:

```sh
./zig-out/bin/sydradb pgwire [address] [port]
```

Defaults:

- `address`: `127.0.0.1`
- `port`: `6432`

See also:

- [CLI](../reference/cli.md#pgwire-address-port)
