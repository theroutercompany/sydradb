# SydraDB Showcase Platform

This workspace is the living showcase harness for SydraDB.

Goals:

- run real `sydradb` processes against deterministic local fixtures
- expose fast-moving CAS, `sydraQL`, compiler, and engine work through scenario packs
- keep the UI and runner stable while the product surface changes rapidly

## Layout

- `runner/` – local JSON API, session manager, seeders, and scenario execution
- `scenarios/` – manifest-driven scenario registry
- `fixtures/` – deterministic datasets and expected evidence snapshots
- `ui/` – lightweight React/Vite interface
- `shared/` – shared contracts between runner and UI

## Commands

From `demos/showcase/`:

```bash
npm install
npm run dev
```

Runner only:

```bash
npm run dev:runner
```

UI only:

```bash
npm run dev:ui
```

Tests:

```bash
npm test
```

## Expectations

- Build `./zig-out/bin/sydradb` from the repo root before running scenario tests.
- The runner uses real temp workspaces under your OS temp directory and removes them on session reset.
- `multi-writer-heads` is intentionally present but gated off until the underlying capability is ready to demo honestly.
