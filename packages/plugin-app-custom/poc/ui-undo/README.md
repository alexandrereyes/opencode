# Public API family undo POC

This directory is deliberately outside `src` and is not registered by the
production plugin. `PublicApiUndo` accepts only the public generated-client
shape plus plugin-compatible JSON storage.

The executable candidate:

- discovers descendants and messages through paginated public APIs;
- imports exact assignments from the custom backend's public session log before
  migration, and stores them independently;
- uses exact IDs rather than timestamps for reused-child suffix cuts;
- interrupts affected sessions and removes only running shells whose public
  assistant tool metadata identifies an origin at or after the cut;
- leaves pending inputs untouched while staged, cancelling selected pending IDs
  only on commit;
- stages message-bearing sessions through native per-session revert, with
  cross-location children set to history-only;
- persists operation DTOs validated by Effect Schema;
- supports redo after a separate process reopens file-backed POC storage;
- includes an idempotent one-time importer for the legacy causal table;
- registers an isolated real plugin adapter whose prompt hook commits all other
  family members before native prompt admission commits the target member;
- observes non-prompt inbox admissions and converges the family afterward.

The candidate intentionally remains unregistered in production. See
`EVIDENCE.md` for the corrected baseline comparison. Root and child prompts are
handled by the pre-admission hook. Remaining reproduced differences are crossed
overlapping snapshots, late background-subagent delivery forcing commit of the
undo, and the observable ordering of non-prompt inbox admission versus family
commit.

Pinned upstream backend: `7c5a4d01aa2a8144a81b6261aad220cf5a84c107`
(OpenCode 2.0.2), checked out at `~/Worktrees/opencode2-undo-upstream`.

Run revision-specific fixtures without modifying backend source permanently:

```sh
./poc/ui-undo/run-conformance.sh oracle /path/to/custom-9eb-worktree
./poc/ui-undo/run-conformance.sh upstream /path/to/upstream-7c-worktree
```
