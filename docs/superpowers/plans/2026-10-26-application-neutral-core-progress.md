# Project ledger: application-neutral core

Plan: `docs/superpowers/plans/2026-10-26-application-neutral-core.md`
Spec: `docs/superpowers/specs/2026-10-26-application-neutral-core-design.md`
Persistent goal: active in this conversation; no deadline or token budget.

## Current checkpoint

M1 / Task 2 is in progress. Native integration, crash smoke, and the bounded
restart soak passed. The integrated driver build passed all four steps. The
latest soak recovered all 15,604 acknowledged rows after five restarts. It
reported zero row-loss, shadow-mismatch, verification, and ingest errors. The
workload took 61 seconds; the complete run took 76 seconds. The unchanged
workload bound is 60 to 70 seconds. All 35 Python evidence tests passed.

The causal Engine test proved that raw timestamp bounds omitted emitted bucket
rows. It failed with 4 of 6 rows before the fix and passed after the fix. Its
second batch proves that progress counting includes later output beyond a
captured raw timestamp. The mixed native/scalar derived-history fix is also
integrated. The complete native suite still needs a rerun on this combined tree.

Task 4 schema extraction passed storage checks. Empty generic initialization
is under compiler and regression verification in an isolated worktree. Query
resource limits and selector parsing have separate implementation workers.
The atomic checkpoint split failed twice on engine dependencies. A worker must
prove the full dependency boundary before the next compile attempt.
The current branch is `codex/native-market-storage` at `42fbd55`.

| Milestone | State | Acceptance evidence |
| --- | --- | --- |
| M1: native-storage stabilization | In progress | Native integration, crash smoke, and bounded restart soak pass; combined-suite rerun and release qualification remain open |
| M2: application boundaries | Partial | Schema extraction: 210 storage checks; neutral routes: 4 focused checks |
| M3: query limits | Planned | Query ownership review complete; no implementation evidence |
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
| Standalone HTTP EOF regression on remote main | FAIL before fix; PASS: 2/2 after fix | `http-main-red-memory.log`, `http-main-green.log` |
| CAS mirror checks after refinement | Compile failure: duplicate `loadTreeObjectFromStore`; no tests ran | `cas-mirror-focused.log`; terminal exit 1 |
| CAS mirror checks after duplicate removal | Compile failure: two unmutated `var` declarations; no tests ran | `cas-mirror-focused-v2.log`; terminal exit 1 |
| Isolated native-storage foundation | PASS: 184/184 storage tests; terminal exit 0 | `native-foundation-storage.log` |
| CAS retained-mirror regression and affected engine cases | PASS: 5/5; terminal exit 0 | `cas-worker-focused.log`, `cas-verified-fix-result.md` |
| First full native integration run | 736/736 Zig tests passed; target failed because system Python 3.9 rejected `zip(strict=True)` | `native-market-ci-current.log`; terminal exit 1 |
| Python evidence suite under 3.13.15 | PASS: 35 tests | `native-script-python313.log`; terminal exit 0 |
| Native integration with the Python shell fix | PASS: 34/34 steps, 736 Zig tests, 35 Python tests; shell selected Python 3.13.7 | `native-market-ci-python313.log`; terminal exit 0 |
| 60-second restart soak | FAIL acceptance: schema 3 versus validator 2; max operations 3 versus validator 2; elapsed 74 seconds versus 70-second bound | `native-soak-60s.log`, `native-soak-60s/soak-evidence.json`; terminal exit 1 |
| Crash smoke, one iteration, fsync always | PASS: all seven crash points, exercise exit 86 and recovery exit 0 | `native-crash-smoke.log`; terminal exit 0 |
| Schema 3 soak validator and bundle tests | PASS: 23 tests, repeated by controller under Python 3.13.15 | `soak-contract-result.md`; controller terminal exit 0 |
| Isolated soak timer build | PASS: 4/4 build steps and Zig format check | `soak-timing-build.log`; terminal exit 0 |
| Soak with separate timing fields | FAIL acceptance: workload 61 seconds and total 73 seconds; peak 4 versus expected 3; restart label deltas 21 and 22 | `native-soak-timed-60s.log`, `native-soak-timed-60s/soak-evidence.json`; terminal exit 1 |
| Isolated native derived-row checkpoint | PASS: 3/3 focused tests, including the test root | `native-derived-focused.log`; terminal exit 0 |
| Native derived-row compatibility fix | PASS: 5/5 focused checks after causal failures before the fix | `native-derived-mixed-fix-tests.log`; terminal exit 0 |
| Corrected soak driver | PASS: 4/4 build steps and 13/13 focused tests | `soak-progress-build.log`, `soak-progress-driver-tests.log`; terminal exit 0 |
| Fresh run with stable progress counts | FAIL: `RollupProgressCountsInconsistent` after initial seed work; no workload evidence emitted | `native-soak-progress-60s.log`, `soak-progress-verification-complete.json`; terminal exit 1 |
| First intermediate native checkpoint | Compile failure: `stopWriterWorker` and `stopDerivedWorker` were partitioned after their callers | `native-checkpoint-1-tests.log`; terminal exit 1 |
| Rollup output-range causal regression | FAIL before fix: expected 6, found 4; PASS after fix: 1/1, including later output beyond a captured upper bound | `soak-count-range-tests.log`, `soak-count-range-result.md` |
| Combined driver build and Python evidence suite | PASS: 4/4 build steps and 35 Python tests | `soak-range-integrated-build.log`, `soak-integrated-python.log`; terminal exit 0 |
| Combined 60-second restart soak | PASS: 15,604 acknowledged and recovered rows, five restarts, all four error counters zero; workload 61 seconds, total 76 seconds | `native-soak-range-60s.log`, `native-soak-range-60s/soak-evidence.json`; terminal exit 0 |
| Revised first intermediate checkpoint | Compile failure: `declareExactSeriesCanonicalBatchLocked` is still partitioned after its caller | `native-checkpoint-1-closure-tests.log`; terminal exit 1 |


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

