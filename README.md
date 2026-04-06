# sydraDB

SydraDB is a single-node time-series database written in Zig.

## Alpha statement

Current alpha focus:

- HTTP ingest
- HTTP range queries
- Compiled sydraQL as the default execution path for the supported subset
- CAS-native snapshot, bundle, verify, clone, fetch/push, fsck, vacuum, and upgrade workflows
- Snapshot/restore via CAS bundles
- PostgreSQL wire protocol preview, including the current simple-query path and preview prepared/extended flow

This is intentionally not a broad PostgreSQL replacement. The current compatibility layer is a narrow alpha bridge: startup/auth flow, simple query execution, and a preview prepared/extended path. `COPY`, broader catalog emulation, and wider compatibility claims remain out of scope.

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
- Alpha-only / preview surfaces:
  - `small_pool`
  - PostgreSQL prepared statements / extended protocol through `pgwire`
- Explicitly unsupported this cycle:
  - 32-bit targets
  - Influx LP / Prom remote_write adapters
  - full PostgreSQL catalog coverage
  - COPY
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

Alpha. The current cycle is a stabilization-and-truthfulness push: make the CAS-backed storage path, compiled sydraQL path, and benchmark/demo surface honest and reproducible before broadening the product contract again.

## Benchmarks

The repo now carries three benchmark entrypoints for the `v0.4.0` alpha cycle:

```bash
zig build bench-alloc -- --ops 10000 --concurrency 4 --series 1
zig build bench-sydraql -- --points-per-series 32 --iterations 5
zig build bench-cas
```

Scenario definitions live under [`benchmarks/README.md`](/Users/rexliu/sydradb/benchmarks/README.md), [`benchmarks/alloc/scenarios.json`](/Users/rexliu/sydradb/benchmarks/alloc/scenarios.json), [`benchmarks/sydraql/scenarios.json`](/Users/rexliu/sydradb/benchmarks/sydraql/scenarios.json), and [`benchmarks/cas/scenarios.json`](/Users/rexliu/sydradb/benchmarks/cas/scenarios.json).

One checked-in sample run is published in [`benchmarks/v0.4.0-summary.md`](/Users/rexliu/sydradb/benchmarks/v0.4.0-summary.md).

## Demos

The repo also carries four reproducible demo scripts:

```bash
bash demos/demo-quickstart.sh
bash demos/demo-sydraql-compiled.sh
bash demos/demo-cas-lifecycle.sh
bash demos/demo-pgwire-preview.sh
zig build demo-smoke
```

See [`demos/README.md`](/Users/rexliu/sydradb/demos/README.md) for the current checklist.

## License

Apache-2.0

## CLI

