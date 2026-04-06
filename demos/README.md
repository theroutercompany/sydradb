# Demo Scripts

These scripts are the reproducible `v0.4.0` alpha demos referenced by the release plan.

Run them from the repo root after `zig build`:

- `bash demos/demo-quickstart.sh`
- `bash demos/demo-sydraql-compiled.sh`
- `bash demos/demo-cas-lifecycle.sh`
- `bash demos/demo-pgwire-preview.sh`
- `bash demos/demo-local-ingest-socket.sh`
- `bash demos/demo-combined-http-socket.sh`
- `bash demos/demo-http-large-ingest.sh`
- `bash demos/demo-http-concurrent-fanout.sh`

Each script creates its own temporary workspace and prints one or more `CHECKPOINT` lines so breakage is obvious during manual validation.
