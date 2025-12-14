---
sidebar_position: 7
title: src/sydra/compat/fixtures/translator.zig
---

# `src/sydra/compat/fixtures/translator.zig`

## Purpose

Loads SQL→sydraQL translation test cases from a JSONL (JSON Lines) fixture file.

The module is used by tests (see `tests/translator/cases.jsonl`) to validate translator behavior against a fixed suite of inputs.

## JSONL file format

Each non-empty line is a JSON object with fields:

- `name` (string, required)
- `sql` (string, required)
- `notes` (string, optional; defaults to `""`)
- `expect` (object, required)

The `expect` object contains:

- `kind` (string, required): `"success"` or `"error"`
- If `kind == "success"`:
  - `sydraql` (string, required)
- If `kind == "error"`:
  - `sqlstate` (string, required)
  - `message` (string, optional; defaults to `""`)

## Public API

### `pub const Expect = union(enum) { success: Success, failure: Failure }`

### `pub const Success`

- `sydraql: []const u8`

### `pub const Failure`

- `sqlstate: []const u8`
- `message: []const u8`

### `pub const Case`

- `name: []const u8`
- `sql: []const u8`
- `expect: Expect`
- `notes: []const u8`

### `pub const CaseList`

- `alloc: std.mem.Allocator`
- `cases: []Case`
- `pub fn deinit(self: *CaseList) void`
  - Frees all owned strings within `cases` and then frees the slice itself.

### `pub const FixturesError = error { UnsupportedExpectKind, MissingField, InvalidType }`

### `pub fn loadCases(alloc: std.mem.Allocator, path: []const u8) !CaseList`

Behavior:

- Reads `path` from the current working directory (`std.fs.cwd()`).
- Loads the entire file into memory (limit: `1 MiB`).
- Splits by newline.
- For each non-empty line:
  - parses JSON (`std.json.parseFromSlice`)
  - validates required fields/types
  - duplicates strings into owned allocations

On success, returns `CaseList{ .cases = toOwnedSlice(...) }`.

## Key internal helpers

- `parseExpect(alloc, value) !Expect` parses the `expect` object.
- `dupeField(alloc, obj, key) ![]u8` duplicates a required string field.
- `dupeOptionalField(alloc, obj, key, default) ![]u8` duplicates an optional string field.

