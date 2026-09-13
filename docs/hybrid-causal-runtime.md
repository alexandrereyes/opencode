# Hybrid causal runtime isolation

## Active objective

Continue the work in `poc-ui-undo` as a production-oriented refactor: retain the
custom plugin policies and isolate the necessary native mechanisms in our own
backend modules. This supersedes the public-API-only implementation restriction
of `poc-ui-undo.md`; that document and its experiments remain historical evidence.

Behavioral baseline: custom `9ebde0dc7`.
Upstream comparison baseline: `0f26ad878`, the upstream base incorporated into
this custom history. Keep the comparison fixed while measuring overlap.

## Existing work to preserve and reuse

Preserve the previous worker's uncommitted files, dependency changes, candidate
code, migration code, fixtures and evidence under `poc/ui-undo` and its tests.
Reuse successful public operations and tests where they fit the hybrid design.
Do not register the incomplete public-API candidate wholesale or create a second
authoritative undo ledger alongside the existing durable family state.

The existing production custom plugin and its nine feature modules remain the
policy/integration layer. Dedicated backend aggregators may use typed native
services and native persistence; browser contracts and plugin policy code must
retain their established dependency boundaries.

## Refactoring boundary

Concentrate undo-specific additions currently mixed into Job, Session inbox,
projectors, recovery and tool completion in dedicated native extension modules.
Retain upstream implementation bodies where possible and replace our added
policy/mechanism blocks with small, explicit integration calls.

Do not copy whole upstream modules to private files and remove their original
bodies: that creates delete-versus-modify conflicts and a second implementation
to maintain. Do not use monkeypatching or intercept private globals. Reuse the
same native service instances, locks, transactions and scopes; do not instantiate
a parallel Session/Job runtime.

Keep serialization, side-effect ordering and transaction ownership unchanged.
Extract only supporting native code that is directly necessary for this causal
isolation. Custom updater/maintenance behavior and unrelated fork changes are
outside this refactor and must remain intact.

## Required guarantees

- Exact causal boundaries and preserved independent work according to the
  current suffix semantics, including pending inputs and reused children.
- Family commit before ordinary and synthetic input admission.
- Suppression of obsolete background results while preserving staged undo/redo.
- Correct per-file restoration for crossed parent/child edits.
- History-only treatment of cross-Location participants.
- Persisted stage/clear/commit and recovery after restart or planner unload.
- Compatibility with existing events, schemas, causal records and migrations.
- No functional regression to the other plugin modules or native operations.

The public-API POC's negative fixtures are useful regressions: the hybrid must
match the custom oracle on those cases, not merely reproduce upstream failures.

## Review and measurement

Record the starting overlap with the fixed upstream baseline, then report:

1. Existing upstream files and hunks still touched by causal runtime changes.
2. Added/deleted lines in those existing files before and after extraction.
3. New extension files, their responsibilities and remaining integration calls.
4. Any retained schema/event/lifecycle seam that cannot be moved safely.

A smaller central file alone is insufficient; verify that restoring upstream
bodies actually reduces overlapping edits rather than moving deletions around.
Preserve assertions in the causal, Job, inbox, recovery and HTTP tests. Add
focused coverage for newly introduced boundaries, run appropriate package
typechecks and compare relevant runtime costs against the behavioral baseline.

Submit implementation and evidence to the parent reviewer, iterate on findings,
and do not commit, push or integrate before review. No production database
access, live restart, sync, pending/held-release writes, MyEnv/global config
changes or automatic activation. Existing upstream defects remain out of scope.

## Extraction inventory

The overlap baseline below was captured from clean custom `9ebde0dc7` against
fixed upstream `0f26ad878`, before the hybrid extraction. Counts are Git
added/deleted lines in existing upstream paths, not total implementation size.

