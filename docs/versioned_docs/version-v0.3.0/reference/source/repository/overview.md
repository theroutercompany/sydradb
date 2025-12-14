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

- [`README.md`](./readme-file) – high-level pitch + quickstart + CLI summary
- [`AGENTS.md`](./agents) – contributor guidelines (style, tests, docs expectations)
- [`sydradb.toml` / `sydradb.toml.example`](./configuration-files) – configuration files (note: parser has limitations)
- [`.pre-commit-config.yaml`](./pre-commit) – local checks that CI runs (fmt/build/test)
- [`.envrc`](./direnv) – direnv integration for the pinned Nix dev shell
- [`.github/workflows/*`](./github-actions) – CI workflows + docs deploy
- [`.github` templates](./github-templates) – PR and issue templates
- [`SECURITY.md`](./security) – security policy (currently a template)
- [`LICENSE`](./license) – Apache-2.0
- [`project.json`](./project-json) – generated design/context artifact
- [`.gitignore`](./gitignore) – ignored build outputs and local state
