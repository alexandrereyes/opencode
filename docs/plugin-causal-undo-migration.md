# Causal undo policy extension

Base: `origin/custom` at `0a5e0768e`.

## Goal and retained mechanisms

Extract causal participant selection into the existing custom plugin through
a generic planning hook. Preserve native stage/clear/commit endpoints and App
behavior. This is a reduction of policy coupling and overlap in upstream files,
not elimination of native undo machinery.

Native ownership remains necessary for durable provenance, `SessionCausalTable`,
job generations/origins and invalidation, notification guards, snapshots,
grouped revert state/projectors, family coordination, restart recovery, and
auto-commit of a staged family on new input. Keep old events and persisted
plans replayable. No migrations or shadow histories are required by this split.

## Public planning contract

Use a canonical browser-safe Schema contract re-exported through
`@opencode/plugin/session-revert`. It contains:

- Origin: parentSessionID, messageID, toolCallID.
- SessionFact: sessionID, parentID?, Location ref, firstMessageSeq?, firstInboxSeq?.
- AssignmentFact: inputID, parentSessionID, childSessionID, assignedSeq, origin,
  optional current input state (`message` or `inbox`) and sequence.
- ToolFact: sessionID, sequence, origin.
- Facts: root message boundary plus session/assignment/tool facts.
- Participant: sessionID, optional messageID, pendingIDs.
- Plan: participants, origins, pendingOrigins, discardedSessionIDs.

Use sequence constraints compatible with existing stored data; do not introduce
a stricter positive-only requirement if the native sequence domain allows zero.

Add `session.hook("revert.plan", ...)` to both Effect and Promise surfaces.
The event has readonly facts and a replaceable plan. The custom plugin's
planner is pure, deterministic, and uses only the public facts/contract. It
does not access SQL, Core services, Server, locks, or transaction callbacks.

## Native lifecycle

1. Resolve the root Session and activate its Location's plugins.
2. Collect immutable minimal provenance facts.
3. Invoke the planning hook outside Session/inbox locks.
4. Decode and semantically validate the returned plan before side effects.
5. Invalidate jobs and interrupt selected participants through native mechanisms.
6. Acquire family locks and re-read facts without invoking plugins under locks.
7. If facts changed, release locks and replan outside them.
8. Otherwise revalidate and apply the plan with existing persistence/snapshots.

Reject unknown or duplicate participants/inputs/origins, root-as-child, pending
IDs not in inbox, message boundaries not projected, and discarded sessions not
in the participant set. Keep policy selection out of this mechanical validation.
Normalize plan/fact ordering where needed for deterministic comparisons.

Only the root Location's planner participates. Children in another Location
retain history rollback without cross-Location file restoration, as today.

## No-plugin and existing-plan behavior

Without a registered planner, new stage operations use an empty derived plan:
root-only undo. No duplicate causal fallback implementation remains in Core.
Previously persisted grouped reverts must still clear, commit, restore and
auto-commit correctly after plugin unload, using their stored participants.

## Organization

Keep fact collection and plan validation in a native `session/revert-plan`
module. Where practical, extract existing family coordination into a native
`session/revert-coordinator` module so `session/session.ts` delegates instead of
hosting the entire extension. Keep snapshot/persistence ownership in native
revert code. Do not refactor unrelated runtime behavior or duplicate executors.

## Verification and delivery

Preserve assertions from existing causal revert, session ownership, job,
execution/restart, shell/subagent, HTTP cascade/shell, and App revert tests,
loading the custom planner explicitly where causal behavior is expected.
Add pure planner coverage, root-only behavior without plugin, invalid-plan
rejection before mutations, replan-after-fact-change, root-only hook Location,
normal plugin activation, and clear/commit of stored groups after unload.
Test both Effect and Promise hooks and the installed/dist custom plugin.

Report honestly which native code remains and why. No UI rewrite means no App
layout benchmark is required unless session UI files actually change. Public
Protocol changes, if needed, require client generation through the generator.
Preexisting upstream bugs are outside scope. Review before commit; publish a
single squash to `custom` after approval. Automatic activation remains off:
no sync, production preparation, pending/held-release writes, MyEnv/config
changes, or live restarts.

