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

Built preview:

```bash
npm run build
npm run preview
```

## How It Runs

- The UI is a React/Vite frontend.
- The runner is a local Express JSON API that serves `/api/demo/*`.
- The runner creates temporary workspaces under your OS temp directory.
- Each workspace gets its own generated `sydradb.toml`, local `data/` directory, and HTTP port.
- The runner then starts real `sydradb` child processes against those workspaces, seeds them with fixture data, and executes scenario steps through HTTP or CLI calls.

In local development, `npm run dev` runs:

- `npm run dev:runner` on `127.0.0.1:4177`
- `npm run dev:ui` on `127.0.0.1:4173`

The Vite dev server proxies `/api/demo/*` to the runner.

In built/preview mode, the runner serves the compiled frontend itself, so the UI and API come from the same process.

## Docker

The showcase can run as a single container that includes:

- the built `sydradb` binary
- the built showcase runner
- the built static UI
- scenario manifests and fixtures

Build from the repo root:

```bash
docker build -f demos/showcase/Dockerfile -t sydradb-showcase .
```

Run it:

```bash
docker run --rm -p 4177:4177 sydradb-showcase
```

Then open:

```text
http://127.0.0.1:4177/
```

Container notes:

- The container runs the Express runner, which also serves the built UI.
- The runner binds to `0.0.0.0` inside the container through `SHOWCASE_HOST=0.0.0.0`.
- The runner uses `SYDRADB_BIN=/app/bin/sydradb`.
- Scenario temp workspaces are still ephemeral and live inside the container filesystem.

## Expectations

- Build `./zig-out/bin/sydradb` from the repo root before running scenario tests.
- The runner uses real temp workspaces under your OS temp directory and removes them on session reset.
- `multi-writer-heads` is intentionally present but gated off until the underlying capability is ready to demo honestly.
