# Session archive plugin migration

Base: `origin/custom` at `f00fd86ec`.

## Contract and scope

- Existing custom plugin, same registration ID and other features.
- Export `@opencode/plugin-app-custom/archive/rpc`, namespace `Archive`.
- RPC `custom.archive`, method `archive({ sessionID }) -> {}`.
- The plugin owns recursive traversal; App lifecycle actions use the RPC.
- Remove the former HTTP archive endpoint and its generated-client methods.

This migration deliberately retains a minimal native state transition. It is
not a claim that archive persistence can live entirely outside the runtime.

## Native mechanism

Expose `ctx.session.archive({ sessionID })` in Effect and Promise as a
single-session operation. It validates existence, interrupts active execution,
waits for idle, closes the session model transport, reloads current state, and
publishes the existing archive event only when not already archived.

Keep `session.archived`, its projector and public event handling, native
`time.archived`, list filtering and import/export compatibility. Preserve
`time_updated` and retained history/inbox. No migration of existing archives.

Extend the generic `SessionScan.Input` with `parentID?: Session.ID | null`:
omitted selects all; null selects roots; an ID selects direct children.

## Plugin policy

For each node, interrupt and wait before discovering its direct children.
Scan all child pages, including archived children, and recurse serially. Then
call native single-session archive. Already-archived nodes still have their
descendants traversed, allowing retry after partial completion.

Archive events remain child-before-parent. Native transport closure occurs
with the final single-session operation, which rechecks quiescence after child
processing. On success every visited transport is closed. Do not introduce a
second preparation API just to preserve the old internal transport-close order.
Preserve partial-operation failure propagation and retry behavior.

## Verification and delivery

Test native single-session behavior, recursive plugin behavior across pages,
already-archived intermediate nodes, idempotent retry, descendants-first events,
history/timestamps/import-export compatibility, and actual interruption of busy
sessions. Exercise normal plugin HTTP RPC and removal of the legacy endpoint.
Verify lifecycle UI/batches/worktree-linked archiving through RPC.

Follow the App benchmark requirement before session UI changes. Run focused
checks/builds and client generation from `packages/client`. Preexisting upstream
bugs remain outside scope. Review before commit, then squash/push to `custom`.
Automatic activation is disabled: no sync, production prepare, pending/held-
release writes, MyEnv/global config changes or live restarts.

## Implemented verification

- Core single-session archive tests cover idempotent timestamps, unchanged
  `time.updated`, retained metadata/history, unrelated descendants, transport
  closure, unknown IDs, and interruption plus settlement of a real active
  coordinator execution.
- Store tests cover `parentID` root/direct-child filtering independently of
  archived state. Plugin tests cover complete pagination, archived intermediate
  nodes, serial descendants-first order, and failure propagation.
- The server smoke test builds a durable parent/child/grandchild tree through
  the import API, with the child already archived. The real plugin RPC archives
  the grandchild before the parent, leaves an unrelated session active, retains
  message history, and preserves every archive timestamp on retry. It also
  confirms the old HTTP route is absent and RPC failures reach the client.
- App browser and E2E tests cover menus, batches, retries, cache/tab cleanup,
  and worktree-associated archive through `custom.archive`.
- Focused results: Core 10/10, plugin archive/navigation 3/3, server RPC 1/1,
  client event projection 25/25, Schema 8/8, App browser 23/23, and archive
  E2E 5/5. Typechecks passed for Core, Plugin, custom plugin, App, Server,
  Client, Schema, and website; plugin and website builds passed. Client
  generation was repeated without changing its generated diff.

### App benchmark

Both revisions ran the same two passing scenarios from
`home-tab-navigation-benchmark.spec.ts` with one worker and no retries.

| Scenario       | Metric              | `f00fd86ec` |    After |
| -------------- | ------------------- | ----------: | -------: |
| Open session   | all first observed  |    121.2 ms | 127.5 ms |
| Open session   | all stable observed |    130.9 ms | 138.1 ms |
| Close only tab | all first observed  |     37.4 ms |  35.5 ms |
| Close only tab | all stable observed |     48.6 ms |  60.2 ms |

These are single-run measurements, suitable as a regression signal rather
than a performance claim. The separate “stages the review body” fixture failed
on both revisions because `[data-component="session-review"]` never appeared
within 10 seconds; it was excluded from the comparison and not changed here.