## Implemented result

The causal selection algorithm now lives in
`packages/plugin-app-custom/src/causal-undo/index.ts` and registers on the
existing `custom.app-mentions` plugin. Core retains fact collection, schema and
semantic validation, job invalidation, interruption, family locking,
revalidation, snapshots, durable events and projections, and restart recovery.

`SessionRevertPlan.acquire` activates only the root Session's Location and
captures its hook registry before the first facts read. With no planner, the
loader reads only the root boundary and root Session metadata; it does not read
assistant content or descendants. With a planner, tool facts are projected in
SQLite with `json_each` and `json_extract`, so Core never selects or decodes full
assistant transcripts. Native file rollback planning likewise projects only
snapshot IDs and file paths instead of decoding message content.

The coordination code moved from `session/session.ts` into
`session/revert-coordinator.ts`. This reduces overlap in the central Session
module but intentionally leaves the native mechanism substantial. The pure
custom policy is 73 lines; native `revert-plan` and `revert-coordinator` are
approximately 500 lines together because they own database facts, validation,
locking, retries, jobs, snapshots, and persisted-plan execution.

## Fact collection benchmark

Measured on 2026-09-12 with Bun 1.4.2 on one macOS machine using the same
fixture and measurement loop in both checkouts:

- published baseline: a clean checkout at `0a5e0768e`;
- extracted implementation: this worktree;
- extracted command: `bun packages/core/script/benchmark-revert-plan.ts`;
- baseline adapter: a temporary untracked runner invoking the real
  `SessionRevert.causal` export in the clean baseline checkout;
- seven measured runs after one warmup per scenario.

The in-memory SQLite fixture contains three Sessions (root, affected child, and
an old sibling), 4,000 assistant messages per Session, 8 KiB of text/reasoning
payload per message, and one tool part every 20 messages. Before timing, both
implementations receive identical rows. The runner compares canonical plan
hashes as well as participant/origin counts.

| Scenario                           | Published `SessionRevert.causal` | New load + plugin planner |              Tradeoff |
| ---------------------------------- | -------------------------------: | ------------------------: | --------------------: |
| Near-end cut; old sibling excluded |                          4.68 ms |                  30.53 ms | new path 6.52× slower |
| Wide cut; both children affected   |                         34.15 ms |                  30.66 ms | new path 10.2% faster |

Plans were equivalent in both scenarios. The near-end hash was
`770cb8fb3eac5f400da054ef67ca2aba0716346108700e1c0be2310c28bf480b`
(one participant, 45 origins); the wide hash was
`3476d1557710058445a535e8c59fa0d1eb6b2e3399cffc22aa156d14cad2a00e`
(two participants, 418 origins). There were no pending origins or discarded
Sessions in this fixture.

This exposes the expected tradeoff of the generic facts contract: the new
loader scans minimal tool metadata for the full descendant set, while the
published implementation follows only spans selected by its built-in policy.
The new path avoids materializing full transcript payloads, but a narrow late
cut is substantially slower. The approximately 31 ms absolute result is left
explicit for review rather than changing the frozen contract or moving causal
selection back into Core. These single-machine measurements are diagnostic
evidence, not a performance guarantee.

### Intermediate extraction measurement

Before SQL projection, the first extraction draft selected and decoded all
12,000 assistant rows. On the same fixture, two seven-run measurements placed
that intermediate path at 44.40–55.56 ms with 164.7–166.9 MB observed heap
growth. SQL projection measured 29.78–33.52 ms, returned only 600 metadata rows,
and had no observable heap increase at process sampling resolution. The
root-only no-planner fast path measured 0.010–0.016 ms and returned one row.

SQLite still scans JSON to identify tool parts. The improvement over the
intermediate draft is that full text, reasoning, tool state, and output payloads
do not cross into JavaScript, including during the locked re-read.
