---
sidebar_position: 1
title: Repository files overview
---

# Repository files overview

This section documents the *repository-level* files and conventions that shape how SydraDB is built, tested, configured, and shipped.

If you are here to understand runtime behavior and module boundaries, start with:

- `Reference/Source Reference/Entrypoints` (process entry)
- `Reference/Source Reference/src/sydra` (runtime modules)

## Contents

- `README.md` – high-level pitch + quickstart + CLI summary
- `AGENTS.md` – contributor guidelines (style, tests, docs expectations)
- `sydradb.toml` / `sydradb.toml.example` – configuration files (note: parser has limitations)
- `.pre-commit-config.yaml` – local checks that CI runs (fmt/build/test)
- `.envrc` – direnv integration for the pinned Nix dev shell
- `.github/*` – CI workflows + templates (including docs deploy to GitHub Pages)
- `SECURITY.md` – security policy (currently a template)
- `LICENSE` – Apache-2.0
- `project.json` – generated design/context artifact

