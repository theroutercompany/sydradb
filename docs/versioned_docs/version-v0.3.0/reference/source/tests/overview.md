---
sidebar_position: 1
title: Tests overview (tests)
---

# `tests` overview (`tests/*`)

This directory is the landing zone for reusable fixtures and harnesses that support SydraDB’s compatibility and correctness testing.

It is referenced by:

- translator fixture loader: `src/sydra/compat/fixtures/translator.zig`
- Postgres-compatibility testing docs: `Reference/Postgres Compatibility/Testing`

## Current contents

- `tests/README.md` – test harness structure and roadmap
- `tests/lexer/README.md` – placeholder for lexer golden cases
- `tests/translator/cases.jsonl` – SQL→sydraQL translation fixtures (JSON Lines)

