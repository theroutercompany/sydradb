---
title: tools/bench_cas.zig
---

# `tools/bench_cas.zig`

CAS benchmark harness for the `v0.4.0` alpha cycle.

Example:

```sh
zig build bench-cas
```

The harness prints three scenario summaries:

- `fresh_primary` for bootstrap/upgrade plus bundle create/verify/apply and fsck
- `packed_local` for pack plus local clone/fetch/push flows
- `migrated_legacy` for upgrade, vacuum, and fsck timing on a legacy-seeded repo
