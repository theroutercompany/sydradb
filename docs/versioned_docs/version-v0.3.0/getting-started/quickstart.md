---
sidebar_position: 1
tags:
  - getting-started
---

# Quickstart

## Prerequisites

- Zig `0.15.x` (recommended: use the pinned toolchain via Nix; see below)

## Build

From the repo root:

```sh
zig build
```

The binary is emitted at `./zig-out/bin/sydradb`.

## Run the HTTP server

By default, `sydradb` runs the HTTP server (equivalent to `serve`):

```sh
./zig-out/bin/sydradb
```

The server loads `./sydradb.toml` from the current working directory. If the file is missing, it falls back to built-in defaults.

Important: the current config loader is a minimal parser and does not reliably support inline comments (for example `auth_token = ""  # ...`). If the server appears to ignore your config or fails to parse it, remove inline comments.

See:

- [Configuration](../reference/configuration) (including parser limitations)
- [`parseToml` implementation notes](../reference/source/sydra/config.md#parsing-behavior-parsetoml)

## Ingest a point

The HTTP ingest endpoint accepts NDJSON (one JSON object per line):

```sh
curl -XPOST localhost:8080/api/v1/ingest --data-binary $'{"series":"weather.room1","ts":1694300000,"value":24.2}\\n'
```

See: [HTTP API – `POST /api/v1/ingest`](../reference/http-api.md#post-apiv1ingest).

## Query a range

```sh
curl -XPOST localhost:8080/api/v1/query/range \\
  --data-binary '{"series":"weather.room1","start":1694290000,"end":1694310000}'
```

See: [HTTP API – `POST /api/v1/query/range`](../reference/http-api.md#post-apiv1queryrange).

## Nix (pinned toolchain)

```sh
nix develop
zig build
```

To build a reproducible package:

```sh
nix build
./result/bin/sydradb
```

See also:

- [Running the server](./running-the-server.md)
- [Ingest and query](./ingest-and-query.md)
