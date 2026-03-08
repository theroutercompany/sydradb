# Contributing

This repository uses a small pinned toolchain and a docs site alongside the Zig codebase. Keep changes narrow, verify them locally, and prefer updating docs when public behavior changes.

## Toolchain

- Preferred Zig: `0.15.1`
- Recommended workflow: `nix develop`
- Docs tooling: Node.js + npm under `docs/`

## Core checks

From the repository root:

```sh
zig build
zig build test
```

Optional CI-parity checks:

```sh
pip install pre-commit
pre-commit run --all-files --show-diff-on-failure
```

## Documentation

The docs site lives in `docs/`.

Local preview:

```sh
cd docs
npm install
npm start
```

Production build:

```sh
cd docs
npm run build
```

## Repository conventions

- Runtime code lives under `src/`
- Docs content lives under `docs/docs/`
- Prefer keeping GitHub issues and docs aligned with the actual codebase
- When public behavior changes, update the relevant README or docs page in the same change
- Treat `small_pool`, 32-bit targets, and broad PostgreSQL compatibility as non-default paths unless the current docs explicitly say otherwise

See also:

- `AGENTS.md`
- `/Users/rexliu/sydradb/docs/docs/development/contributing.md`