These directories are under the checkpoint artifact directory.

## Published checkpoints

Planning PR: https://github.com/theroutercompany/sydradb/pull/74.
Signed local commit: `5affff8d60c3b4daf584948369111737bcd145bf`.
Published commit: `d2e88931429106ff63d3ba915676f1924fbf8e1b`.
Both commits have tree `c54d4f0771cbee65bccb9f8886b38a64f280f3ae`.
The local signature passed `git verify-commit` with `/opt/homebrew/bin/gpg`.

The normal Git push returned HTTP 403 for the local account. The connected
GitHub app published the same reviewed tree and created the feature-branch PR.
No direct push or update to main occurred. The remote commit has a different
identity from the signed local checkpoint; do not claim they have the same SHA.

The standalone HTTP worktree first exposed an old one-shot transport harness
hang. The controller captured its stacks and stopped only that owned process.
An in-memory HTTP request now isolates the EOF behavior: it reproduced the panic
on remote main before the fix. Both selected checks passed after the fix. The
independent review found no blockers; see `http-pr-review-result.md`.

HTTP fix PR: https://github.com/theroutercompany/sydradb/pull/75.
Signed local commit: `5d91182c76dc29e36f2b600935f6cc3aa38c8232`.
Published commit: `d8c8ddf33b27d287eceb4097161a6b532f082aa4`.
Both commits have tree `82ebc1671550988a2a52667b2430cafc1c1fdced`.
The local signature, changed-file format, and diff whitespace checks passed.
The isolated branch does not have full-suite or keep-alive test evidence.

