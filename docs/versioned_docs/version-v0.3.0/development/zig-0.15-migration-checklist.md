# Zig 0.15.x Migration Checklist

This plan captures every known change required to move the codebase and tooling from Zig 0.14.x to Zig 0.15.x. Work through the sections in order; each bullet calls out the exact files and symbols to touch so we can execute without additional clarification.

## 1. Toolchain & Automation
- [x] Update `flake.nix:19` to pin `zig-0.15.x` (remove the `zig-0.14.0` fallback logic) and ensure `shell.nix:3` selects the same package so `nix develop` exposes the new compiler.
- [x] Bump both Zig installs in `.github/workflows/ci.yml` to `version: 0.15.x` (jobs `checks` and `release-artifacts`). Keep the current target matrix, just validate the new runner can build them.
- [x] After the bump, clear cached hooks (`pre-commit clean`) so `pre-commit run --all-files` pulls the 0.15 binary. No config change needed.
- [x] Revise onboarding docs that mention the Zig pin (`AGENTS.md` or any other references) so contributors install the correct release.

## 2. Std I/O Accessors
- [x] Replace `std.io.getStdIn()`/`getStdErr()` usages with the new file helpers:
  - `src/sydra/server.zig:85` → use `var stdin_file = std.fs.File.stdin();` then `var reader_state = stdin_file.reader(&buf); const reader = reader_state.interface();`.
  - `examples/loadgen.zig:7` and `src/sydra/compat/log.zig:20` → use `std.fs.File.{stdout,stderr}().writer(&buf)` (keep the writer state alive and grab `.interface()` when needed).
- [x] Audit for any other direct `std.io.get*` calls and convert them to `std.fs.File.*`.

## 3. HTTP Server Plumbing
- [x] In `src/sydra/http.zig` allocate read/write buffers per connection, then call:
  ```zig
  var reader_state = connection.stream.reader(&in_buf);
  var writer_state = connection.stream.writer(&out_buf);
  var http_server = std.http.Server.init(reader_state.interface(), writer_state.interface());
  ```
- For request bodies switch to the new reader constructors:
  - Use `var body_reader = try req.readerExpectContinue(&buf);` when honoring `Expect: 100-continue`, or `req.readerExpectNone(&buf)` when no expectation is present.
  - The returned value is `*std.http.Server.Reader` which already satisfies `std.Io.Reader`, so call `body_reader.readNoEof(...)` directly.
- `respondStreaming` now expects the buffer argument first; update calls at `src/sydra/http.zig:426` and `src/sydra/http.zig:472`.
- Ensure the writer state lives as long as the connection loop (don’t let it go out of scope).

## 4. Pgwire Server & Protocol
- [x] Wrap connections with explicit buffer states before the handshake (`src/sydra/compat/wire/server.zig:24-66`) and pass `reader_state.interface()`/`writer_state.interface()` into `session.performHandshake`.
- Update `messageLoop` to accept `*std.Io.Reader`/`*std.Io.Writer` and replace `reader.*.readNoEof` with `reader.readNoEof`.
- Adjust `protocol.zig` helpers (`readStartup`, writers, tests) to operate on interfaces rather than the legacy reader struct.
- Fix tests in `session.zig` to build interface wrappers from `std.io.fixedBufferStream` via `.reader()`/`.writer()` → `.interface()`.

## 5. Storage & Codec Reads/Writes
- [x] For every `file.reader(&buf)` call (WAL, segments, tags, manifests) hold on to the state and interact through its `.interface()`:
  ```zig
  var reader_state = f.reader(&buf);
  const reader = reader_state.interface();
  try reader.readNoEof(...);
  ```
- Update helper functions such as `readExact` (`src/sydra/storage/wal.zig`) and the Gorilla codec readers to take `*std.Io.Reader` and use the new method names.
- When using `file.writer(&buf)` grab the interface via `writer_state.interface()` instead of the deprecated pointer hack.

## 6. Error Handling & API Tightening
- [x] Replace the `_ = err;` pattern in `src/sydra/engine.zig:189-193` with explicit error handling (e.g., a `catch |err| { std.log.warn(...); continue; }` block) because Zig 0.15 no longer allows silent discards.
- [x] Review any `catch` blocks that mention `error.EndOfStream`; the new reader error set differs. Either handle it explicitly or map it to your own error type.
- [x] Run `zig fmt` after all code edits; the formatter will catch lingering layout issues (e.g., `src/sydra/codec/zstd.zig`, `src/sydra/config.zig` were cited by pre-commit).

## 7. Verification Checklist
- `zig fmt` (root)
- `zig build`
- `zig build test`
- `pre-commit run --all-files --show-diff-on-failure`
- Manual smoke tests:
  - Start HTTP server, hit `/metrics`, POST `/api/v1/ingest`, and query `/api/v1/query/range`.
  - Run `sydradb pgwire` and confirm a `psql` startup handshake succeeds (see `logs/logs_47733482709/2_Checks (ubuntu-latest).txt` for prior failures).
- When everything passes locally, push to a branch and verify the GitHub Actions matrix completes; expect cache misses on the first run due to the compiler upgrade.

> Tip: keep the migration in a dedicated branch. Once CI is green, update release notes for v0.15 adoption and retag the workflow if necessary.
