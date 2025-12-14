---
sidebar_position: 4
title: shell.nix
---

# `shell.nix`

## Purpose

Provides a non-flake development shell for environments that do not use `nix develop`.

It mirrors the flake dev shell’s intent: expose Zig 0.15.x (when available) plus basic tooling.

## Key behavior

- Chooses Zig as:
  - `pkgs.zig_0_15` if available, otherwise `pkgs.zig`
- Installs packages:
  - `zig`
  - `zls`
  - `ripgrep`
  - `git`
  - `nixfmt` (prefers `nixfmt-classic`)
- Configures Zig caches to use repository-local paths:
  - `ZIG_GLOBAL_CACHE_DIR = ".zig-cache"`
  - `ZIG_LOCAL_CACHE_DIR = ".zig-local-cache"`
- Prints the Zig version in `shellHook`.