PR 75 hosted CI job `121999726538` passed `zig build` and `zig test`, but failed
the repository formatting hooks. The EOF hook changed base documentation and
workflow files. Zig format reported unchanged `engine.zig` and `storage/cas.zig`.
The macOS matrix job was cancelled after the Ubuntu failure. See
`http-pr-ci-summary.log`. A separate worker owns the mechanical base cleanup in
`ci-format-pr/`; keep it outside the HTTP patch. Hosted `zig test` uses the base
test graph and does not replace the focused HTTP regression evidence.

Formatting PR: https://github.com/theroutercompany/sydradb/pull/76.
Signed local commit: `80f4dc276a6456958c86206de3cc5f70aca3d79b`.
Published commit: `b15229b1d36030353814ce17cbc4daf7fba55259`.
Both commits have tree `c36b8e61c9c4fb171a1521cd0370dbd6e766c7e1`.
The worker removed exactly one LF from 70 text files and formatted the two Zig
files reported by CI. The controller repeated the format and whitespace checks
and verified the local signature. Hosted Ubuntu checks passed. Hosted macOS
format checks passed, but its Zig build driver failed to link system symbols.
The docs build found two pre-existing links to absent generated ingest pages.
See `format-ci-macos-excerpt.log` and `format-ci-docs-excerpt.log`. Separate
workers own the toolchain diagnosis and the two-link docs correction.

The dependency review is complete: `native-pr-scope-review-result.md`. A draft
foundation worktree at `native-foundation-pr/` contains a clean replay of
`4cd4c8d` on the formatting checkpoint. It excludes the earlier ingest and CI
changes. It passed 184 storage tests and is published as draft PR 77:
https://github.com/theroutercompany/sydradb/pull/77.
Signed local commit: `da6fa3dd63dcd5968067bb6fccab8b062b9a88ad`.
Published commit: `3528ec00b564a916e46ba0fb1938e7799e9054a1`.
Both commits have tree `8dae61579f03625a9c32e6d79145aa7bca3d58ac`.
The PR targets the formatting branch. Runtime and later hardening checks remain
open. Later native fixes and the current dirty implementation remain in the
original working branch.

The CAS build worker removed the duplicate loader and added ownership cleanup
plus allocation-failure coverage. The controller's pinned format check passed.
The redundant validation error log was removed so the caller owns reporting.
A worker now owns the remaining compile fixes and focused CAS verification in
one task; see `cas-verified-fix-agent.jsonl` and `cas-worker-focused.log`.
That task passed all five focused checks with terminal exit 0. The controller
ran `native-market-ci -Doptimize=ReleaseSafe -j2 --summary all`. The first run
failed only the Python 3.9 script step. The exact one-line dev-shell fix selected
Python 3.13.7 and the full rerun passed. Migration evidence includes 64 checkpoint
interruptions. Benchmark, demos, shadow comparison, storage, runtime, and wire
checks passed. The separate crash smoke passed all seven points.

The soak artifact has zero acknowledged-row loss, shadow mismatches, verification
failures, and ingest errors. Its schema and maximum-operation count changed in
the pre-existing driver work but the consumers still require the old contract.
One worker owns strict producer-consumer reconciliation in the Python validators
and fixtures. A read-only worker owns timing analysis; do not relax the elapsed
bound merely to pass. Full soak acceptance remains open.

Docs-link PR: https://github.com/theroutercompany/sydradb/pull/78.
Signed local commit: `cbc2ed05ca3ca90682e52ae2dae8f4cdc6743b0e`.
Published commit: `7c4fcbe2dc7469d45854dadd2c06115ec9825656`.
Both commits have tree `28b83ffeada5038b100679720c6d82b86c91e625`.
The one-line correction points to source files verified on remote main. The PR
targets the formatting branch. Hosted Docusaurus and Ubuntu checks passed. Its
macOS check still has the separate SDK failure.

Python dev-shell PR: https://github.com/theroutercompany/sydradb/pull/79.
Signed local commit: `d34e8a1eb2530834e6a0c3d9a8b7ee889d4f205c`.
Published commit: `fceb8a368a06d79f5a8908b58df37a5fc2970468`.
Both commits have tree `b59043581358df159c3755c7e03e5290cb3628cc`.
The same patch is integrated in the active native checkout and passed the full
native integration target. The isolated PR retains the older base product code.

