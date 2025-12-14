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

The server binds to `0.0.0.0:<http_port>` as configured in `sydradb.toml`.

## Config file lookup

`sydradb` loads `sydradb.toml` from the current working directory (CWD). If it is missing or unreadable, the server uses built-in defaults (mirroring `sydradb.toml.example`).

Important: the current config loader is a minimal parser and does not reliably support inline comments after values. If you copy `sydradb.toml` or `sydradb.toml.example` from the repo, remove inline comments before running.

See: [Configuration](../reference/configuration).

## Authentication

If `auth_token` is non-empty in config, all routes under `/api/*` require:

```
Authorization: Bearer <auth_token>
```

Non-`/api/` routes (for example `/metrics` and `/debug/*`) are not gated by this check.

## Endpoints

- `/metrics` (GET) – Prometheus-style text metrics
- `/api/v1/ingest` (POST) – NDJSON ingest
- `/api/v1/query/range` (GET/POST) – time range query by `series` or `series_id`
- `/api/v1/query/find` (POST) – tag-based series lookup
- `/api/v1/sydraql` (POST) – sydraQL query execution (request body is plain text)
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
