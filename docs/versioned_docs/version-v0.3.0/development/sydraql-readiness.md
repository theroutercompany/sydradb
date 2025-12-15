---
sidebar_position: 8
---

# sydraQL readiness checklist

This page is a lightweight checklist used by the sydraQL roadmap to track “ship readiness” gates.

See also:

- [sydraQL Design](../concepts/sydraql-design.md)
- [sydraQL Engineering Roadmap](./sydraql-roadmap.md)
- [sydraQL backlog](./sydraql-backlog.md)

## Spec readiness

- [ ] sydraQL grammar surface is documented (statements, expressions, precedence)
- [ ] Function catalog lists argument/return types and nullability rules
- [ ] Error model lists user-facing codes and messages
- [ ] Examples cover common cases (scan, downsample+fill, rate, insert, delete)

## Implementation readiness

- [ ] Lexer, parser, validator paths are feature-complete for the v0 surface
- [ ] Planner + optimizer produce stable physical plans for key query shapes
- [ ] Operator pipeline supports scan/filter/project/aggregate/sort/limit end-to-end
- [ ] Limits/quotas enforced (result size, series count, request size)

## API readiness

- [ ] HTTP endpoint (`POST /api/v1/sydraql`) contract documented and tested
- [ ] Error responses are consistent (`{"error":"..."}` and status codes)
- [ ] `stats` payload includes enough diagnostics to debug slow queries

## Testing & tooling readiness

- [ ] Golden tests exist for parser/plan/exec
- [ ] Fuzz smoke tests (at least lexing) run in CI
- [ ] Benchmarks exist for critical hot paths (lexer, aggregation, sort/top-k)

## Docs readiness

- [ ] “Start Here” docs explain sydraQL usage at a practical level
- [ ] “Source Reference” docs cover the query pipeline modules and link them together

