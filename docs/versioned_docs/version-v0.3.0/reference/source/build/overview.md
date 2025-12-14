---
sidebar_position: 1
title: Build overview
---

# Build overview

SydraDB uses Zig’s build system (`build.zig`) to produce:

- the main `sydradb` executable
- test runners
- developer tools (e.g. `bench_alloc`)

Key build-time knobs are exported through a generated `build_options` module and consumed by runtime code (notably the allocator selection in `src/sydra/alloc.zig`).

## Contents

- `build.zig` – build graph definition, build options, and helper tools
- `flake.nix` / `flake.lock` – pinned Nix flake for reproducible builds and a consistent Zig toolchain
- `shell.nix` – non-flake dev shell fallback
- `vendor/mimalloc/**` – mimalloc headers and C sources used when `-Dallocator-mode=mimalloc`
