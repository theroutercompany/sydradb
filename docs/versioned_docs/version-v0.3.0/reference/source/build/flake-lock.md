---
sidebar_position: 5
title: flake.lock
---

# `flake.lock`

## Purpose

Pins the exact revisions of the flake inputs used by `flake.nix` to make builds reproducible.

This file is generated/maintained by Nix and typically updated via:

```sh
nix flake update
```

## What it contains

The lockfile records, for each input:

- repository identity (e.g. GitHub owner/repo)
- a fixed revision (`rev`)
- a content hash (`narHash`)
- timestamps (`lastModified`)

Notable pinned inputs in this project include:

- `nixpkgs` (nixos-unstable)
- `zig-overlay`

