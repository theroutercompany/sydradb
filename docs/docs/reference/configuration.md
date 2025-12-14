---
sidebar_position: 1
---

# Configuration (`sydradb.toml`)

## File location

`sydradb` loads `sydradb.toml` from the current working directory (CWD). If the file is missing or cannot be parsed, the server falls back to built-in defaults.

## Parser notes (important)

The current config loader is a **minimal line-based parser**, not a full TOML implementation.

- Comments are only supported as **full-line** comments starting with `#`.
- Inline `# ...` comments after a value are not reliably supported.
- String values should be quoted as `"..."` with no trailing comment text.

Use `sydradb.toml.example` as a starting point, but remove inline comments if you run into parsing issues.

## Settings

### `data_dir` (string)

Directory used for on-disk state (WAL, segments, manifests, etc.).

Default: `./data`

### `http_port` (integer)

HTTP listen port.

Default: `8080`

### `fsync` (string enum)

WAL fsync policy.

Accepted values: `always`, `interval`, `none`

Default: `interval`

### `flush_interval_ms` (integer)

Maximum time between memtable flushes.

Default: `2000`

### `memtable_max_bytes` (integer)

Flush trigger based on in-memory buffered data size.

Default: `8388608` (8 MiB)

### `mem_limit_bytes` (integer)

Memory limit for the engine process. (Parsed by config; current enforcement depends on runtime implementation.)

Default: `268435456` (256 MiB)

### `auth_token` (string)

If non-empty, all `/api/*` requests require:

```
Authorization: Bearer <auth_token>
```

Default: empty (auth disabled)

### `enable_influx` (bool)

Toggles the Influx-compatible surface. (Parsed by config; current behavior depends on runtime implementation.)

Default: `false`

### `enable_prom` (bool)

Toggles Prometheus-style metrics. (Parsed by config; current behavior depends on runtime implementation.)

Default: `true`

### `retention_days` (integer)

Retention window for data in days.

- `0` disables retention (keep data forever).
- Retention is applied best-effort after memtable flush.

Default: `0`

### `retention.<namespace>` (integer)

Namespace-specific retention in days, e.g.:

```toml
retention.weather = 30
```

Notes:

- Namespace is derived as the substring before the first `.` in the series name (e.g. `weather.room1` → `weather`).
- The current engine retention pass operates on `retention_days`; namespace overrides may require additional wiring depending on runtime implementation.