macOS SDK PR: https://github.com/theroutercompany/sydradb/pull/80.
Signed local commit: `49276e2082f856512e7c448e6b2f679724339756`.
Published commit: `eea97dc696f5b6c50cde960d5c6b52dcbbc37229`.
Both commits have tree `902e4fa079df86fb1b56347a94c2404300604b25`.
The worker selected the installed Xcode 26.3 path for both macOS build jobs and
added SDK identity output. YAML and whitespace checks passed. Hosted Ubuntu and
macOS format, build, and test checks passed. macOS job `122009783147` in run
`40449858255` reports Xcode 26.3 and SDK 26.2. PR 80 is ready for review. Release
packaging jobs did not run on the PR; this is not release-package evidence.

Demo process-ownership PR: https://github.com/theroutercompany/sydradb/pull/81.
Signed local commit: `39bb3c2698edf10e8ca7adea02e1bacff22852cf`.
Published commit: `184165c47e2e814e5fec2e6118a28498e75960cc`.
Both commits have tree `e167d5a072f4c26d6c58d844c0b7a6c54f52653b`.
This is a clean replay of `6e23247` on PR 80. All demo shell syntax checks passed.
The local-socket and quickstart scripts passed with the existing native
integration binary. That binary was not rebuilt from the isolated PR branch.
Hosted Ubuntu and macOS checks passed in run `40452048084`. Release jobs were
skipped on this PR.

Native derived-row draft PR: https://github.com/theroutercompany/sydradb/pull/82.
Signed local commits: `feafcd422d8258096a707fe0ff712aa9d2ae1084` and
`d0ca5ad75a8b1bb10df1860c43e50395c6e9111b`.
Published commits: `b3b4e09291c775f40c1aeba627a8c314a6d45dbb` and
`62e8b2204d3b944399c3ac2e2133cce4a65fd1de`.
Each corresponding tree matches; the final tree is
`0d2ccf4244413c9a06b08bbea29e255e3837fffc`. The PR targets the foundation branch.
All five focused checks passed after the mixed-source fix. Full runtime and
hosted acceptance of this intermediate branch remain open.

An isolated worker prepares Task 5 in `trading-policy-preparation/`. It owns only
the engine validation facade and the new trading policy module. It must preserve
the original validators' error precedence and signal fallback behavior. It cannot
edit the active native-storage checkout or start a competing build. Its copied
engine prerequisite is recorded in `trading-policy-baseline-engine.zig`.

The schema 3 validator worker completed. It now requires concurrent and restart
rollup progress, validates label counts against emissions and highwater progress,
and rejects old or incomplete evidence. The controller repeated all 23 focused
Python tests. The saved soak still fails only its unchanged elapsed bound.

The isolated timing worker owns `soak-timing-preparation/`. It must record the
workload boundary separately from completion through final verification, keep
the existing workload bound and subprocess timeout, and update both producers
and consumers. Its patch must apply to the current schema 3 validator.

The isolated empty-catalog worker owns `empty-catalog-preparation/`. Generic
load and snapshot paths must remain free of trading defaults. Recognized legacy
market routes must initialize trading explicitly after authentication. Existing
schemas, digests, and mappings must remain intact. No root source writes or
competing builds are assigned to this worker.

The next native PR is prepared in `native-derived-pr/`, based on the published
foundation tree. It replays `ff5ccc0` cleanly and changes only `engine.zig`.
The three focused checks passed. Independent review found that native identity
groups can hide older scalar-only groups. The PR is held for a causal regression
and compatibility fix in this worktree. The worker must also inspect overlapping
timestamps in a mixed group. See `native-derived-review-result.md` and
`native-derived-mixed-fix-agent.jsonl`.

