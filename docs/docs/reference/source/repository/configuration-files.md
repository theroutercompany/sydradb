---
sidebar_position: 4
title: sydradb.toml and sydradb.toml.example
---

# `sydradb.toml` and `sydradb.toml.example`

## Purpose

These files provide runtime configuration for the `sydradb` process.

Lookup behavior:

- The server loads `sydradb.toml` from the current working directory (CWD).
- If the file is missing or cannot be parsed, SydraDB falls back to built-in defaults.

## Important: parser limitations

The current config loader is a minimal, line-based parser (`src/sydra/config.zig`). It does **not** implement full TOML.

In particular:

- Full-line comments starting with `#` are supported.
- Inline comments after values (for example `auth_token = ""  # comment`) are **not reliably supported** and may cause parsing errors or surprising values.

## Known-good minimal config

Use this format (no inline comments) when starting out:

```toml
data_dir = "./data"
http_port = 8080
fsync = "interval"
flush_interval_ms = 2000
memtable_max_bytes = 8388608
mem_limit_bytes = 268435456
auth_token = ""
enable_influx = false
enable_prom = true
retention_days = 0
```

For a full key-by-key reference, see:

- `Reference/Configuration (sydradb.toml)`

