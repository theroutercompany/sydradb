---
sidebar_position: 2
title: tests/README.md
---

# `tests/README.md`

## Purpose

Describes the intended long-term structure of the `tests/` directory as a home for:

- SQL trace replays
- golden fixtures
- ORM smoke suites
- a curated subset of PostgreSQL regression tests

It also points to the project’s compatibility testing documentation for overall direction.

## Key points

- Current implemented fixture:
  - `translator/cases.jsonl` (consumed by translator tests)
- Planned (not yet present) subdirectories:
  - `traces/`, `fixtures/`, `orm/`, `regression/`

