---
sidebar_position: 7
title: src/sydra/compat/fixtures/translator.zig
---

# `src/sydra/compat/fixtures/translator.zig`

## Purpose

Loads SQL→sydraQL translation test cases from a JSONL (JSON Lines) fixture file.

The module is used by tests (see `tests/translator/cases.jsonl`) to validate translator behavior against a fixed suite of inputs.

## See also

- [SQL → sydraQL translator](../query/translator.md)
- [Compatibility: SQLSTATE](./sqlstate.md) (error cases)

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

## Code excerpt

```zig title="src/sydra/compat/fixtures/translator.zig (loadCases excerpt)"
pub fn loadCases(alloc: std.mem.Allocator, path: []const u8) !CaseList {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(contents);

    var cases = std.array_list.Managed(Case).init(alloc);
    errdefer {
        for (cases.items) |case| {
            alloc.free(case.name);
            alloc.free(case.sql);
            alloc.free(case.notes);
            switch (case.expect) {
                .success => |s| alloc.free(s.sydraql),
                .failure => |f| {
                    alloc.free(f.sqlstate);
                    alloc.free(f.message);
                },
            }
        }
        cases.deinit();
    }

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return FixturesError.InvalidType;
        const obj = parsed.value.object;

        const name = try dupeField(alloc, obj, "name");
        const sql = try dupeField(alloc, obj, "sql");
        const notes = try dupeOptionalField(alloc, obj, "notes", "");

        const expect_val = obj.get("expect") orelse return FixturesError.MissingField;
        const expect = try parseExpect(alloc, expect_val.*);

        try cases.append(.{ .name = name, .sql = sql, .expect = expect, .notes = notes });
    }

    return CaseList{ .alloc = alloc, .cases = try cases.toOwnedSlice() };
}
```
