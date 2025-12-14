---
sidebar_position: 4
---

# Troubleshooting

## Build issues

### Zig version mismatch

This repo targets Zig `0.15.x`. If you see compile errors that look like stdlib API mismatches, confirm your Zig version:

```sh
zig version
```

If you use the pinned toolchain via Nix:

```sh
nix develop
zig version
zig build
```

### Missing dependencies for the docs site

The documentation site lives under `docs/` and uses Node.

```sh
cd docs
npm install
npm start
```

## Server issues

### Port already in use

By default the HTTP server listens on port `8080`. If you see “address already in use”, either stop the other process or set `http_port` in `sydradb.toml`.

### Config file not being picked up

`sydradb` loads `./sydradb.toml` from the current working directory (CWD). If you run the binary from another directory, it will not see the config unless you copy/symlink it there.

Confirm where you are running from:

```sh
pwd
ls -la sydradb.toml
```

### Config parsing errors

The current config loader is a minimal line-based parser (not full TOML). The most common issue is inline comments after values, for example:

```toml
http_port = 8080 # inline comments may break parsing
```

If parsing fails, remove inline comments and keep comments on their own lines.

See: [Configuration](../reference/configuration).

## API issues

### `401 unauthorized` on `/api/*`

If `auth_token` is set in `sydradb.toml`, all `/api/*` routes require:

```
Authorization: Bearer <auth_token>
```

### Ingest returns `413 Payload Too Large`

`POST /api/v1/ingest` buffers input lines. A single NDJSON line that exceeds the internal buffer fails the request.

If you are batch-ingesting, split large payloads into smaller lines and smaller requests.

## Debugging and introspection

- `GET /metrics` – Prometheus-style metrics for ingest/flush/WAL/queue/memtable
- `GET /debug/alloc/stats` – allocator stats (only in `small_pool` allocator mode)
- `GET /debug/compat/stats` and `GET /debug/compat/catalog` – PostgreSQL compatibility counters/catalog snapshot
