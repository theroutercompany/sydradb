# sydraDB

SydraDB is a single-node time-series database written in Zig.

## Alpha statement

Current alpha focus:

- HTTP ingest
- HTTP range queries
- Basic sydraQL
- Snapshot/restore
- Narrow PostgreSQL simple-query compatibility

This is intentionally not a broad PostgreSQL replacement. The current compatibility layer is a small bridge for startup/auth flow, simple query execution, the current SQL translator subset, and standard `CommandComplete` behavior.

## Supported contract

- Zig: `0.15.1`
- Supported build targets:
  - `x86_64-linux-gnu`
  - `aarch64-linux-gnu`
  - `x86_64-macos`
  - `aarch64-macos`
- Supported allocator modes:
  - `mimalloc` (default)
  - `default`
- Experimental, not a release gate this cycle:
  - `small_pool`
  - `cas_mode = "dual_write"` metadata-first CAS commit graph
- Explicitly unsupported this cycle:
  - 32-bit targets
  - Influx LP / Prom remote_write adapters
  - full PostgreSQL catalog coverage
  - prepared statements / extended protocol / COPY
  - migration tooling

## Quick start

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/sydradb            # serve using sydradb.toml
curl -XPOST localhost:8080/api/v1/ingest --data-binary $'{"series":"weather.room1","ts":1694300000,"value":24.2}\n'

# Allocator modes
zig build                                # default: mimalloc global allocator
zig build -Dallocator-mode=default       # supported Zig allocator path
zig build -Dallocator-mode=small_pool    # experimental allocator path
```

## Nix

If you use Nix, this repo includes a flake that pins Zig and provides a dev shell:

```bash
# Start a shell with the pinned Zig
nix develop

# Build the package (installs to ./result)
nix build
./result/bin/sydradb serve
```

Notes

- The flake integrates `mitchellh/zig-overlay` and pins Zig `0.15.1`.
- To (re)pin: `nix flake lock --update-input nixpkgs --update-input zig-overlay` then commit the updated `flake.lock`.

## Direnv (auto-activate dev shell)

This repository includes an `.envrc` that loads the pinned Nix dev shell.

1. Install direnv and nix-direnv
   - Nix: `nix profile install nixpkgs#direnv nixpkgs#nix-direnv`
   - Homebrew: `brew install direnv`
2. Hook direnv in your shell (e.g., zsh): add `eval "$(direnv hook zsh)"` to your shell rc.
3. Ensure nix-direnv is sourced by direnv (recommended):
   - Create `~/.config/direnv/direnvrc` with: `source "$HOME/.nix-profile/share/nix-direnv/direnvrc"` (or equivalent for your profile).
4. In this repo run: `direnv allow`.

From now on, entering the directory will auto‑activate the correct toolchain.

## Status

Pre-alpha. The goal of the current cycle is to make the existing TSDB core and narrow compatibility surface more honest, tighter, and better documented rather than broader.

## License

Apache-2.0

## CLI

```bash
./zig-out/bin/sydradb             # serve (HTTP): /api/v1/ingest, /api/v1/query/range, /api/v1/sydraql, /metrics
./zig-out/bin/sydradb ingest      # read NDJSON from stdin into local WAL
./zig-out/bin/sydradb query <series_id> <start_ts> <end_ts>
./zig-out/bin/sydradb compact     # merge small→large segments (v2 stub)
./zig-out/bin/sydradb snapshot <dst_dir>   # write a self-contained CAS bundle
./zig-out/bin/sydradb restore  <src_dir>   # apply a CAS bundle into data_dir
./zig-out/bin/sydradb stats       # print simple counters
./zig-out/bin/sydradb cas bundle create <dst_dir> [--since <spec>]
./zig-out/bin/sydradb cas bundle verify <bundle_dir>
./zig-out/bin/sydradb cas bundle apply <bundle_dir>
./zig-out/bin/sydradb cas verify
./zig-out/bin/sydradb cas refs
./zig-out/bin/sydradb cas log [heads/main]
./zig-out/bin/sydradb cas branch <name> [spec]
./zig-out/bin/sydradb cas tag <name> [spec]
./zig-out/bin/sydradb cas diff <lhs> <rhs>
./zig-out/bin/sydradb cas rollback <spec>
./zig-out/bin/sydradb cas gc [--apply] [--no-reflogs] [--grace-ms <n>]
./zig-out/bin/sydradb cas fsck [--connectivity-only] [--no-reflogs] [--lost-found]
./zig-out/bin/sydradb cas pack
./zig-out/bin/sydradb cas checkout <spec>
./zig-out/bin/sydradb cas export-legacy [spec]
```

Config: `sydradb.toml`

```
data_dir = "./data"
http_port = 8080
fsync = "interval"  # always|interval|none
flush_interval_ms = 2000
memtable_max_bytes = 8388608
mem_limit_bytes = 268435456
auth_token = ""  # set non-empty to require Bearer auth on /api/*
enable_influx = false
enable_prom = true
cas_mode = "off"  # off|dual_write
metadata_read_mode = "legacy"  # legacy|shadow|primary
# Per-namespace TTL
retention.weather = 30
```

Config notes:

- `mem_limit_bytes` is parsed, but it is not currently enforced as a global runtime quota.
- `cas_mode = "dual_write"` writes immutable metadata commits and `refs/heads/main` alongside the legacy storage path.
- `metadata_read_mode = "shadow"` serves from legacy metadata and cross-checks answers against the CAS snapshot.
- `metadata_read_mode = "primary"` serves metadata from CAS and can boot even if `MANIFEST`, `tags.json`, or `series_catalog.jsonl` are missing.
- CAS repositories now persist `objects/info/store-format` to version repository-wide storage behavior separately from per-object codecs.
- WAL recovery order is sourced from the CAS commit graph when CAS is enabled, with any uncaptured live WAL files appended as tail replay.
- `snapshot`/`restore` now operate on CAS bundles. A restored bundle only materializes `objects/` and `refs/`; use `metadata_read_mode = "primary"` for mirrorless startup, or run `cas checkout` / `cas export-legacy` if you need compatibility files regenerated.
- Sealed segment and WAL payloads are chunked into CAS extent trees; `cas checkout` / `cas export-legacy` materialize mirror files by walking those trees rather than depending on legacy blobs.
- `cas gc` is reflog-aware by default. `--apply` first quarantines unreachable content under `objects/cruft/<timestamp>/` and only prunes older cruft after the configured grace window; use `--no-reflogs` when you want rollback history to stop protecting old commits.
- `cas fsck` defaults to full content and mirror validation. `--connectivity-only` limits it to graph/reflog/reachability checks, and `--lost-found` writes dangling commit/blob/tree ids under `lost-found/`.
- `enable_influx` and `enable_prom` remain parseable config flags, but they should be treated as placeholder or experimental toggles until real adapter surfaces land.
- `auth_token` is the only built-in API auth mechanism today; if it is empty, `/api/*` is unauthenticated.
