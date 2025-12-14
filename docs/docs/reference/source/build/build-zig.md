---
sidebar_position: 2
title: build.zig
---

# `build.zig`

## Purpose

Defines the Zig build graph for SydraDB:

- builds the `sydradb` executable from `src/main.zig`
- generates and injects a `build_options` module used by the runtime
- optionally links mimalloc for allocator benchmarking/perf work
- defines extra steps for tests and tooling (`bench_alloc`)

## Build options (`zig build -D...`)

### `-Dallocator-mode`

Declared as:

- `b.option([]const u8, "allocator-mode", ...) orelse "mimalloc"`

Allowed values:

- `default`
- `mimalloc` (default)
- `small_pool`

Runtime impact:

- The string is written into `build_options.allocator_mode`.
- `src/sydra/alloc.zig` uses it to select allocator implementation at comptime.

### `-Dallocator-shards`

Declared as:

- `b.option(u32, "allocator-shards", ...) orelse 0`

Runtime impact:

- Written into `build_options.allocator_shards`.
- In `small_pool` mode, this controls the number of sharded slab allocators (0 disables sharding).

## Generated module: `build_options`

The build script constructs:

- `const build_options = b.addOptions();`
- `build_options.addOption([]const u8, "allocator_mode", allocator_mode_str);`
- `build_options.addOption(u32, "allocator_shards", allocator_shards);`
- `const build_options_module = build_options.createModule();`

This module is imported into all relevant Zig root modules via:

- `root_mod.addImport("build_options", build_options_module);`

## Zig version compatibility

The build graph contains two paths depending on Zig version:

- Zig `0.15+`:
  - uses `b.createModule` and passes `.root_module` to `b.addExecutable` / `b.addTest`.
- Older Zig:
  - uses `.root_source_file` directly and then mutates `exe.root_module`.

The switch is controlled by:

- `const is015 = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 15;`

## Main executable: `sydradb`

Built from:

- `src/main.zig`

If `-Dallocator-mode=mimalloc`:

- adds include paths for `vendor/mimalloc/include` and `vendor/mimalloc/src`
- compiles `vendor/mimalloc/src/static.c` with flags:
  - `-DMI_STATIC_LIB`
  - `-DMIMALLOC_STATIC_LIB`
  - `-DMI_SEE_AS_DLL=0`
  - `-Ivendor/mimalloc/include`
  - `-Ivendor/mimalloc/src`
- links libc and `pthread`

Otherwise:

- links libc
- links `pthread` only on Linux

## Build steps

### `zig build`

Installs the `sydradb` artifact (via `b.installArtifact(exe)`).

### `zig build run -- <args...>`

Defines a `run` step that executes the installed `sydradb` artifact.

### `zig build test`

Defines a `test` step that runs tests rooted at `src/main.zig`.

Mimalloc handling:

- in Zig 0.15+, the test runner also compiles `static.c` and links `pthread` when `allocator-mode=mimalloc`.

### `zig build compat-wire-test`

Runs tests rooted at:

- `src/sydra/compat/wire/server.zig`

This isolates pgwire compatibility tests into a separate step.

### `zig build bench-alloc -- <args...>`

Builds and runs a tool executable:

- name: `bench_alloc`
- root source: `tools/bench_alloc.zig`
- imports:
  - `build_options`
  - `sydra_tooling` (a module rooted at `src/sydra/tooling.zig`)

Mimalloc handling mirrors the main executable and tests.

