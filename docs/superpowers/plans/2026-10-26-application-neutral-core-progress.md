# Project ledger: application-neutral core

Plan: `docs/superpowers/plans/2026-10-26-application-neutral-core.md`
Spec: `docs/superpowers/specs/2026-10-26-application-neutral-core-design.md`
Persistent goal: active in this conversation; no deadline or token budget.

## Current checkpoint

The latest combined native and empty-catalog target passed all 34 steps, 743 Zig
tests, and 35 Python tests. A subsequent code review identified two migration
maintenance gaps; causal tests are in preparation. M1 remains open. The earlier bounded
restart soak, before the empty-catalog change, recovered
all 15,604 acknowledged rows after five restarts, with all four error counters zero.
Its workload took 61 seconds and the complete run took 76 seconds. Crash smoke
previously passed all seven points. These are local and smoke results, not full
release qualification.

The mixed-history regression failed because its flush restarted background
processing before the manual assertions. The worker reordered the fixture and
kept every expected count. The focused run changed from 2/3 to 3/3 passing tests,
then the full combined target passed. Production behavior did not change in that
fixture correction.

The first native hardening checkpoint is signed after 210 storage tests passed.
Its isolated two-file port passed all 185 storage tests on the published native
stack and is open as PR 84. Empty generic initialization passed 507 runtime and
211 storage tests before a refinement narrowed publication checks to requested
schemas. That refinement passed 19 focused checks and all 508 isolated runtime
tests, then was integrated. The combined target found two additional trading
fixtures that lacked explicit initialization. Both passed focused checks after
a two-line fixture repair; the combined target then passed. Limits and the
selector/compiler integration have source changes but no passing test result yet.
The neutral routes are open as PR 85 with six passing local checks.
The current branch is `codex/native-market-storage` at `42fbd55`.

| Milestone | State | Acceptance evidence |
| --- | --- | --- |
| M1: native-storage stabilization | In progress | Combined integration, crash smoke, and bounded restart soak pass; two maintenance gaps are under causal investigation |
| M2: application boundaries | Partial | Root schema extraction and aliases passed; revised empty-catalog branch passes 19 focused checks |
| M3: query limits | Prepared; fixes in progress | Independent ownership and accounting reviews found defects; no build or test result yet |
| M4: general selection | Prepared | Parser and compiled-family changes integrated in an isolated tree; verification pending |
| M5: generic rollups and final audit | Design review | Definition, bounded-read, and bucket-semantics contracts under review; no implementation |

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

## Subsequent isolated verification and PR dependencies

The empty-catalog branch passed 18 focused runtime checks, all 507 runtime tests,
and all 211 storage tests. The verification worker corrected the injected CAS
fault lifecycle and a positional comparison between live and CAS series order.
These results do not close the independent concurrent-publication finding. The
initializer still compares unrelated catalog changes after releasing the lock for
publication. Keep Task 6 isolated until that finding has a causal test and fix.
Evidence: `empty-catalog-verified-focused.log`,
`empty-catalog-verified-runtime.log`, and `empty-catalog-verified-storage.log`.

The combined root source completed `native-market-ci` with exit 1: 30 of 34
steps succeeded and 737 of 738 Zig checks passed. The mixed-history regression
expected four processed rows and observed two. The worker owns a focused causal
investigation of fixture scheduling versus product behavior. No assertion is
reduced. See `native-market-ci-combined.log`.

The checkpoint worker proved reciprocal dependencies across the former engine
patches. The new first checkpoint contains only the catalog and reader. The next
checkpoint keeps the existing engine/runtime/CAS dependency closure together.
All seven patches apply in order and reproduce the captured source hashes.
Compiler verification remains pending. The original nine patches are preserved
in `native-checkpoints/old9patches/`.

The native foundation and derived-row branches now include PR 80's SDK fix.
Both hosted Ubuntu and macOS checks passed for these updated heads. The foundation
docs job still reports the previously identified local-ingest links from PR 78.
Release jobs were skipped. The local dependency merges are signed, and the remote
file trees match them. These are branch integrations, not PR merges or main updates.

