---
sidebar_position: 2
---

# CI and releases

SydraDB uses GitHub Actions for:

- Code checks and release artifacts: `.github/workflows/ci.yml`
- Docs build and deploy to GitHub Pages: `.github/workflows/docs.yml`

## Code CI (`ci.yml`)

### What runs on PRs

- `checks` job on macOS + Ubuntu
- Runs `pre-commit` hooks that include:
  - `zig fmt --check`
  - `zig build`
  - `zig build test`

### What runs on `main` pushes

- `checks` (same as PRs)
- `release-artifacts` builds `ReleaseSafe` binaries for a small target matrix and uploads tarballs

### Publishing a GitHub Release

Tag pushes like `v0.1.0` trigger the `publish-release` job which:

- downloads the built artifacts
- publishes a GitHub Release with generated notes

## Docs deploy (`docs.yml`)

Docs deploy runs on pushes to `main` and:

- builds the Docusaurus site in `docs/`
- deploys to GitHub Pages via the Actions Pages pipeline

Repo setting required (one-time):

- `Settings → Pages → Source = GitHub Actions`

See also:

- `Reference/Source Reference/Repository/.github/workflows/*`
