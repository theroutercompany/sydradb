---
sidebar_position: 8
---

# sydraQL readiness checklist

This page tracks the current v0 sydraQL surface as it exists today. It is a readiness document, not a greenfield wishlist.

See also:

- [sydraQL Design](../concepts/sydraql-design.md)
- [sydraQL Engineering Roadmap](./sydraql-roadmap.md)
- [sydraQL backlog](./sydraql-backlog.md)

## Spec readiness

- [x] A basic statement surface exists (`SELECT`, `INSERT`, `DELETE`, `EXPLAIN`)
- [x] Function metadata exists for a non-trivial builtin set
- [ ] Grammar and precedence are fully documented as a stable user-facing contract
- [ ] Error codes/messages are documented as a stable public API
- [ ] Practical examples cover the full supported v0 surface

## Implementation readiness

- [x] Lexer, parser, validator, planner, optimizer, and operator pipeline are present
- [x] HTTP execution path exists at `POST /api/v1/sydraql`
- [x] End-to-end scan/filter/project/aggregate/sort/limit flow exists for the implemented subset
- [ ] Tag-filter syntax in the language surface is complete
- [ ] Function execution coverage matches the current registry breadth
- [ ] Rollup/downsampling planning is implemented rather than stubbed
- [ ] Quotas and limits are enforced as a clear runtime contract

## API readiness

- [x] The HTTP endpoint exists and returns columns, rows, and stats
- [x] Query stats contain enough detail for basic debugging
- [ ] Error responses are documented and normalized as a stable contract
- [ ] Practical client examples cover both success and failure cases

## Testing & tooling readiness

- [x] Unit coverage exists in the query pipeline modules
- [x] Translator fixtures exist for the SQL bridge
- [ ] Golden suites for parser/plan/exec are in place
- [ ] Fuzz smoke tests run in CI
- [ ] Query benchmarks are published for the hot paths we care about

## Docs readiness

- [x] The docs site explains the role of sydraQL in the system
- [x] Source reference pages cover the major query modules
- [ ] The high-level docs present the supported subset cleanly enough for external users
- [ ] Readiness, backlog, and roadmap pages are reviewed regularly enough to stay truthful