| PR | Signed local checkpoint | Published commit | Shared tree |
| --- | --- | --- | --- |
| 74, passing-soak ledger | `5dda3fcc3f30891545687fd1a2218abd0be732cb` | `6e7fa6a336d53bb74eb7d5b7462f836e74f9075b` | `371852dc49e465766e22fe2796310b687b46b060` |
| 77, SDK dependency | `cb5d15fea63150f7a498ccbde350a164d4e7dbbc` | `eb16d6fa5702a4bd097bee76b226f5e5ee794c74` | `079eaa35065af94dce6f0c63b0d9a608a764535f` |
| 82, foundation dependency | `7b8584eaf7bc3d1b45606e85f726c795be8c3f7a` | `13e541023d2f3459ef529cd72804c5786b8e3287` | `53512986b190e78c009723992e1f21a069a3b319` |
| 83, initial migration | `869cd459def553378e1c446148e0aaec4771d6b5` | `64b2c8795a8fd4b68e67dae1830ae1303aee7fe7` | `0650d9843ffe978967c8404dfd68b34e3969161f` |
| 75, CI dependencies | `f241aae14e9f2dee3d853842596725e327f7ce2a` | `4cd44aeabacd9c9fcafa360906089eac754ff091` | `043181cd899770337c0228b42f13b393fad10844` |

PR 77 now targets PR 80. PR 82 still targets PR 77. PR 75 now targets PR 80.
PR 83 targets PR 82: https://github.com/theroutercompany/sydradb/pull/83.
It remains a draft. Its initial migration checkpoint has no isolated compiler or
runtime evidence. The worker is porting the existing acknowledged-tail,
crash-consistency, repeat-resume, pre-promotion read/validation, and sequence
correction fixes before readiness. See `native-migration-preparation-result.md`.

A separate `neutral-row-api-pr/` worktree ports the approved aliases onto PR 75.
Its fixtures use that branch's existing scalar-fanout APIs. It does not replace
or weaken the native fixtures in the combined root source.

The selector worker found that the historical bracket notation was not a literal
public syntax contract. The controller asked an optional preference question and
stated the working assumption: `FROM sensor.temperature[label.site = 'west']`,
using existing string escapes and WHERE semantics. The worker now owns parser
and frontend support. A separate compiler worker owns family selection through
existing WHERE predicates. Neither task has test evidence yet.

## Open verification after the combined target

- The mixed-history worker owns the serial build slot. Its isolated engine file
  matched the root engine SHA-256 before investigation:
  `42bc7384274873479b8d6490664afc85310c1ced8a4a0387ffe36e858758eca1`.
- The Task 6 worker will narrow the CAS postcondition to the requested schemas.
  Unrelated series and definitions must not cause initialization failure. This
  replaces the overbroad catalog comparison; verification is pending.
- Source preparation continues for limits, selectors, compiled families, neutral
  API isolation, and migration correctness. No untested patch is integrated.
- A read-only worker is mapping the generic persisted-rollup implementation to
  existing aggregate, retry, checkpoint, and publication code.

The root controller continues to write documentation only. Source and test edits
remain delegated. The persistent goal is active.

## Green combined native baseline

`native-mixed-parent-red.log` records the focused failure with unchanged counts.
`native-mixed-parent-green.log` records 3/3 passing checks after fixture reordering.
`native-market-ci-combined-fixed.log` records terminal exit 0, 34/34 successful
steps, 738/738 Zig tests, and 35 Python tests. The original failed run remains in
`native-market-ci-combined.log`.

The worker found that `flushNow` resumes the derived worker. The corrected fixture
flushes input before it stops that worker and registers definitions. This prevents
background processing from advancing the same highwater before manual processing.
Expected row and emission counts remain unchanged. See `native-mixed-fixture-result.md`.

First native hardening checkpoint: `e515072a4cdc952e3187005947b7075b5b837350`,
tree `854cd24227d50523a643b3ed998e76687b6e5525`. Local signature verification passed.
The isolated checkpoint passed 210/210 storage tests and all three build steps:
`native-checkpoint-1-final-storage.log`. A worker is preparing the same narrow
catalog/reader change for a scoped upstream PR on the published native stack.

The neutral-route worktree now has formatted source and an unchanged copy of the
existing HTTP test-root artifact. That artifact remains untracked. The controller
is running focused alias, auth, validation, and final-record checks in
`neutral-row-api-focused.log`.

## Review findings and isolated verification queue

