---
sidebar_position: 1
tags:
  - config
---

# Configuration (`sydradb.toml`)

Implementation reference:

- [`src/sydra/config.zig`](./source/sydra/config.md)
- [`sydradb.toml` and `sydradb.toml.example`](./source/repository/configuration-files.md)

## File location

`sydradb` loads `sydradb.toml` from the current working directory (CWD). If the file is missing or cannot be parsed, the server falls back to built-in defaults.

Built-in defaults are repository-aware:

- Fresh repositories default to `cas_mode = "dual_write"` and `metadata_read_mode = "primary"`.
- Existing repositories that still look like legacy/on-disk mirror layouts stay on `cas_mode = "off"` and `metadata_read_mode = "legacy"` until `sydradb cas migrate-reftable` flips the repository format marker.
- If `sydradb.toml` is present, its values still win.

## Parser notes (important)

The current config loader is a **minimal line-based parser**, not a full TOML implementation.

Implementation notes: [`parseToml` behavior](./source/sydra/config.md#parsing-behavior-parsetoml).

- Comments are only supported as **full-line** comments starting with `#`.
- Inline `# ...` comments after a value are **not reliably supported** and may:
  - cause parse failures (fallback to defaults), or
  - change the interpreted value (e.g. a quoted string no longer ends at `"`).
- String values should be quoted as `"..."` with no trailing comment text.

The checked-in `sydradb.toml` and `sydradb.toml.example` include inline comments for humans; if you use them, **remove inline comments** before running the server.

## Known-good minimal config (no inline comments)

```toml
data_dir = "./data"
http_port = 8080
ingest_socket_path = ""
ingest_socket_max_frame_bytes = 8388608
fsync = "interval"
flush_interval_ms = 2000
memtable_max_bytes = 8388608
mem_limit_bytes = 268435456
auth_token = ""
enable_influx = false
enable_prom = true
retention_days = 0
```

## Settings

### `data_dir` (string)

Directory used for on-disk state (WAL, segments, manifests, etc.).

Default: `./data`

### `http_port` (integer)

HTTP listen port.

Default: `8080`

Set `http_port = 0` to disable HTTP entirely. This is mainly useful for socket-only local ingest setups.

### `ingest_socket_path` (string)

Unix-domain socket path for the local binary ingest listener.

Default: empty string (`""`, disabled)

Notes:

- Empty string disables the listener.
- If `http_port != 0` and `ingest_socket_path != ""`, Sydra starts both listeners.
- If `http_port = 0` and `ingest_socket_path != ""`, Sydra runs in socket-only mode.
- The listener startup validates the path up front and fails fast for non-socket collisions, live listeners, and oversized paths.

### `ingest_socket_max_frame_bytes` (integer)

Maximum allowed local-ingest protocol frame size.

Default: `8388608` (8 MiB)

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

Used as a coarse ingest backpressure limit over queued + buffered in-memory points.

When the limit is hit:

- new ingests are rejected before queueing
- `/metrics` increments the ingest rejection counters
- HTTP ingest returns a JSON error with code `ingest_backpressure`

Default: `268435456` (256 MiB)

### `auth_token` (string)

If non-empty, all `/api/*` requests require:

```
Authorization: Bearer <auth_token>
```

Default: empty (auth disabled)

### `enable_influx` (bool)

Parsed by config, but not currently a promise of a production-ready Influx-compatible adapter surface.

Default: `false`

### `enable_prom` (bool)

Parsed by config, but not currently a promise of a production-ready Prometheus remote-write adapter surface.

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
- There is no built-in “default namespace” — `retention.default` only applies to series whose namespace is literally `default` (e.g. `default.cpu`).
- The config parser loads namespace overrides, but the current engine retention pass operates on `retention_days`; namespace overrides may require additional wiring depending on runtime implementation.

### `cas_mode` (string enum)

Controls whether the engine writes CAS commits alongside compatibility files.

Accepted values: `off`, `dual_write`

Default in `sydradb.toml`: `off`

Built-in startup default when `sydradb.toml` is absent:

- Fresh repositories: `dual_write`
- Existing legacy repositories: `off`

In the `v0.4.0` alpha contract, `dual_write` is the supported CAS write mode for fresh repositories.

### `metadata_read_mode` (string enum)

Controls whether reads use legacy mirrors, compare against CAS in shadow mode, or serve from CAS directly.

Accepted values: `legacy`, `shadow`, `primary`

Default in `sydradb.toml`: `legacy`

Built-in startup default when `sydradb.toml` is absent:

- Fresh repositories: `primary`
- Existing legacy repositories: `legacy`

### `query_compiler_mode` (string enum)

Controls whether sydraQL uses the legacy pipeline only, compares compiled vs. legacy in shadow mode, or prefers the compiled executor and falls back when needed.

Accepted values: `legacy`, `shadow`, `compiled`

Default: `compiled`

Notes:

- `compiled` is the intended `v0.4.0` alpha default.
- Unsupported query shapes fall back to the legacy pipeline and increment the compiler fallback metrics exposed on `/metrics`.