```bash
./zig-out/bin/sydradb             # serve (HTTP): /api/v1/ingest, /api/v1/query/range, /api/v1/sydraql, /metrics
./zig-out/bin/sydradb pgwire      # PostgreSQL wire protocol preview (simple query + preview prepared flow)
./zig-out/bin/sydradb ingest      # read NDJSON from stdin, flush, and exit only after points are queryable
./zig-out/bin/sydradb query <series_id> <start_ts> <end_ts>
./zig-out/bin/sydradb compact     # merge small→large segments (v2 stub)
./zig-out/bin/sydradb snapshot <dst_dir>   # write a self-contained CAS bundle
./zig-out/bin/sydradb restore  <src_dir>   # apply a CAS bundle into data_dir
./zig-out/bin/sydradb stats       # print simple counters
./zig-out/bin/sydradb cas clone <src_dir> <dst_dir> [--borrow]
./zig-out/bin/sydradb cas fetch-local <src_dir> [--materialize]
./zig-out/bin/sydradb cas push-local <dst_dir> [--borrow]
./zig-out/bin/sydradb cas verify-bundle <bundle_dir>
./zig-out/bin/sydradb cas bundle create <dst_dir> [--since <spec>]
./zig-out/bin/sydradb cas bundle verify <bundle_dir>
./zig-out/bin/sydradb cas bundle apply <bundle_dir>
./zig-out/bin/sydradb cas verify
./zig-out/bin/sydradb cas refs
./zig-out/bin/sydradb cas head [ref]
./zig-out/bin/sydradb cas log [heads/main]
./zig-out/bin/sydradb cas branch <name> [spec]
./zig-out/bin/sydradb cas tag <name> [spec]
./zig-out/bin/sydradb cas delete-ref <ref>
./zig-out/bin/sydradb cas rename-ref <old_ref> <new_ref>
./zig-out/bin/sydradb cas reflog <ref> [limit]
./zig-out/bin/sydradb cas diff <lhs> <rhs>
./zig-out/bin/sydradb cas rollback <spec>
./zig-out/bin/sydradb cas migrate-reftable
./zig-out/bin/sydradb cas upgrade
./zig-out/bin/sydradb cas expire [--materialize-borrowed] [--reflog-expiry-ms <n>] [--checkpoint-expiry-ms <n>]
./zig-out/bin/sydradb cas vacuum [--repair] [--materialize-borrowed] [--reflog-expiry-ms <n>] [--checkpoint-expiry-ms <n>] [--prune-grace-ms <n>]
./zig-out/bin/sydradb cas prune [--dry-run] [--grace-ms <n>]
./zig-out/bin/sydradb cas gc [--apply] [--no-reflogs] [--grace-ms <n>]
./zig-out/bin/sydradb cas fsck [--connectivity-only] [--no-reflogs] [--lost-found] [--repair]
./zig-out/bin/sydradb cas pack
./zig-out/bin/sydradb cas checkout <spec>
./zig-out/bin/sydradb cas export-legacy [spec]
```