The first neutral-route test run hung in the old one-shot HTTP helper. A sampled
client waited in `readv` while the server waited in `receiveHead`. The worker
ported the existing helper that handles one request, flushes, and closes. The
second run finished with four of five checks passing. The custom-schema parity
test returned `SyntaxError`; the worker is checking the old test client's response
framing. Neither run is recorded as a passing API checkpoint. Evidence:
`neutral-row-api-hang-sample.txt`, `neutral-row-api-focused-fixed.log`, and
`neutral-row-api-helper-result.md`.

The native catalog/reader port contains the same two-file change as signed
checkpoint `e515072a4cdc952e3187005947b7075b5b837350`. It is isolated on the
published derived-row branch. The first test command named an absent target,
`test-storage`; no tests ran. `build.zig` declares `storage-test`, which the
controller is now running. See `native-metric-catalog-storage-fixed.log`.

The Task 6 worker replaced the whole-catalog CAS comparison with a comparison of
the requested schemas. It added a gated unrelated-definition regression and
retained failed-publication recovery checks for shadow and primary reads. Both
the empty-catalog and selector patches pass formatting and patch dry-run checks.
The revised Task 6 behavior has not yet run through the compiler or tests.

| Review finding | Assigned change | Evidence |
| --- | --- | --- |
| Query allocation failure can leak a sort row or aggregate group allocations | Keep local ownership until list insertion succeeds; test allocation failures | `query-limits-ownership-review-result.md` and inspected operator code |
| Prepared VM initialization can fail after compiled-state ownership transfers | Delay ownership transfer until initialization succeeds; test reset and cleanup | Same review and `PreparedStmt.ensureCompiled` |
| A prior quota refusal can misclassify a later backing-allocator OOM | Report the cause of the current allocation failure | Same review and `QueryExecutionContext.allocationError` |
| Compiled names, label-case filtering, and ambiguity errors differed from existing behavior | Keep named families dynamic, preserve case parity and error contracts | `compiled-family-refined-result.md`; tests are prepared, not run |
| Migration retry and promotion require existing durability followups | Port acknowledged-tail flush, deterministic checkpoints, resume, digest and sequence fixes | `native-migration-hardening-result.md`; compilation and tests remain pending |

The selector/compiler worker now owns their integration. The generic rollup design
review is correcting three open assumptions: no pageable native row visitor exists
in M3; changed output keys require an explicit definition/target contract; exact
integer bucket arithmetic must not silently change existing query semantics.
No rollup implementation has started. The controller remains the reviewer and
orchestrator; implementation workers own source and test edits.

PR 84 is open at https://github.com/theroutercompany/sydradb/pull/84 and targets
the derived-row branch. Its signed local commit is
`a283c1aa3dbe0ca67dd4f804349b3e4b1cde6e9a`; published commit
`06bda7a14f85e43eae6187d93c2f9ea48b986439` has the same tree,
`7e2fc6a3054717c6e64559400a38c235435031cd`. Local signature verification passed.
`native-metric-catalog-storage-fixed.log` records 185/185 tests and 3/3 steps.

The revised empty-catalog focused run passed all 19 checks. Evidence:
`empty-catalog-schema-postcondition-focused.log`. The broader runtime run is in
`empty-catalog-schema-postcondition-runtime.log`; its result is not yet known.

