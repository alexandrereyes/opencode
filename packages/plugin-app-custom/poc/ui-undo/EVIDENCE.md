# Corrected evidence and decision

## Targets

- Baseline/oracle: custom `9ebde0dc7f553a85eff59da72f72d6812f962f9e`.
- Candidate backend: upstream V2 `7c5a4d01aa2a8144a81b6261aad220cf5a84c107`
  (2.0.2), detached at `~/Worktrees/opencode2-undo-upstream`.
- The upstream checkout has native per-session revert, inbox, paginated
  session/message and shell APIs, but no custom causal planner/coordinator/job
  invalidation. Its OpenAPI exposed no operation ID containing `causal`, `group`
  or `job`.

The POC plugin is loadable from `poc/ui-undo/plugin-package`, but is not exported
or registered by the production plugin.

## Corrected findings

### Prompt admission hook works for the basic family case

The plugin registers the public `ctx.session.hook("prompt")`. Before returning,
it commits every staged family member except the target; native upstream prompt
admission then commits the target from the session value it loaded before the
hook. Committing the target inside the hook was tested and caused a stale-state
double commit, so the split is intentional.

The real upstream smoke loaded the plugin normally and submitted independent
HTTP prompts to both root and child:

```json
{
  "rootPromptFamilyCommit": true,
  "childPromptFamilyCommit": true
}
```

The earlier `promptFamilyCommit:false` conclusion is withdrawn.

### Non-prompt admission converges, but with different public ordering

Prompt hooks do not run for synthetic, compaction, shell or move inputs. The POC
therefore subscribes to public events and commits a matching family when it sees
`session.inbox.enqueued`. A real upstream synthetic request eventually cleared
both markers, but public ordering was:

```json
["session.inbox.enqueued", "session.revert.committed"]
```

The real oracle test observed the reverse order:

```json
["session.revert.committed", "session.inbox.enqueued"]
```

Thus ordinary prompt behavior is solved; synthetic admission still has an
observable ordering gap. Compaction, shell and move were inspected in source but
not separately executed against the candidate.

### Existing history migration is conditional

The reduced-message indistinguishability claim from the first iteration was
invalid and was removed. With `events.persist:true`, the real custom HTTP log
replayed `session.subagent.input.assigned`, and the candidate migrated the exact
child boundary. With the default server configuration, the real public log
returned only `log.synced`; the normal CLI server does not set `events.persist`.
The candidate now refuses to claim complete migration when no durable history
was replayed.

A one-time versioned migration from the old `session_causal` table into plugin
storage is implemented in `legacy-migrate.ts`. The runtime candidate never reads
SQL. A fixture database verifies schema decoding, idempotence, coverage markers
and planning from the resulting ledger. The ledger retains `assignedSeq` and the
complete origin tuple (`parentSessionID`, `messageID`, `toolCallID`). This is a
deployment migration, not a permanent Core undo dependency. Coverage of missing
source messages and larger historical topologies remains NOT TESTED: the current
planner retains but does not yet consume `assignedSeq`, because public message
pages do not expose their durable sequence.

Future upstream capture remains incomplete: prompt hooks expose child session
and input IDs without parent origin, while tool-after exposes parent
session/message/tool IDs and resulting child session without the exact child
input ID. The experimental plugin records both observations durably, but does
not join them heuristically. Concurrent identical direct and subagent prompts
cannot be correlated exactly without ambient context or a heuristic.

## Real execution evidence

### Upstream plugin smoke

An isolated upstream server on port `42002` loaded the POC through normal plugin
configuration. The runner created two real long-running shells and three real
parent/child trees through public APIs. Provenance was explicitly supplied.

```text
packages/plugin-app-custom$ bun poc/ui-undo/upstream-smoke.ts http://127.0.0.1:42002 <ephemeral-password>
{"ok":true,"rootID":"ses_root9b0d5caebcfb414c9a79bc7ea5ef15c4","childID":"ses_child9b0d5caebcfb414c9a79bc7ea5ef15c4","preservedShellID":"sh_09a561f70001U6PdeQDWdSf7JX","removedShellID":"sh_09a561f73001y806MjqeOxi8cd","phase":"staged","rootPromptFamilyCommit":true,"childPromptFamilyCommit":true,"syntheticFamilyCommit":true,"syntheticOrder":["session.inbox.enqueued","session.revert.committed"],"causalOrGroupOperations":[]}
```

### Oracle tests on `9ebde0dc7`

```text
packages/core$ bun test test/session-revert.test.ts -t 'rewinds reused children'
# 1 pass
packages/core$ bun test test/session-revert.test.ts -t 'rejects a parent stage'
# 1 pass
packages/core$ bun test test/session-revert.test.ts -t 'tracks promoted'
# 1 pass
packages/server$ bun test test/session-revert-cascade.test.ts test/session-revert-shell.test.ts
# 2 pass
packages/server$ bun test test/poc-ui-undo-provenance.test.ts
# 2 pass; persisted-log migration plus default-log behavior; oracle synthetic order asserted
packages/server$ bun test test/poc-ui-undo-overlap.test.ts
# 1 pass; crossed overlapping files both restore to base
```

### Candidate tests

