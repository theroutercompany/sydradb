---
sidebar_position: 12
title: .gitignore
---

# `.gitignore`

## Purpose

Keeps build outputs and local developer state out of version control.

## Notable ignored paths

- Zig outputs and caches:
  - `zig-out/`, `zig-cache/`
  - `.zig-cache/`, `.zig-local-cache/`
- Local runtime state:
  - `data/` (default `data_dir`)
  - `snapshots/`
  - `logs/`
- Nix/direnv:
  - `.direnv/`
  - `result` (Nix build output symlink)
- Editor/OS artifacts:
  - `.idea/`, `.vscode/`, `.DS_Store`
- Local secrets and venvs:
  - `.env`, `.venv/`

If you add new local state directories (bench outputs, scratch data), ensure they are either:

- placed under an already-ignored path (like `data/`), or
- added to `.gitignore` explicitly.

