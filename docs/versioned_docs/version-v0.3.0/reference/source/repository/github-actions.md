---
sidebar_position: 7
title: .github workflows
---

# `.github/workflows/*`

This repository uses GitHub Actions for two main concerns:

- **CI for code** (fmt/build/test + release artifacts)
- **CI for docs** (build and deploy the Docusaurus site to GitHub Pages)

## `ci.yml` (code CI)

### `checks` job

- Runs on `ubuntu-latest` and `macos-latest`.
- Installs Zig `0.15.1`.
- Runs `pre-commit run --all-files --show-diff-on-failure` (which performs `zig fmt --check`, `zig build`, and `zig build test`).

### `release-artifacts` job

- Runs on non-PR events (pushes to `main` and tags).
- Builds a `ReleaseSafe` binary for a small target matrix and uploads `.tar.gz` artifacts.

### `publish-release` job

- Runs on tag pushes matching `v*`.
- Downloads the build artifacts and publishes a GitHub Release with generated notes.

## `docs.yml` (docs deploy)

- Runs on pushes to `main`.
- Builds the Docusaurus site under `docs/`.
- Deploys to GitHub Pages using the GitHub Actions Pages pipeline.

Prerequisite setting:

- In the repository: `Settings → Pages → Source = GitHub Actions`