```text
packages/plugin-app-custom$ bun typecheck && bun test test/poc-ui-undo.test.ts
# 15 pass, 0 fail

packages/plugin-app-custom$ ./poc/ui-undo/run-conformance.sh oracle <oracle-worktree>
# server typecheck: exit 0; 3 pass

packages/plugin-app-custom$ ./poc/ui-undo/run-conformance.sh upstream <upstream-worktree>
# server typecheck: exit 0; 3 pass: descendants-first overlap,
# root-first overlap, normal-plugin late background completion
```

The runner refuses to start if any target path already exists, copies its
fixture sources and candidate runtime into dedicated repository-local test
paths, and removes exactly those created paths on exit. It has no personal
absolute path and leaves the detached upstream worktree clean.

Crossed overlap results were:

- descendants-first: `first="child first"`, `second="base"`;
- root-first: `first="base"`, `second="parent second"`;
- oracle grouped restore: both files equal `"base"`.

The file-backed restart test writes the operation in a separate Bun process,
then a new orchestrator reopens and redoes it. Persisted operation and provenance
DTOs are validated with Effect Schema.

## Baseline versus candidate

| Behavior                                              | Baseline `9eb`                                                     | Upstream plus POC plugin                                                                                                      | Result                                                                |
| ----------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Paginated cold descendants                            | Authoritative DB traversal                                         | Public parent-filter pagination                                                                                               | PASS                                                                  |
| Reused/equal-time child cut                           | Exact assignment and `assignedSeq`; suffix from first causal input | Exact IDs with a projected source message; no timestamps                                                                      | PASS for tested projected-source case; missing-source case NOT TESTED |
| Independent input after cut                           | Removed by suffix                                                  | Removed by the same suffix                                                                                                    | PASS; prior blocker withdrawn                                         |
| Independent child revert                              | Rejects selected conflict only                                     | Same; unrelated reverted descendant allowed                                                                                   | PASS                                                                  |
| Move an already-owned staged boundary                 | Supported                                                          | Existing operation membership permits restage                                                                                 | PASS in unit sequence                                                 |
| Pending stage/redo                                    | Preserved until commit                                             | Preserved until commit                                                                                                        | PASS normal path                                                      |
| Root/child prompt after undo                          | Family committed before admission                                  | Prompt hook + native target commit                                                                                            | PASS in real upstream plugin                                          |
| Synthetic after undo                                  | Family commit precedes enqueue                                     | Event observer commits after enqueue                                                                                          | **UNSATISFIED; real ordering counterexample**                         |
| Running shells around cut                             | Exact causal invalidation                                          | Public tool `shellID` mapping                                                                                                 | PASS in real upstream: prior retained, post-cut removed               |
| Delayed background subagent                           | Causal invalidation suppresses notification and keeps undo staged  | Immediate event-driven cancel loses naturally: `enqueued`, `delivered`, then `too-late`; plugin commits undo to erase history | **UNSATISFIED; real upstream counterexample**                         |
| Crossed overlapping files                             | Per-file globally earliest snapshot restores both files            | Descendants-first and root-first each restore a different single file                                                         | **UNSATISFIED for composition of existing revert APIs**               |
| Cross-location history-only                           | Supported                                                          | Candidate sends `files:false`                                                                                                 | PASS at API-sequence level                                            |
| Durable reload/redo                                   | Durable group marker                                               | Validated plugin/file storage                                                                                                 | PASS across a separate process                                        |
| Existing history                                      | Assignment table always available to oracle                        | Public-log migration only if persistence was enabled; one-time legacy data migration otherwise                                | CONDITIONAL                                                           |
| Concurrent stage/prompt and partial transport failure | Serialized family critical section                                 | Not fully exercised                                                                                                           | NOT TESTED                                                            |
| Draft preservation                                    | Client concern                                                     | Not exercised                                                                                                                 | NOT TESTED                                                            |

## Decision

Basic family prompt commit is viable with the existing prompt hook and is no
longer a blocker. Full no-tradeoff parity is still not viable using only the
current permanent public runtime APIs, based on three reproduced differences:

1. non-prompt inbox admission is publicly visible before the plugin can commit;
2. the normal plugin attempts cancellation immediately on `inbox.enqueued`, but
   the observed notification is already delivered; it must commit the staged
   undo to erase it, losing the oracle's still-redoable staged state; and
3. both possible whole-session stage orders fail different files in a crossed
   overlap, while the oracle restores each file from its globally earliest
   affected snapshot.

Proposed backend primitives—not a claim of mathematical minimality—are: a
pre-admission hook shared by all inbox-producing operations, public exact
subagent-input provenance, causal background-job invalidation, and a native
revert request that accepts multiple session boundaries for one per-file
snapshot plan. No public API at the pinned revision exposes snapshot contents or
per-file restore; filesystem endpoints are read-only and VCS diff operates on
the project's repository rather than exposing the native snapshot store. The
pinned revision does not expose the newer session-diff endpoint.

A separate plugin-owned snapshot engine would be a different engineering
project, outside this POC of composing existing APIs; it is not inherently a
workaround and has not been evaluated here. Accessing private shadow-Git paths
or fabricating session histories merely to force file restoration is excluded
by the agreed boundary.
