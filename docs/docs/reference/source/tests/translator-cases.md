---
sidebar_position: 4
title: tests/translator/cases.jsonl
---

# `tests/translator/cases.jsonl`

## Purpose

Provides JSONL fixtures for SQL→sydraQL translation behavior.

Each line is a single JSON object consumed by:

- `src/sydra/compat/fixtures/translator.zig` (`loadCases`)

The fixtures are used by unit tests to:

- validate successful translations produce expected sydraQL strings
- validate unsupported/invalid SQL falls back with an expected SQLSTATE and message

## Format (per line)

Each non-empty line is a JSON object containing:

- `name` (string): stable identifier for the case
- `sql` (string): input SQL statement
- `expect` (object):
  - `kind` (string): `"success"` or `"error"`
  - if `"success"`:
    - `sydraql` (string)
  - if `"error"`:
    - `sqlstate` (string)
    - `message` (string, optional; defaults to `""`)
- `notes` (string, optional; defaults to `""`)

See `src/sydra/compat/fixtures/translator.zig` for the exact parsing rules.

## What’s currently covered

The current fixture set includes basic rewrites and fallbacks for:

- `SELECT` constants / projections / `WHERE` / `*`
- `INSERT` basic and `RETURNING`
- `UPDATE` with and without `WHERE`, plus `RETURNING`
- `DELETE` with and without `WHERE`, plus `RETURNING`

Several “invalid” statements are included to assert fallback behavior (e.g. empty `SET`, empty `WHERE`, missing `RETURNING` list).

