# Repository Guidelines

## Project Structure & Module Organization
The runtime entrypoint lives in `src/main.zig`, which wires the CLI and HTTP services. Domain logic sits under `src/sydra/` with `storage/` for WAL and retention flows, `query/` for sydraQL planning and execution, and `codec/` for compression primitives. Operational tooling resides in `cmd/`, reusable fixtures in `examples/`, and integration assets or scratch data stay in `tests/` or `data/` to avoid polluting the main tree.

## Build, Test, and Development Commands
- `zig build` – produce a debug binary at `zig-out/bin/sydradb` for local feature work.
- `zig build -Doptimize=ReleaseSafe` – emit an optimized artifact suitable for profiling or packaging.
- `zig build run -- serve` – launch the HTTP daemon against the current working directory.
- `zig build test` – execute all inline Zig tests; run before any push.
- `nix develop` / `nix build` – enter the pinned toolchain or create a release binary at `./result/bin/`.

## Coding Style & Naming Conventions
Follow Zig defaults: four-space indentation, trailing commas in multiline literals, lowerCamelCase identifiers, UpperCamelCase types, and SCREAMING_SNAKE_CASE comptime constants. Scope imports to the file’s domain and avoid unnecessary globals. Run `zig fmt src cmd docs examples` before committing to align formatting.

## Testing Guidelines
Co-locate `test` blocks with the logic they exercise, naming them for intent (e.g. `test "memtable applies retention"`). Use `zig build test` for fast feedback, and add regression fixtures under `examples/` when bugs need reproduction. Cover WAL replay, compaction, snapshot/restore, and query planning whenever changes touch those areas.

## Commit & Pull Request Guidelines
Write imperative commit subjects capped at 72 characters and keep formatting-only changes isolated. Squash fixups locally before pushing. Pull requests should link relevant issues, summarize behavioral or schema deltas, and attach verification output such as command logs or API excerpts. Update `docs/` and `sydradb.toml.example` whenever configuration knobs or defaults change.

## Security & Configuration Tips
Never commit credentials or production data; prefer environment variables or `.env` overrides. Document new runtime flags in `sydradb.toml.example` and mirror them in `docs/`. Clean temporary data under `data/` or `tests/` before merging to keep fresh checkouts reproducible.