| Existing path | Baseline + / - | Current + / - | Isolated responsibility or retained seam |
| --- | ---: | ---: | --- |
| `core/src/job.ts` | 273 / 11 | 147 / 11 | Registry still owns scopes, synchronized active state, KV persistence and cancellation. It declares those dependencies to `job-causal-adapter.ts`; causal projection/rewrite loops, invalidation, revocation, cancellation and notification guarding live in owned modules. |
| `core/src/session/projector.ts` | 166 / 24 | 28 / 6 | The upstream root stage/clear/commit bodies remain in place. Small calls add provenance registration, child preparation/deletion, derived marker cleanup and root provenance cleanup inside the same projection transaction. The unrelated archive projection is also retained. |
| `core/src/session/inbox.ts` | 39 / 22 | 27 / 21 | Two staged-family gate calls remain. Multi-session locking and locked compaction admission stay here because the coordinator must use the authoritative inbox locks. Maintenance wrapping is preserved and is not counted as extracted causal policy. |
| `core/src/session/execution/restart.ts` | 45 / 21 | 45 / 21 | Recovery must use the live Job/Session services; generation guards and legacy marker upgrade calls remain lifecycle seams. |
| `core/src/session/revert.ts` | 84 / 27 | 16 / 41 | Capture, restore, diff and event publication remain native. The optimized multi-boundary file planner moved as one authority to `revert-files.ts`; retaining the old decoder here would create a second planner and regress the current SQL path. |
| `core/src/session/session.ts` | 83 / 73 | 83 / 73 | Pre-admission family commit, causal assignment publication and coordinator calls remain at native admission boundaries. |
| `core/src/session.ts` | 11 / 0 | 11 / 0 | Public Core facade exposes the native grouped operations. |
| `core/src/session/sql.ts` | 22 / 0 | 0 / 0 | The causal table moved unchanged to a generator-discovered extension SQL module. |
| `core/src/tool/plugin/shell.ts` | 28 / 16 | 28 / 16 | Tool start records exact origin; completion uses the generation guard. |
| `core/src/tool/plugin/subagent.ts` | 13 / 3 | 13 / 3 | Exact child-input provenance is created at the tool call boundary. |
| `core/src/session/subagent-completion.ts` | 13 / 10 | 13 / 10 | Notification admission remains guarded by the native Job authority. |
| `core/src/session/subagent-job.ts` | 8 / 7 | 8 / 7 | Generation-specific observation prevents replacement-job output. |
| `core/src/config/plugin/command.ts` | 11 / 1 | 11 / 1 | Synthetic command subagents create the same exact provenance as tool subagents. |
| generated DB schema/migration | 18 / 0 | 18 / 0 | Existing databases and `9eb` events require the columns/table; generated files are not hand-edited here. |
| `schema/src/session-event.ts` | 25 / 0 | 25 / 0 | Durable provenance and grouped revert lifecycle events. |
| `schema/src/session-revert.ts` | 11 / 0 | 11 / 0 | Persisted parent/children metadata is required to recover grouped state without the planner loaded. |

Across those existing paths—all present in `0f26ad878`—the fixed-baseline
overlap changed from 850 added / 215 deleted lines (1,065 changed) to 484 added /
210 deleted lines (694 changed). New files are excluded from both totals.
The projector now preserves the upstream root bodies rather than hiding their
deletion in an extension module. For the original Job/projector/inbox hotspots,
overlap fell from 535 to 240 changed lines. Including revert/sql, the five
hotspots fell from 668 to 297 lines; zero-context hunk counts changed from
38/10/10/7/1 to 38/8/10/7/0 respectively. The Job reduction is predominantly
within existing lifecycle hunks. Zero-Core is not claimed.
The projector's six deleted lines are the expression-bodied `Cleared` callback
rewrapped as an Effect generator so child markers can be cleared first; its root
`SessionTable` update remains verbatim in that callback. No root stage/commit
operation was moved to the extension.
The 41 deletions reported for `session/revert.ts` include removal of upstream's
private root-only `plan` helper and therefore remain a possible delete-versus-
modify merge conflict. This is deliberate rather than zero-overlap: `9eb`
already replaced that decoder with the optimized SQL planner needed to compare
root and child snapshots globally. Keeping both would create two planning
authorities or route root-only operations back through the older full-message
decode. Capture, restore, diff, clear, commit and event publication remain in
the upstream file.

### Native extension modules

- `core/src/job-causal.ts`: owns causal identity state plus invalidation,
  revocation, generation cancellation and notification-guard orchestration. Its
  typed adapter is backed by the one real Job `SynchronizedRef`, KV store,
  generation cancel function and notification semaphore. Invalid origins are
  marked under the registry lock before the durable scan; revoked origins are
  marked under that same lock before active or durable records are rewritten.
- `core/src/job-causal-adapter.ts`: maps the private active Job shape to causal
  candidates and applies origin rewrites while holding the real Job
  `SynchronizedRef`. It receives the existing KV persistence and
  generation-cancel callbacks. The single notification semaphore is allocated
  per `JobCausal.operations` instance, not in `job.ts` or module-global state.
- `core/src/session/revert-persistence.ts`: owns provenance projection and only
  the family additions around native root projection: child markers, child
  suffix/pending deletion, child instruction reset, root provenance cleanup and
  the staged inbox gate. Root marker writes, root message/inbox deletion and root
  instruction reset remain visibly in `SessionProjector`; all extension calls
  execute in its existing Bus projection transaction.
- `core/src/session/revert-files.ts`: owns the single optimized SQL planner for
  root and same-Location child boundaries, including global timestamp/ID order
  and earliest snapshot selection per file. `SessionRevert` retains the real
  Snapshot service, capture/restore/diff lifecycle and persisted event.
- `core/src/session/causal.sql.ts`: declares the unchanged `session_causal`
  table, keys and indexes. The official Drizzle glob discovers it; migration
  check reports no schema change. The generated full-schema manifest was
  refreshed solely for deterministic declaration order.

