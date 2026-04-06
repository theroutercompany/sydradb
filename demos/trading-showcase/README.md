# SydraDB Trading Showcase

This workspace is the trading-focused walkthrough for SydraDB.

Goals:

- show how market rows are written into SydraDB
- surface definitions, runtime state, and grouped analysis using the current trading APIs
- compare corrected market data across storage revisions without leading with storage jargon

## Commands

From `/Users/rexliu/sydradb/demos/trading-showcase`:

```bash
npm install
npm run dev
```

Built preview:

```bash
npm run build
npm run preview
```

Docker:

```bash
docker build -f demos/trading-showcase/Dockerfile -t sydradb-trading-showcase .
docker run --rm -p 4277:4277 sydradb-trading-showcase
```

Unified container:

```bash
docker build -f demos/showcase/Dockerfile -t sydradb-showcase .
docker run --rm -p 4177:4177 -p 4277:4277 sydradb-showcase
```
