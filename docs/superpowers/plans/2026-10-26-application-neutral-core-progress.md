# Project ledger: application-neutral core

Plan: `docs/superpowers/plans/2026-10-26-application-neutral-core.md`
Spec: `docs/superpowers/specs/2026-10-26-application-neutral-core-design.md`
Persistent goal: active in this conversation; no deadline or token budget.

## Current checkpoint

M1 / Task 2 is in progress. The storage baseline passed. The runtime baseline
hung in a publication wait cycle. The controller captured its stacks and stopped
only the owned test process. Regression tests now precede the production fix.
Task 4 is implemented and awaits controller verification. A separate worker owns
the approved neutral HTTP routes and tests.
The current branch is `codex/native-market-storage` at `42fbd55`.

| Milestone | State | Acceptance evidence |
| --- | --- | --- |
| M1: native-storage stabilization | In progress | Baseline checks started; see below |
| M2: application boundaries | Planned | Read-only Luna review in progress |
| M3: query limits | Planned | Read-only Luna review in progress |
| M4: general selection | Planned | No implementation evidence |
| M5: generic rollups and final audit | Planned | No implementation evidence |

## Starting work and preservation

The starting diff contains 5,134 insertions and 589 deletions across:

- `src/sydra/engine.zig`
- `src/sydra/storage/cas.zig`
- `src/sydra/storage/market_catalog.zig` and `market_reader.zig`
- `src/sydra/storage/market_runtime.zig`
- `tools/native_market_soak_driver.zig`

`CLAUDE.md` is an existing untracked file. Do not claim it as project output.

Baseline copies, SHA-256 manifest, and binary diff:
`/private/tmp/sydradb-core-20261026-gdxun_3i/`.

The copied files are in `baseline/`. `baseline.json` records HEAD and file hashes.
`baseline.diff` records the exact starting diff. These are local checkpoint
artifacts, not a replacement for the user's source tree or an external backup.

## Evidence log

| Check | Result | Evidence |
| --- | --- | --- |
| Release-script suite during initial review | PASS: 35 tests under Python 3.13.15, 8.101 seconds | Terminal output in this conversation |
| System Python attempt | Python 3.9.6 rejects `zip(strict=True)` | Initial review output; no product fix applied |
| Direct pinned Zig version | 0.15.1 | Terminal output |
| Direct Zig storage baseline | Did not run tests: global cache permission, then macOS system-symbol link failure | `storage-baseline.log` in checkpoint directory |
| Repository Nix storage baseline | PASS: 210/210 tests; terminal exit 0 | `storage-nix-baseline.log` in checkpoint directory |
| Repository Nix runtime baseline | FAIL: 498 tests completed before a hang; owned process stopped with SIGTERM | `runtime-baseline.log`, `runtime-baseline-sample.txt` |
| Idle drain regression before fix | FAIL: expected `Timeout`, got `false` with the writer stopped | `drain-red.log`; terminal exit 1 |
| Publication regression checks | PASS: 6/6, including the original hung test | `publication-green.log`; terminal exit 0 |
| Storage after schema extraction | PASS: 210/210 | `storage-after-schema.log`; terminal exit 0 |
| Full runtime after first publication fix | FAIL: zero-timeout regression, three CAS mirror error logs, HTTP EOF panic | `runtime-after-publication.log`; terminal exit 1 |
| Publication deadline and compatibility checks | PASS: 8/8 | `publication-deadline-green.log`; terminal exit 0 |
| Neutral HTTP routes after EOF fix | PASS: 4/4 | `neutral-http-green.log`; terminal exit 0 |

The runtime build summary reports completed tests, but its terminal exit is 1.
Do not count this as a passing runtime suite. The stack shows the producer in
`MarketBatchCompletion.wait` and the sole writer waiting for pending registrations
inside `capturePublishedMarketCatalogSnapshot`. The producer releases its
reservation only after the writer completes its batch.

| Issue | Change under verification | Evidence |
| --- | --- | --- |
| Writer waits for its own future completion | Capture published identities without waiting in the writer; external callers wait before requesting an ordered flush | Stack sample, reservation lifetime, writer loop |
| Idle drain can return before consuming its flush request | Include pending flush requests and generation changes in the drain condition | `requestFlush`, `waitForDrainedStateWithTimer` |

The independent patch review found an unbounded external registration wait.
Registration waiting and forced drain now share one 30-second timer. The new
prequeue regression also checks registration timeout and later success.
The existing zero-timeout drain contract remains a poll of the drained state.

The full runtime run reached previously unexecuted tests. It does not prove that
the CAS mirror failures were introduced by this project. A read-only worker is
tracing their cause. The HTTP correction fixture has no final newline and exposes
a body-reader panic. Its worker must fix EOF handling, not add a newline to hide it.

## Delegation