Owned files excluded from overlap totals include `schema/src/causal-revert.ts`,
the causal migration, `job-causal.ts`, `revert-plan.ts`,
`revert-coordinator.ts`, `revert-persistence.ts`, `revert-files.ts`,
`causal.sql.ts`, `job-maintenance.ts` and `job-upgrade.ts`.

| Owned file | Lines | Responsibility |
| --- | ---: | --- |
| `core/src/job-causal.ts` | 217 | Causal job state, rejection and operations over the native adapter. |
| `core/src/job-causal-adapter.ts` | 75 | Typed bridge to the real Job registry and persistence callbacks. |
| `core/src/session/revert-persistence.ts` | 195 | Family projection additions and inbox staged gate. |
| `core/src/session/revert-files.ts` | 97 | One optimized multi-boundary snapshot planner. |
| `core/src/session/revert-plan.ts` | 335 | Facts, plugin planning and plan validation. |
| `core/src/session/revert-coordinator.ts` | 209 | Family locks, conflict checks and stage/clear/commit coordination. |
| `core/src/session/causal.sql.ts` | 26 | Unchanged provenance table declaration. |
| `core/src/database/migration/20260910124143_causal-revert.ts` | 28 | Historical schema migration. |
| `schema/src/causal-revert.ts` | 77 | Shared typed facts, plan and origin contract. |
| `core/src/job-maintenance.ts` | 31 | Maintenance inspection of recoverable jobs. |
| `core/src/job-upgrade.ts` | 37 | Legacy background marker upgrade bridge. |

### Retained execution seams

- Admission in `session/session.ts` retains `withFamily` around reconcile,
  family commit, provenance publication and admission. Moving only the calls
  would not reduce overlap: the required seam is the ordering relative to prompt
  preparation and each concrete inbox operation. The policy and lock/retry loop
  are already isolated in `revert-coordinator.ts`.
- Restart keeps the generation fallback beside decoding of legacy background
  markers, and passes it to `Job.guard` before synthetic admission. The actual
  validity/locking rule is now in `job-causal.ts`; restart retains only recovery
  construction and acknowledgement ordering.
- `subagent-completion.ts`, `subagent-job.ts` and the shell tool retain origin
  and generation data at their production/observation boundaries. Moving these
  fields away would require reconstructing identity after the job may have been
  replaced, which is the race the fields prevent.

### POC reuse

The production authority remains the native persisted grouped revert. The POC
is reused as executable counterexample coverage and planner evidence: exact ID
cuts, paginated family discovery, DTO validation/file-backed reload, independent
child conflict behavior and the upstream overlap/late-completion fixtures. Its
`PublicApiUndo` runtime remains unregistered because synthetic pre-admission,
crossed-file restore and late background suppression require the native seams
listed above.

### Review-one verification

- `packages/core`: `bun typecheck`; 217 focused Job, Session ownership/revert,
  execution/restart, shell and subagent tests passed after the snapshot/SQL
  extraction. After the final Job adapter shape, all 23 Job tests and all 68
  Session ownership/restart tests passed again.
- `packages/server`: `bun typecheck`; five HTTP cascade, shell suppression,
  provenance and crossed-file oracle tests passed. The two Job-sensitive HTTP
  cascade/shell tests passed again after the final adapter shape.
- `packages/plugin-app-custom`: `bun typecheck`; 18 planner and POC persistence,
  migration, exact-cut and negative-counterexample tests passed.
- `packages/core`: `bun run script/migration.ts --check` passed after the
  supported SQL-module move; Drizzle reported no schema changes.

The shell HTTP test was strengthened and rerun separately: after a delayed
background completion is released, the obsolete notice is absent and the
grouped revert remains staged until the test explicitly commits it. The server
provenance test continues to assert `session.revert.committed` before
`session.inbox.enqueued` for synthetic admission.

The optimized planner implementation and ordering were moved unchanged. As a
runtime smoke comparison, the crossed-file test measured 454 ms before and
410 ms after in comparable full focused-suite runs; this is not treated as a
microbenchmark guarantee. The existing causal-plan benchmark retained identical
plan hashes before/after; medians were 30.64/31.19 ms before and 34.25/33.03 ms
after for near-end/wide, within the noise expected from separate local runs.

No Session UI code or public Protocol/HttpApi changed, so neither a UI benchmark
nor generated-client refresh applies to this extraction. No live service,
production storage or automatic POC activation was used.

### Final reviewer verification

The reviewer independently recomputed the five-hotspot diff against `0f26ad878`:
`9ebde0dc7` had 584 added and 84 deleted lines (668 total); the hybrid has 218
added and 79 deleted lines (297 total). New owned files are excluded from that
comparison. This measures changed-line overlap, not a measured future Git
conflict rate.

The reviewer also ran the crossed-file oracle, HTTP background-shell undo, and
public provenance tests on the hybrid worktree: four tests and 38 assertions
passed. The implementation is approved for the requested isolation scope, with
the documented remaining admission, recovery, schema and snapshot-helper seams.
All earlier POC artifacts remain preserved. No commit, push or activation was
performed as part of this verification.
