---
sidebar_position: 6
title: .envrc
---

# `.envrc`

## Purpose

Enables direnv auto-activation of the pinned Nix dev shell when you `cd` into the repository.

Behavior:

- Watches `flake.nix`, `flake.lock`, and `shell.nix` so changes trigger reload.
- Prefers `use flake .` when nix-direnv is configured.
- Falls back to `use nix` for non-flake setups.

## Related docs

- `Reference/Source Reference/Build/flake.nix`
- `Reference/Source Reference/Build/shell.nix`

