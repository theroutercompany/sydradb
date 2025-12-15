---
sidebar_position: 3
tags:
  - docs
---

# Documentation site

This repository’s documentation site is a Docusaurus project rooted at `docs/`.

See also:

- [Docusaurus toolbox](./docusaurus-toolbox.md) (built-in features and authoring patterns)
- [Documentation coverage plan](./documentation-plan.md) (how to document the repo line-by-line)

## Local development

From the repo root:

```sh
cd docs
npm install
npm start
```

Build a production site:

```sh
cd docs
npm run build
```

## Deployment (GitHub Pages)

The site is configured for GitHub Pages project hosting:

- `docs/docusaurus.config.js` sets:
  - `url = "https://theroutercompany.github.io"`
  - `baseUrl = "/sydradb/"`

CI deploys the generated static site from `docs/build` using GitHub Actions.

If Pages is not yet enabled in the repository settings:

1. Go to `Settings → Pages`
2. Set **Source** to **GitHub Actions**

See also:

- [CI and releases](./ci)
