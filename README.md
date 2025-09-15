# sydraDB

A fast, embeddable time-series database in Zig.

## Why
- Local-first, single binary
- Crash-safe WAL → columnar TS segments
- Simple query layer (sydraQL)

## Quick start
```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/sydradb            # serve using sydradb.toml
curl -XPOST localhost:8080/api/v1/ingest --data-binary $'{"series":"weather.room1","ts":1694300000,"value":24.2}\n'
```

## Nix (reproducible toolchain)
If you use Nix, this repo includes a flake that pins Zig and provides a dev shell:

```bash
# Start a shell with the pinned Zig
nix develop

# Build the package (installs to ./result)
nix build
./result/bin/sydradb serve
```

## Status
Pre-alpha. Expect dragons.

## License
Apache-2.0

## CLI
```bash
./zig-out/bin/sydradb             # serve (HTTP): /api/v1/ingest, /api/v1/query/range, /metrics
./zig-out/bin/sydradb ingest      # read NDJSON from stdin into local WAL
./zig-out/bin/sydradb query <series_id> <start_ts> <end_ts>
./zig-out/bin/sydradb compact     # merge small→large segments (v2 stub)
./zig-out/bin/sydradb snapshot <dst_dir>
./zig-out/bin/sydradb restore  <src_dir>
./zig-out/bin/sydradb stats       # print simple counters
```

Config: `sydradb.toml`
```
data_dir = "./data"
http_port = 8080
fsync = "interval"  # always|interval|none
flush_interval_ms = 2000
memtable_max_bytes = 8388608
mem_limit_bytes = 268435456
auth_token = ""  # set non-empty to require Bearer auth on /api/*
enable_influx = false
enable_prom = true
# Per-namespace TTL
retention.weather = 30
```
