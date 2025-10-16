# Repository Guidelines

## Project Structure & Module Organization
Runtime entry starts in `src/main.zig`, wiring the CLI and HTTP servers. Core logic lives in `src/sydra/`: `storage/` for WAL and retention, `query/` for sydraQL planning and execution, and `codec/` for compression routines. Operational tooling resides in `cmd/`, reusable fixtures in `examples/`, and integration assets or scratch data sit under `tests/` or `data/` to keep the tree clean.

## Build, Test, and Development Commands
- Use Zig 0.15.x; `nix develop` and CI are pinned to that release.
- `zig build` generates the debug binary at `zig-out/bin/sydradb` for day-to-day work.
- `zig build -Doptimize=ReleaseSafe` emits an optimized artifact suitable for profiling or packaging.
- `zig build run -- serve` launches the HTTP daemon in the current directory.
- `zig build test` executes all inline Zig tests; run before every push.
- `nix develop` or `nix build` enters the pinned toolchain or produces `result/bin/` artifacts when using the Nix workflow.

## Coding Style & Naming Conventions
Follow Zig defaults: four-space indentation, trailing commas in multiline literals, lowerCamelCase for values, UpperCamelCase for types, and SCREAMING_SNAKE_CASE for comptime constants. Scope imports narrowly and avoid unnecessary globals. Before committing, run `zig fmt src cmd docs examples` to keep formatting consistent.

## Testing Guidelines
Co-locate `test` blocks with the code they cover and give descriptive names such as `test "memtable applies retention"`. Use `zig build test` for fast feedback. Add targeted fixtures under `examples/` when reproducing bugs, and cover WAL replay, compaction, snapshot/restore, and sydraQL planning whenever you modify related areas.

## Commit & Pull Request Guidelines
Write imperative commit subjects capped at 72 characters and keep formatting-only changes isolated. Squash fixups locally before pushing. Pull requests should link relevant issues, summarize behavioral or schema changes, and include verification artifacts (e.g., command outputs or API snippets). Update `docs/` and `sydradb.toml.example` whenever you add or modify runtime flags.

## Security & Configuration Tips
Never commit credentials or production data; prefer environment variables or `.env` overrides. Document new configuration knobs in `sydradb.toml.example` and mirror them in `docs/`. Clean temporary data in `data/` or `tests/` before merging to keep fresh clones reproducible.