The native agent tool ignored the requested Luna override and attempted an
unsupported `gpt-5.5` model. No review result came from those failed agents.

The local Codex CLI starts read-only child sessions with explicit
`--model gpt-6-luna` and `model_reasoning_effort="max"`. Parent sandbox startup
failed first. Automatic approval allowed the same CLI call with a read-only
child sandbox. No sandbox bypass flags were used.

- Boundary review: `core-boundary-review.md`; event log `core-boundary-agent.jsonl`.
- Query review: `query-contract-review.md`; event log `query-contract-agent.jsonl`.

The boundary review completed with terminal exit 0. It recommends extracting
pure policy and schema definitions before moving stateful rollup processors.
The query review completed with terminal exit 0. It identifies allocator ownership,
storage scan accounting, and prepared-execution reset as required query-limit boundaries.

Task 4 implementer owns only `applications/trading/schema.zig` and
`storage/market_catalog.zig`. It must preserve the existing dirty catalog work.
The controller will run tests after inspecting the diff. Result and event log:
`schema-extraction-result.md` and `schema-extraction-agent.jsonl`.

The schema worker completed with terminal exit 0. The controller inspected the
diff against the preserved baseline and formatted both owned files with Zig 0.15.1.
No formatter or test process from that worker remained in the targeted process check.

The independent concurrency review completed with terminal exit 0. It confirms
the producer/writer progress cycle. Its suggested writer retry is not implemented:
the controller is moving external waiting outside publication locks and preserving
the existing filter for unpublished identities. See `publication-deadlock-review.md`.

The neutral HTTP worker owns only `src/sydra/http.zig`. It must use the existing
handlers and add cross-route tests for sensor, service, and trading schemas.
Result and events: `neutral-http-result.md`, `neutral-http-agent.jsonl`.

The neutral route worker completed with exit 0. The controller corrected its
schema-count assumption and changed the contract test to native storage. The test
now checks cross-route corrections and projected reads after flush. The controller
also updated `README.md` and `docs/docs/reference/http-api.md` with neutral routes
and a sensor example. The HTTP worker fixed the EOF panic. The focused neutral-route checks passed.
The complete runtime suite still requires a passing rerun after the CAS fix.

The HTTP EOF worker and both read-only reviews completed with terminal exit 0.
The CAS review traces retained descriptors to missing local mirror paths. The
initialization review maps explicit trading initialization and affected fixtures.

The active CAS implementer owns only `storage/cas.zig`; see
`cas-mirror-fix-agent.jsonl`. The controller owns its integration and runtime tests.

Independent checkpoint worktrees use remote main as their base:

- `plan-pr/`: project design, implementation plan, and evidence ledger.
- `http-eof-pr/`: standalone HTTP final-record fix and its causal test.

These directories are under the checkpoint artifact directory. No commit or pull
request was complete at this ledger snapshot.

All delegation outputs live in the checkpoint directory.

## Rulings

1. Work in the existing feature checkout because required native-storage changes
   are uncommitted. Preserve exact baseline copies before edits. A clean worktree
   from HEAD would omit the implementation the user asked to finish.
2. The user authorized local implementation and a persistent project. Skill-level
   planning handoff gates do not require another permission prompt for that work.
3. Use visible project documents as the durable ledger. The user subsequently
   authorized atomic checkpoint commits and scoped pull requests. Use feature
   branches. Do not push directly to main. Merge remains outside this authority.
4. Preserve legacy serialized names even after application code moves. Renaming
   a digest domain or metric changes storage identity and requires a separate
   compatibility design.
5. Treat local checks as local evidence. Hosted release acceptance is not implied
   by this project request or by a passing local harness.
6. The user approved neutral `/api/v1/schemas/...` and `/api/v1/rows/...` routes
   while preserving existing market routes. Use POST `/api/v1/schemas/register`,
   GET `/api/v1/schemas`, GET `/api/v1/schemas/<metric>`, POST
   `/api/v1/rows/ingest`, and POST `/api/v1/rows/query`. Share existing handlers.
7. The runtime baseline binary compiled before Task 4 began. Source edits during
   its execution cannot affect that baseline executable. Do not start a competing
   build until the baseline completes.
8. The user approved empty fresh databases through the generic API. Preserve
   existing schemas and legacy market-route compatibility. Implement explicit
   trading initialization instead of retaining automatic generic catalog seeding.
9. Remote `main` is `9a39597`. The current feature branch has 46 unpublished
   commits, including native-storage dependencies. No open pull requests existed
   at the remote check. Prepare independent fixes from remote main when possible,
   and use explicit dependency branches for the native-storage changes.

## Resume instructions

Read the spec and plan. Check `git status --short`. Inspect the current owned
process handles and logs before repeating any test. Finish the baseline, collect
the two reviews, and start the smallest verified application-policy extraction.
Do not mark M1 complete based only on the Python runner tests.