CLI result payloads are written to stdout. Interactive startup summaries stay on stderr and are only emitted when stderr is attached to a TTY.

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
query_compiler_mode = "compiled"  # legacy|shadow|compiled
# Per-namespace TTL
retention.weather = 30
```

Config notes:

- `mem_limit_bytes` is enforced as a coarse ingest backpressure limit over queued + buffered in-memory points. When the limit is hit, ingest rejects new points and increments `/metrics` rejection counters.
- `/api/*` error responses now include JSON fields `error`, `code`, and `status` so clients can distinguish missing input, unsupported query shapes, and overload conditions.
- `sydradb ingest` now uses the same line parser and series-id derivation as HTTP ingest, including `tags` and fallback-to-first-numeric `fields` behavior.
- `cas_mode = "dual_write"` writes immutable metadata commits and `refs/heads/main` alongside the legacy storage path.
- `metadata_read_mode = "shadow"` serves from legacy metadata and cross-checks answers against the CAS snapshot.
- `metadata_read_mode = "primary"` serves metadata from CAS and can boot even if `MANIFEST`, `tags.json`, or `series_catalog.jsonl` are missing.
- `query_compiler_mode = "compiled"` is the default execution mode. Unsupported query shapes fall back to the legacy pipeline and emit visible fallback metrics.
- Without `sydradb.toml`, fresh repositories default to `cas_mode = "dual_write"` plus `metadata_read_mode = "primary"`. Existing repositories without a migrated `objects/info/store-format` marker stay on `off` plus `legacy` until `cas migrate-reftable` or `cas upgrade` is run.
- CAS repositories persist `objects/info/store-format` to version repository-wide storage behavior separately from per-object codecs. Fresh repositories initialize format v3 with a reftable ref backend plus canonical `segment_root` / `journal_root` metadata for active history. Legacy repositories stay in the older compatibility format until explicitly migrated and normalized.
- WAL recovery order is sourced from the CAS commit graph when CAS is enabled, with any uncaptured live WAL files appended as tail replay.
- `snapshot`/`restore` now operate on CAS bundles. A restored bundle only materializes `objects/` and `refs/`; use `metadata_read_mode = "primary"` for mirrorless startup, or run `cas checkout` / `cas export-legacy` if you need compatibility files regenerated.
- `objects/info/pack-inventory` records the active pack set with stable BLAKE3 digests and object counts, and bundle manifests now use format v4 so they can describe the exact exported pack subset plus prerequisite refs.
- `reftable/info/summary` is a rebuildable side index over active tables. It records ref key ranges, reflog ranges, update spans, and tombstone presence so runtime lookups can skip irrelevant tables before decoding blocks.
- `cas clone` now supports an explicit `--borrow` mode. The default path remains owned and pack-preserving; `--borrow` initializes the destination refs immediately and keeps object lookup backed by the source repository through alternates.
- `cas fetch-local` still tracks source refs under `remotes/<repository-id>/...` and borrows source object storage by default. `--materialize` imports the reachable borrowed objects into the destination and clears alternates afterward.
- Reftable-backed repositories now persist symbolic heads under `symrefs/`. `cas head` reads or updates the local `HEAD` target, and `cas fetch-local` mirrors a source `HEAD` target into `symrefs/remotes/<repository-id>/HEAD` when the source publishes one.
- `cas push-local` now defaults to owned transfer: it fast-forwards the destination `heads/main`, materializes the pushed reachable objects locally, and leaves the destination independent of the source. Use `--borrow` only when you explicitly want alternates-backed storage.
- Sealed segment and WAL payloads are chunked into CAS extent trees; `cas checkout` / `cas export-legacy` materialize mirror files by walking those trees rather than depending on legacy blobs.
- Segment descriptors now carry a canonical native `segment_root` tree for sealed segment data. Each root stores a `meta` blob plus per-block `stats`, `ts`, and `values` objects so later read paths can skip blocks without materializing a full `.seg` file.
- WAL descriptors now carry a canonical native `journal_root` tree plus checkpoint-state metadata, so commits record replay high-water and the exact captured WAL frame set instead of treating sealed WAL content as one opaque file blob.
- `cas pack` now maintains a pack set instead of collapsing to one active pack; `objects/info/multi-pack-index` accelerates mixed-pack lookups while loose objects remain the write path.
- `objects/info/reachability-bitmap` caches the reachable object-id set for the current ref snapshot, `objects/info/commit-graph` carries logical changed-path Bloom filters alongside generation numbers, and `objects/info/object-refs` stores explicit child edges for GC/fsck.
- Active pack files now carry adjacent `.manifest` files with per-type counts and checksums, and unreachable loose objects are quarantined into cruft packs instead of loose cruft directories.
- Reftable repositories now persist `reftable/state` and write update-indexed `<min>-<max>.table` files. Transactions append narrow spans, while compaction rewrites suffixes geometrically into wider tables without losing tombstones.
- `cas gc` is reflog-aware by default. `--apply` first quarantines unreachable content under `objects/cruft/<timestamp>/` and only prunes older cruft after the configured grace window; use `--no-reflogs` when you want rollback history to stop protecting old commits.
- `cas fsck` defaults to full content and mirror validation. `--connectivity-only` limits it to graph/reflog/reachability checks, `--lost-found` writes dangling commit/blob/tree ids under `lost-found/`, and `--repair` safely rebuilds derivable side indexes, pack sidecars, and reftable metadata before re-validating the store. Full and connectivity modes now also report compatibility debt separately from corruption: reachable legacy segment descriptors, reachable legacy WAL descriptors, and loose refs still present in migrated v3 repositories.
- `cas upgrade` verifies the repository, migrates loose refs to reftable when needed, normalizes active reachable commits to canonical `segment_root` / `journal_root` forms, refreshes indexes, and rewrites the repository-format marker only after the migration path succeeds.
- `cas expire` applies the non-destructive maintenance policy: reflog expiry, checkpoint expiry, and optional borrowed-object materialization.
- `cas prune` is the destructive end of maintenance. It only deletes previously quarantined cruft that has aged past the grace window and cleans up stale mirror files; it does not quarantine new unreachable content.
- `cas vacuum` is the one-shot maintenance path: it runs `fsck`, optionally repairs derivable metadata, applies expiry/materialization policy, repacks reachable loose objects, and then applies GC with the current prune-grace policy.
- `enable_influx` and `enable_prom` remain parseable config flags, but they should be treated as placeholder or experimental toggles until real adapter surfaces land.
- `auth_token` is the only built-in API auth mechanism today; if it is empty, `/api/*` is unauthenticated.
- `pgwire` should be treated as a preview alpha interface for `v0.4.0`: useful for smoke tests and demos, but not yet a broad PostgreSQL compatibility promise.