The accounting review found a packed-index allocation bypass, uncounted CAS
name-resolution work, an extended-protocol error-cycle gap, and late output error
mapping gaps. Bounded workers own the packed-reader and protocol fixes. The
metadata/preparation cancellation gap remains open. The reported DELETE flush
changes physical storage before quota rejection but does not delete logical rows;
do not describe it as data loss or promise unchanged physical layout after an error.
The PostgreSQL error-cycle rule was checked against the official
[message-flow contract](https://www.postgresql.org/docs/17/protocol-flow.html).
Evidence: `query-limits-accounting-review-result.md` and inspected call sites.

## Published neutral API and integrated empty catalogs

PR 85 is open at https://github.com/theroutercompany/sydradb/pull/85 and targets
the HTTP final-record branch. The first signed checkpoint is
`47e73e46830f84437bd4825a00a3971397f523dc`; published commit
`3c13e43d041f268e01edb7b8ac948490c471ce6e` shares tree
`9a344e0460bfd60620304465c1b7b2eef0b601aa`. All six focused checks passed in
`neutral-row-api-focused-framing.log`. The test client now handles one response
and decodes chunk framing; production transport is unchanged.

Hosted Ubuntu and macOS checks passed for PR 84 and the first PR 85 checkpoint.
PR 85's docs job found three indented JSON examples that MDX parsed as expressions.
The worker changed only their Markdown fences. Signed fix
`c3467cbb02c52a23b774f7f11959b80bc1455ddd` is published as
`47097a56a6cd981bf17479a6c0fe64d1e4bd48b0`, with shared tree
`3102228a87c63d9d75e9275f98fdae5e93070e0e`. Its hosted checks are pending.
The root API examples already use fenced shell blocks, so this patch does not
apply there and no root docs change was required. The existing local-ingest
source-link failures remain covered by separate PR 78.

The refined empty-catalog branch passed 508/508 runtime checks and four build
steps in `empty-catalog-schema-postcondition-runtime.log`. Its seven-file patch
applied cleanly to root after the prior files and hashes were saved in
`empty-catalog-root-before/`. The first combined run then passed 741/743 Zig
tests; two newer mixed-history fixtures were absent from the isolated baseline.
They failed with `UnknownMarketSchema` and `InvalidBarPolicySource`. Both omitted
the explicit trading initializer. The worker added exactly one initializer call
per fixture, after the engine cleanup defer. The focused run changed from 1/3
to 3/3 passing checks, with assertions unchanged. Evidence:
`empty-catalog-mixed-fixtures-red.log`, `empty-catalog-mixed-fixtures-green.log`,
and `empty-catalog-mixed-fixtures-own.patch`. The combined rerun is recorded in
`native-market-ci-empty-catalog-fixed.log`; do not claim its result before exit.

The initial selector/compiler build found a local `predicate` name shadowing
another binding. The worker renamed that local without changing the expression.
`selector-family-focused.log` retains the compiler error; a fresh run is pending.

The pure trading-policy extraction is rebased onto the empty-catalog source in
an isolated tree. Its precedence fixture explicitly registers the required schema
with fanout storage because its configuration disables CAS. The two-file patch is
prepared and formatted; it has not run through tests. See
`trading-policy-current-result.md`.

`native-market-ci-empty-catalog-fixed.log` now records terminal exit 0: 34/34 build
steps, 743/743 Zig tests (510 runtime, 211 storage, 22 wire), and 35 Python tests.
The target also passed the benchmark smoke, migration smoke, all demo steps, and
shadow parity with 256 generated records, 372 queried records, two restarts, and
two revisions. The root source is verified with empty generic initialization and
explicit application setup. Full release-scale qualification remains open.

The migration hardening patch is now under independent review and isolated storage
verification for PR 83. Its original draft checkpoint remains unchanged until that
verification completes. The later native history and dirty runtime closure are
being mapped into scoped PR dependencies; the 46 original branch commits have not
all been published.

## Migration checkpoints, current findings, and validation extraction

The migration hardening branch passed 192/192 storage checks and 432/432 runtime
checks. The new format-boundary fixture initially selected legacy format 1 because
it created `series_catalog.jsonl` before the repository format probe. The worker
now establishes and asserts a format-4 source and format-3 destination. Rejection
and no-mutation assertions remain. Evidence:
`native-migration-hardening-storage-fixed.log`,
`native-migration-hardening-runtime.log`, and
`native-migration-format-fixture-result.md`.

The three signed atomic checkpoints are published on draft PR 83:

| Scope | Signed local commit | Published commit | Shared tree |
| --- | --- | --- | --- |
| CAS format boundaries and checkpoints | `c310e6a0eb16b41bdd5f6520b4ecc83dc42f5c86` | `92943228356664075af288016537ebe2ee2ec9ac` | `8dbbdd853a2c99de9f8f2ad6d450fab7fa118e09` |
| Migration, promotion, and resume | `bac951fcc2a77b3b8e804f3a10b970bf5342cc51` | `a3e9df3b43c99f4d5ff98a8b64edf457282eab2d` | `c634c36418bdf4afd6895fa976282e9a21f1ec6a` |
| Pre-promotion reader compatibility | `c7f330171804143580ee2116bce7d3a134629e86` | `0d7c498ab219299e23ce4e917a121380e4f8ae2c` | `7525dc95b47d86ae4ee68634640fa89b7abfaf2e` |
| Catalog dependency integration | `46c05a0d8d8525fc73102395b18ebb894eab0fd2` | `ef52924cca4327e5e95466c97803bdda687d229d` | `1e88f159e93dad5ee8d9f887ac3fee3c501848ac` |

All local signatures were verified. The dependency merge passed 193/193 storage
tests in `native-migration-catalog-merge-storage.log`. PR 83 now targets PR 84.
No PR was merged and main was not updated. The worker is completing omitted CAS
diff fields and publication-order reconstruction from the original hardening
commits. These later changes are not yet tested or published.

The current-root review closed the older PR's startup sequence concern: current
recovery scans persisted segment sequences before accepting writes. It found two
remaining gaps in the current code. `flushNow` resumes the derived producer before
promotion finishes, so parity and cutover do not share one maintenance pause.
The scalar writer also quarantines WAL failures without returning them through
the migration barrier. These are code-review findings, not reproduced data-loss
results. The isolated `native-maintenance-fix/` worktree now owns deterministic
race and fault tests before production fixes. See
`current-native-migration-review-result.md` and `native-maintenance-before/`.

The pure trading-policy extraction passed all 516 runtime checks and four build
steps in `trading-policy-runtime.log`. Root applied only the prepared two-file
patch. Its engine and policy files match the verified worktree byte-for-byte:
engine SHA-256 `616d7d68f5979c453f9ea50ea0c8d172fd080107e1306a655002cf7e8820fb0c`;
policy SHA-256 `b9ecf791b0b25b49547a23c2f611203418a8eb82c2d783f1f4e052c4de25ea1c`.
Stateful trading algorithms have not moved. The combined native target has not
been rerun after this pure extraction.

The full selector suite compiled but passed only 472/487 tests. The filtered run
had omitted the new query regressions from Zig's lazy test graph and is not feature
evidence. The worker restored exact binding for unique names, added prepared-name
rebinding at execution boundaries, corrected generated selector construction, and
added validator traversal for bracket filters. Existing single-series expectations
remain. The revised patch awaits full runtime verification. Evidence:
`selector-family-runtime.log`, `selector-family-runtime-diagnostics.log`, and
`selector-family-regression-fix-result.md`.

M3's first builds found binding-qualifier errors, then error-set and fixture-contract
mismatches between the reviewed patches. No query-limit test pass is claimed. One
integration worker now owns that worktree and the serial build slot, with authority
to run runtime and wire checks after resolving those mismatches. Root will not run
another build until that worker releases the slot.

PR 85's current Ubuntu and macOS checks pass. Its MDX error is resolved; the docs
job now reports only the two existing local-ingest links addressed by PR 78.
The latest published plan checkpoint is local
`073c653aedbe84f10b5ba26785c1572a446ea8e0`, remote
`e81b9546dec62440229e44929215d86f46372b12`, shared tree
`989f395338f2e69799785c270240d55c76e61be0`. This ledger has newer local entries.

## Audited checkpoints and remaining native delivery

The P2 artifact audit reconstructed the original patch on `e515072` and compared
all three files. The bytes match the current worktree. The difference in diff
counts is 382 added and removed Engine lines caused by the patch representation;
it is not a source change. Patches 3 through 7 also reproduce all ten captured
hashes. See `native-p2-artifact-audit-result.md`. The unchanged P2 result is now
saved in signed local commit `d66e064f9290f1a54a7bb9b328980a01dbce842e`, tree
`ac8f49e6a17dadc6d85ac29c6e99b3182ebe1c0f`. It is not published. Its older
branch ancestry still requires the scoped upstream ports.

The omitted migration hardening is saved in two signed local checkpoints:

| Scope | Local commit | Tree |
| --- | --- | --- |
| CAS diff reports schema and series changes | `6ecc2b7446a24787a78b37740cf7f8e83f500f5a` | `8e4afd17a1e191b78f491c5d543567b2fba8a51a` |
| Fanout reconstruction preserves correction order | `d928bf0d30062654fb0bbf9b73ccefd0e1b0e65a` | `906f40eabbf5e97f3dcfecf2120ff52d23db55fa` |

Signatures were verified. Tests and publication for these two checkpoints are
pending. The previous published PR 83 head `ef52924` passed Ubuntu and macOS
checks in run `40464341499`; release jobs were skipped. Those results do not
validate the two new local checkpoints.

The compaction and crash-recovery worker is preparing the existing `fb0c346` and
`d3c10b8` changes on an isolated branch based on `d928bf0`. It must preserve the
newer migration and catalog changes and produce separate patches. It has no build
slot. The native-maintenance regressions are under a separate test-cleanup review
before their first RED run.

M3 now compiles and runs 523 runtime tests. The latest full run passed 521 and
failed two: cancellation during series-bound scanning, and a mixed native/scalar
derived-bar fixture. Prepared statements again allow binding after
`UnboundParameter`, and the catalog-budget fixture binds its parameter before
checking the limit. No all-green M3 result is claimed. See
`query-limits-integration-runtime-attempt3.log`.

## Query integration, native failure evidence, and published ports

The reviewed M3 patch applied to the current root without conflicts. Root saved
all 24 affected paths in `query-limits-root-before/` first. Twenty-one files match
the worker's source byte-for-byte; Engine, HTTP, and the API reference preserve
the later empty-catalog, policy, and documentation changes. The integrated runtime
run passed 534/534 tests and four build steps (`query-limits-root-runtime.log`).

The wire run passed 23/26 tests (`query-limits-root-wire.log`). The three failures
concern the new tests' message expectations: two extra NoticeResponse frames and
a RowDescription before an execution error. A worker is checking the actual wire
contract and retaining the SQLSTATE, Sync, discarded INSERT, and recovery checks.
M3 is not fully verified yet.

The first native regression run passed 510 tests but omitted the storage command
module from Zig's lazy test graph. It is not regression evidence. The worker added
the module to `src/runtime_tests.zig`. The corrected run executed 519 tests and
failed exactly the two new regressions: promotion's continuous worker pause and
scalar WAL failure propagation. Evidence:
`native-maintenance-wired-red-runtime.log` (517/519, exit 1). A worker now owns
the production fix and repeat-barrier regression in the isolated maintenance tree.

The original seven-patch series and the later feature work now have separate
signed local checkpoints. `signed-native-checkpoint-history.tsv` records each
commit and tree. The latest feature checkpoints are:

| Change | Signed local commit |
| --- | --- |
| Mixed native and scalar derived history | `20dacc9c40340549044d415a191c4a75654ea477` |
| Empty generic catalog and explicit trading initialization | `b28f67c4c29d7bdd788dcc84138d3f37e11e7514` |
| Pure trading policy validation | `5c4bb84e159c38398f20a1383ab7fed80abd1022` |
| Query budgets and cancellation | `de59db429f1dd665c9fa90f572d4f60208f0fa3f` |

The policy checkpoint's Engine and policy hashes match the verified source. The
query checkpoint's Engine hash is
`3b52c30be7b2e3ed698577c30846f119bf53a58add0d87e5e21a5ad52f72ae39`,
which matches the integrated root. These local branches retain the original
unpublished ancestry and will be ported through scoped PRs; they are not pushed
as a replacement for the existing upstream stack.

Two additional ports are published as drafts:

| PR | Signed local commit | Published commit | Shared tree |
| --- | --- | --- | --- |
| 86, native compaction | `bd2e0a0c8edf104eaef30a38cff4c7cf080c9fe6` | `ab14a950da7635ae3c9b238f35f737fe82186358` | `172761dbac5ad43a3844a5e4ba804e33a1aecf95` |
| 87, crash recovery | `2c4e88b56cce4531f6571a6eff99d7a449cbd120` | `ebbd88da68ac62a488f4018073ef7cb9dc48e352` | `5fb1bfa209d43dc61f26775cdc7c21ce50adea02` |

Their patch IDs match the original `fb0c346` and `d3c10b8` changes. Ubuntu and
macOS CI pass at both heads (runs `40467477939` and `40467528071`). The crash
driver has not been executed at this PR head. PR 83's two later checkpoints are
published as `4c2fda426e2bdd016626ac58a7f8603dee26bccf` and
`feac8a4c9e8bdecd76c5d3245ab34a5422d9763a`; their trees match the signed local
checkpoints. Ubuntu passed at `feac8a4`; macOS failed a compiled/legacy query parity
test with a tag JSON parse error. The failure is preserved in
`migration-macos-query-tags-failure.log`. A separate worker is tracing selector
metadata ownership across CAS index replacement in a tree based on `de59db4`.

Independent selector review found four defects: family first/last ordering,
whitespace in dotted names, the prepared ambiguity error, and inconsistent
generated bracket-filter validation. The worker's corrections and causal tests
are prepared in `selector-family-review-fix.patch`; no revised suite has run yet.

The final native prerequisite audit gives useful missing-interface evidence, but
its claim that P2 is stale is rejected. Comparing patch IDs or added-helper lists
does not prove different final source. Root compared commit `d66e064` with the
original-patch reconstruction again; all three files are byte-identical. See
`p2-commit-byte-recheck.json`. The original P2 artifact remains valid. The audit's
remaining writer, recovery, timing, and snapshot prerequisites still need scoped
ports and verification.

## Wire verification and append-history checkpoint

The wire fixture correction passed all 26 tests in the query preparation tree
(`query-wire-budget-fixtures-tests.log`). The correction preserves the SQLSTATE,
discarded pipelined INSERT, Sync, and recovery assertions. Root applied the exact
tested file delta. Signed local commit
`7249907adb22569c45f4411f622d8e12aa1919f9` records this test correction.
The root wire target has not been rerun after this test-only change.

PR 88 ports append-history correctness and CAS mismatch diagnostics in separate
checkpoints. Its 197 storage tests pass (`native-append-history-storage.log`).
Ubuntu and macOS CI pass in run `40471997243` at published head
`5b7418426288c8fab9ad2bb9812db68251a35195`. The shared final tree is
`20d8e3eda9b4782e49cb0a0d11f54d4bd42d124b`.

| Scope | Signed local commit | Published commit |
| --- | --- | --- |
| Append correctness | `8b0a49b5fbf8a5a4d5492cabb8bbdc26aa9c574c` | `2a9e48240fdeeadc644046e89e888b71d9a2799a` |
| Mismatch diagnostics | `b006f15f965f19830afc1a4f677e9c6be4c9aad2` | `5b7418426288c8fab9ad2bb9812db68251a35195` |

The selector ownership investigation found that the compiler stores metadata
slices from a CAS index that a concurrent refresh can replace. The proposed fix
copies selector strings while holding the index lock. It also keeps shadow
comparisons inside that lock. The prepared-query regression, production fix,
and combined patch are separate artifacts under
`query-selector-ownership-patches/`. Independent review and RED/GREEN execution
remain pending. The macOS failure is consistent with this lifetime defect;
the CI log alone does not prove that cause.

The native maintenance production patch now includes cleanup for a promotion
result if worker restart fails, and a regression for a caller's cleanup retry
after a failed restart. The queue rejects work while the writer is stopped.
The final patch is under independent review and a full runtime run; no GREEN
claim is made yet.

The revised selector-family suite still passes 492 of 493 tests
(`selector-family-bounded-runtime.log`). The prepared rebinding test reports two
diagnostics after the time-bound correction. Further fixture edits are stopped.
A read-only worker is tracing preparation and parsing; the assumption that this
was only a missing time bound is not supported by the latest run. The feature is
not integrated into root.

The next native port owns derived event-ID lifetime, runtime directory ownership,
writer wakeups, flush publication errors, and strict append behavior. It starts
from the PR 88 source tree and will preserve separate reviewable checkpoints.

## Selector lifetime and writer delivery checkpoints

The compiled-selector regression fails on the unfixed integrated source
(`query-selector-ownership-red-runtime.log`, 534/535). Its fix passes 535/535
runtime tests (`query-selector-ownership-green-runtime.log`). Root applied the
five-file patch and verified that each file matches the tested worker source.
Signed local checkpoint `452f4a3d1fe1bc61fd22475aa373e022112b6c6d` records it.
The integrated root also passes all 26 wire tests
(`query-limits-root-wire-final.log`).

The scoped upstream port passes 444/444 runtime tests and is published in PR 89.
Ubuntu and macOS CI pass at its head in run `40475252112`; it is ready for review.
Signed local commit `f9df4b19571b9dea11f2f5a916fc15a8d2c08222` and published
commit `6895cc171b8c30422e7162747473141ed44f5928` share tree
`3e2d9708ef51edcc52bc32daf3c356a414f0b29f`.

The remaining AST query consumers have a separate ownership patch. Its regression
initially had a pointer-type compilation error, then aborted on a null tag in the
unfixed path. An explicit type assertion produced a clean RED result: 535/536
tests passed, with only the new regression failing
(`query-ast-selector-red-asserted-runtime.log`). After correction of four caller
adaptation errors, the worker tree passed 536/536
(`query-ast-selector-green-fixed-runtime.log`). Root integration passed 549/549
with terminal exit 0 (`query-ast-selector-root-runtime-terminal.log`). Signed
checkpoint `936d8de97ba9498a2fe2abaca46128cd757a28a1` has tree
`a16ff1e0fc14b28e7f1338e9e5d95c375ca57432`. The patch covers AST scans and the
HTTP comparison endpoint. The checkpoint is local and is not part of PR 89 yet.

PR 90 contains four atomic native checkpoints and the PR 89 dependency merge:

| Scope | Signed local commit | Published commit |
| --- | --- | --- |
| Derived event and directory ownership | `43e048e0d213cd9f66ab39468f1c064cceadc69d` | `f6cb39300c968d2cc09652e46b4864bd561702f6` |
| Writer wake and flush errors | `0749b31cf10f46fa003afb3e00067f1a84a6cacb` | `d30ea5b169021788a1c9115fa9e026c03f6d2dfc` |
| Strict ordered append | `5999440b1db305a61a5923778da10a08464b1d87` | `8aef7c9370e4f5c85d8c65eca5407626d6525957` |
| Benchmark phase timings | `1fc9d7a565015d0a66006aaf7e1c5d90b99dc836` | `4a6cf54b633a43a1c70d1e515cfe48f63fa6a573` |
| Selector dependency merge | `edeb1e4a2f26e000a80ee7ad0d33de6c4c025f66` | `26d4700209fcd9cd4a1c49263615d3a9db422e25` |

Every checkpoint has matching signed-local and published trees. The final tree
is `b41115c1a2786725f0e5f6222d41e6475596fc32`. It passes 447 runtime and 197
storage tests, the benchmark smoke, and all 10 build steps in ReleaseSafe
(`native-writer-delivery-tests.log`). The prior tree passed 642/643 and failed a
compiled-selector test; the explicit dependency resolved that failure. This is
smoke evidence, not a throughput claim. The new buffered-publication-error
regression and early error return must also be reconciled into the current-root
monotonic barrier implementation before M1 closure.

Hosted PR 90 run `40476994553` failed on Ubuntu; the macOS job was canceled.
All 644 assertions passed, but CAS verification emitted error-level descriptor
count mismatches. A read-only caller trace found two private test helpers that
verify after the live manifest changes but before CAS publication completes.
They must cross the existing drain barrier before explicit verification. The
worker is adding a causal regression and retaining error-level corruption
diagnostics. See `native-writer-ci-diagnosis-result.md` and
`native-writer-delivery-ci-failure.txt`. PR 90 remains draft. This evidence does
not establish data loss or persistent CAS corruption.

The selector preparation tree now passes 493/493 runtime tests
(`selector-family-covered-runtime.log`). Its prepared test asserts the exact
existing parser coverage diagnostics for `AS` and `>=` and retains all execution
and rebinding assertions. The integration worker preserved query budgets and
owned selector metadata, added a compiled family budget regression, and produced
a 26-file patch. That tree passed 550/550 runtime tests
(`selector-family-integrated-runtime.log`). A later test-only addition prepares a
by-ID query before CAS replacement and checks the retained plan after replacement;
it still needs final integration evidence. The integration worker is combining
this patch with the AST ownership fix and shared application fixtures.

The first native maintenance run passed all 523 assertions but exited 1 because
two deliberate persistent-startup-failure tests emitted error logs
(`native-maintenance-final-runtime.log`). A narrow test-hook correction now
observes and asserts those injected errors; production logging is unchanged.
The worker tree passed 523/523 with exit 0
(`native-maintenance-verified-runtime.log`), and root integration passed 548/548
with exit 0 (`native-maintenance-root-runtime.log`). Signed checkpoint
`475a9e933af9323e0a27f17dfcc397b293e41967` has tree
`49930b726dd0b985078240d3adf68d49ee00d252`.

The sensor/service/trading lifecycle test passed 536/536 in its worker tree
(`application-contract-final-runtime.log`). It checks explicit reversed-column
projection, corrections, restart, snapshot restore, and historical revisions
against independently expected values. Its root integration remains pending.

The WAL streaming and torn scalar-manifest recovery prerequisites are ported to
the PR 90 base in two ordered patches. Independent review and storage/runtime
checks are in progress. Trading-transform extraction and the current-root
publication-error reconciliation have separate workers and isolated worktrees.
No PR has been merged, and no branch has been pushed directly to main.
