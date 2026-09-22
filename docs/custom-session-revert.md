# Custom session revert

Undo previously traversed the descendant tree and paged every descendant's user
history from the browser before staging the root. A measured family of 152
completed descendants required 460 sequential GETs even though none had a user
message at or after the selected cutoff. This established a latency cost, not a
historical backend deadlock or deletion of those descendants.

## Read boundary and execution ownership

`custom.session-family.revert` now returns only `{ sessionID, messageID }` pairs
for eligible descendants. Its policy belongs to `plugin-app-custom`: select the
first **user** message whose creation time is at or after the cutoff.
`custom.session-family.clear` selects descendants with staged reverts for full
Redo. Neither RPC executes a revert, interrupts execution, deletes sessions, or
changes files.

Existing plugin reads could only list individual histories or bounded family
pages. The small reusable `session.familyBoundaries` extension therefore exposes
the Core `SessionFamily.boundaries` read through Effect and Promise plugin
contexts. It accepts a message type and creation-time cutoff, or selects existing
staged boundaries when that filter is omitted. Core reads the indexed recursive
parent relation and a correlated first-message query in SQLite, without decoding
transcripts or returning full session objects. The host validates that the root
exists. Shared contracts remain browser-safe in Schema.

Ordering matches the previous native reads: breadth-first descendants, siblings
ordered by `time_updated` and then ID ascending, and the first eligible message in
aggregate sequence order (not message ID or creation-time sort order). Archived
descendants remain included; the root and repeated cycle members are excluded.
The aggregate plan is a read snapshot, not a transaction covering later execution.

The browser still executes descendants sequentially with native
`interrupt → wait → stage(files: false)` when its existing activity state says a
child is busy, then performs the root's native `interrupt → wait → stage`. Partial
child failures still display request-failure toasts and allow remaining children
and the root to continue. A failed aggregate read retains the previous root-list
failure behavior: report the failure and attempt the root. Full Redo clears
selected descendants before the root. Root inbox cancellation, prompt restoration,
message selection, stage/commit distinction, and submit barriers are unchanged.

## Pending interaction

The composer dock displays an accessible status with the existing spinner and
semantic text token: checking descendants, completed/total descendant operations,
updating the root, and finishing inbox work. Errors clear pending state; native
request failures remain visible as toasts. The UI introduces no timeout or cancel
operation that could abandon partially applied changes.

The message button retains its pending guard. The composer barrier additionally
joins the latest pending operation when a button or command resolves to the same
boundary, before restoring the draft again. Different boundaries and Redo remain
serialized; they are not discarded or run concurrently. New prompt submission
continues to await the barrier. Consecutive Undo commands can intentionally choose
different earlier boundaries.

## Integration and upstream overlap

Feature base: `29cb2f7a2eb5deeee12b77ca81a241fa8b2b24b3` (`origin/custom`).
Fixed integrated upstream baseline:
`e5ecb5719de37759e06c57ff05ffc668e98f6f30`, verified against the unchanged upstream
App, UI, and Session UI trees.

The remaining upstream-owned runtime integration for this feature is four files,
**17 added lines, zero removed**: Core plugin host, Effect plugin session contract,
Promise plugin session contract, and Promise adapter. The query lives in the
existing dedicated custom aggregation module, `core/src/session/family.ts`; its
contract lives in the existing `schema/src/session-family.ts`. Neither file exists
in the fixed upstream baseline. No upstream implementation body was copied or
moved. No Protocol or production HttpApi contract changed, so client generation is
not required.

Including inherited customizations, the standard modified-upstream-files metric
moves from **54 files / 635 additions / 60 removals** at the feature base to
**54 files / 652 additions / 60 removals**. Reproduce with:

```sh
git diff --numstat --diff-filter=M e5ecb5719de37759e06c57ff05ffc668e98f6f30 -- \
  packages/core/src packages/cli/src packages/cli/script packages/server/src \
  packages/protocol/src packages/schema/src packages/plugin/src \
  packages/client/src packages/tui/src
```

## Validation

- Core SQLite test: 154 descendants, empty selection, exact cutoff, sequence versus
  ID ordering, archived grandchild, generic message-type filtering, cycle handling,
  and parity against the actual native session/message read services.
- Server/plugin RPC test: one request for the 154-member empty plan, eligible
  child/grandchild, missing-root error, native descendant stage and clear selection.
- App tests: aggregate request count, busy descendants, partial failures, pending
  progress, failed/cancelled reads and retry, duplicate-target joining, queued
  Undo/Redo, and existing submit-barrier coverage.
- Browser regression: pending status, disabled repeat click, single plan/stage,
  draft restoration and hidden child-session revert controls. The mock wait and
  clear routes are aligned with the current native endpoints.
- Isolated live browser fixture: 154 descendants, one plan RPC (10 ms observed)
  instead of per-descendant GETs, followed by native root interrupt/wait/stage and
  inbox read. The response was deliberately held for pending-state screenshots;
  screenshot time is not included as a performance claim.

The fixture uses fresh test-only data and no model credentials. It validates Undo,
not provider/MCP equivalence with production. Production sessions and processes
are not used for mutation tests.

The canonical root `bun run check` passes. The optional broader
`app-custom` `typecheck:e2e` still reports the same 13 errors as the clean feature
base (markdown lifetime globals, terminal/timeline performance types, readonly
quote/mention test fields, and the older subagent event fixture). The complete
base and feature diagnostic outputs match; these unrelated E2E typing errors are
not changed here. The targeted browser regressions pass in installed Chrome.
