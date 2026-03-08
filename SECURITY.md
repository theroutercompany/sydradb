# Security Policy

## Current status

SydraDB is pre-alpha software. Security hardening is in progress and the project does not yet make broad deployment guarantees.

The current release focus is:

- single-node TSDB behavior
- HTTP ingest and query correctness
- narrow PostgreSQL simple-query compatibility
- accurate documentation of supported versus unsupported surfaces

## Supported versions

Only the current `main` branch and the most recent tagged release should be treated as candidates for security fixes.

Older tags may remain available for reproducibility, but they should not be assumed to receive coordinated security updates.

## Reporting a vulnerability

Please report vulnerabilities privately to the maintainer rather than opening a public GitHub issue.

Use:

- GitHub private security advisory, if enabled for the repository
- or a direct maintainer contact channel if one is listed on the repository profile

Include:

- affected version or commit
- impact summary
- reproduction steps or proof of concept
- any suggested mitigation

## Response expectations

- Initial acknowledgement target: within 7 days
- Triage target: severity and reproduction assessment as soon as the issue can be reproduced
- Fix timing: best effort, based on impact and maintainer availability

## Current caveats

- If `auth_token` is empty, `/api/*` endpoints are unauthenticated
- `enable_influx` and `enable_prom` config flags are not a promise of production-ready adapter surfaces
- `small_pool`, 32-bit targets, and broader PostgreSQL compatibility are not treated as hardened deployment surfaces in the current cycle
