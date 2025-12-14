---
sidebar_position: 1
---

# Contributing

This page is a practical checklist for making changes to SydraDB without fighting the toolchain.

For repository-wide conventions, also see `AGENTS.md` (mirrored in `Reference/Source Reference/Repository/AGENTS.md`).

## Prerequisites

- Zig `0.15.x` (recommended: use the pinned Nix toolchain)
- Node.js + npm (only required for docs development under `docs/`)

## Recommended workflow

### 1) Enter the pinned dev shell (recommended)

```sh
nix develop
zig version
```

### 2) Build and test

From the repo root:

```sh
zig build
zig build test
```

### 3) Format

```sh
zig fmt src cmd docs examples
```

### 4) Run the same checks CI runs (optional but recommended)

```sh
pip install pre-commit
pre-commit run --all-files --show-diff-on-failure
```

See: `Reference/Source Reference/Repository/.pre-commit-config.yaml`

## Docs contributions

The documentation site lives under `docs/` and is deployed to GitHub Pages from `main`.

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

## Where to put things

- Runtime code: `src/`
- CLI tools: `cmd/`
- Demos: `examples/`
- Docs: `docs/docs/` (Docusaurus content)