The timing patch remains isolated in `soak-timing-preparation/`. Its build passed.
The 60-second rerun completed five restarts with zero reported acknowledged-row
loss, shadow mismatches, verification failures, and ingest errors. Acceptance
still failed: the validator assumes a fixed peak count and equal progress across
labels. Engine telemetry counts nested operations; rollup checkpoints advance
per label. The isolated worker in `soak-progress-preparation/` must derive valid
invariants from those producers, retain per-label progress proof, and correct any
inconsistent observation before another soak run.

Independent evidence review also found that the consumer bounds overlap counts
by only the paired operation count. The producer counts entries from either side
and uses the combined ingest-plus-paired bound. The consumer must use that same
contract and retain positive overlap checks. See `soak-evidence-review-result.md`.

The checkpoint worker produced nine patches in `native-checkpoints/`. Sequential
application and final byte identity passed for all ten captured source files.
This proves reconstruction only; individual intermediate patches have not yet
passed compilation. The first compile exposed two shutdown helpers split after
their callers. A worker moved those existing helpers and required stop-state
dependencies into patch 1. All nine patches still reproduce the captured files.
The revised patch 1 is applied in `native-hardening-checkpoints/`, with format and
whitespace checks passed; compilation is pending. Earlier applied versions are
preserved in `early-metric-checkpoint.patch` and
`native-checkpoint-1-pre-closure.patch`. No hardening checkpoint is committed yet.

The latest engine port of the mixed-source fix is prepared in
`native-mixed-integration.patch`. Its before-copy hash matches the captured root
engine, and `git apply --check` passes in root. Format and whitespace checks pass.
It is not integrated or tested on the latest engine yet.

The empty-catalog patch is prepared in `task6-empty-catalog.patch`. Independent
review found default mapping drift when an empty generic database is reopened,
and a CAS publication failure that can remain unrepaired after restart. A worker
owns those corrections in `empty-catalog-preparation/`. No Task 6 build or runtime
acceptance is claimed.

The soak counting failure occurs after initial seed work. The fixed raw timestamp
origin is 20 seconds into a 60-second bucket. The engine emits the first bar at
`1699999980000000000`, but the count query begins at `1700000000000000000`.
The worker must prove this boundary with an actual-engine regression and inspect
the upper range against the lifetime emission counter. Do not retry a full soak
until that causal check passes. See `soak-count-range-agent.jsonl`.

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
10. The user directed the parent to act only as manager, orchestrator, and team
    lead. From that instruction onward, delegate all source-code and test edits.
    The parent owns review, verification, integration, documentation, and delivery.
    Worker assignments and results are recorded above. Their logs use the same
    task-name prefixes.

## Resume instructions

Read the spec and plan. Check `git status --short`. Inspect the current owned
process handles and logs before repeating any test. Collect the native integration
result and the active worker reports. Verify prepared policy changes before
integration. Continue the native PR dependency sequence without rewriting the
original local history. Do not mark M1 complete from focused tests alone.

## Active isolated work after the bounded soak

- `empty-catalog-preparation/`: explicit trading initialization, stable mapping
  across reopen, and recovery after failed CAS publication. The worker owns the
  serial Zig build slot. No generic initialization changes are integrated yet.
- `query-limits-preparation/`: M3 resource ownership, enforcement, and protocol
  errors. Optional caps preserve existing callers until configured. Not tested.
- `selector-preparation/`: M4 selector parsing and frontend parity. Not tested.
- `native-checkpoints/`: repair atomic boundaries from exact existing code.
  No source behavior changes are authorized in this preparation task.
- `native-migration-pr/`: prepare the next native migration checkpoint on PR 82.
  No compiler or test evidence exists for this isolated branch yet.

All implementation workers use GPT-6 Luna with max reasoning. The controller
reviews and integrates patches, runs checks, and signs and publishes checkpoints.
The controller does not write source or test code. No direct main update or merge
is authorized. Longer soak and platform release qualification remain open.
