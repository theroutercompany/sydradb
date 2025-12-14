---
sidebar_position: 5
title: .pre-commit-config.yaml
---

# `.pre-commit-config.yaml`

## Purpose

Defines local checks that CI also runs, so contributors can catch problems before pushing.

## Hooks

### `pre-commit-hooks`

- `trailing-whitespace` (excluding `vendor/`)
- `end-of-file-fixer` (excluding `vendor/`)
- `check-merge-conflict`
- `check-yaml`

### Local hooks

- `zig fmt --check build.zig src cmd examples docs`
- `zig build -Doptimize=Debug`
- `zig build test`

## Usage

Install once:

```sh
pip install pre-commit
pre-commit install
```

Run on demand:

```sh
pre-commit run --all-files --show-diff-on-failure
```

