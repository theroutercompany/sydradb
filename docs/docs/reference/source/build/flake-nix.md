---
sidebar_position: 3
title: flake.nix
---

# `flake.nix`

## Purpose

Defines a Nix flake that provides:

- a reproducible build (`nix build`)
- a developer shell (`nix develop`) with a pinned Zig toolchain and common dev utilities

## Inputs

- `nixpkgs` (`nixos-unstable`)
- `zig-overlay` (`mitchellh/zig-overlay`)

The overlay is used to select a specific Zig version when available.

## System matrix

The flake defines a fixed set of supported systems:

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

Most outputs are generated for all systems using `forAllSystems`.

## Zig pinning logic

Per system, the flake selects `zigPinned` as:

1. `zig-overlay.packages.${system}."zig-0.15.0"` if present
2. else `zig-overlay.packages.${system}."0.15.0"` if present
3. else `pkgs.zig_0_15` if present
4. else `pkgs.zig`

This is intended to keep contributors on Zig 0.15.x while still providing a fallback.

## `packages.default`

Builds a `stdenvNoCC.mkDerivation` that:

- sets `src = ./.`
- uses `zig` as a `nativeBuildInputs`
- forces Zig caches into `$TMPDIR` to keep Nix builds writable:
  - `ZIG_GLOBAL_CACHE_DIR = "$TMPDIR/zig-cache"`
  - `ZIG_LOCAL_CACHE_DIR = "$TMPDIR/zig-local-cache"`
- runs:
  - `zig build -Doptimize=ReleaseSafe`
- installs via:
  - `zig build -Doptimize=ReleaseSafe -p $out`

## `devShells.default`

Provides a shell with:

- `zig` (pinned)
- `zls`
- `ripgrep`
- `git`
- `nixfmt`

And sets caches to repository-local directories:

- `ZIG_GLOBAL_CACHE_DIR = ".zig-cache"`
- `ZIG_LOCAL_CACHE_DIR = ".zig-local-cache"`

The `shellHook` prints the Zig version on entry.

## `formatter`

Exports `nixfmt` as the flake formatter (preferring `nixfmt-classic` when present).

