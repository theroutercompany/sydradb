---
sidebar_position: 2
title: README.md
---

# `README.md`

## Purpose

Top-level introduction to SydraDB:

- What the project is (“fast, embeddable time-series database in Zig”)
- The “why” (single binary, WAL → segments, minimal query surface)
- A quickstart that builds and runs the HTTP server and ingests a point
- Notes on Nix + direnv usage
- CLI surface summary

## Practical notes

- The README includes an inline config snippet for `sydradb.toml`.
- SydraDB’s current config parser is intentionally minimal and **does not reliably support inline comments** (for example `http_port = 8080 # comment`).

If you copy config snippets from the README, prefer using the “known-good” configuration format documented here:

- [Configuration (`sydradb.toml`)](../../configuration)

