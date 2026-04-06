# Demo Scripts

These scripts are the reproducible `v0.4.0` alpha demos referenced by the release plan.

Run them from the repo root after `zig build`:

- `bash demos/demo-quickstart.sh`
- `bash demos/demo-sydraql-compiled.sh`
- `bash demos/demo-cas-lifecycle.sh`
- `bash demos/demo-pgwire-preview.sh`

Each script creates its own temporary workspace and prints one or more `CHECKPOINT` lines so breakage is obvious during manual validation.
