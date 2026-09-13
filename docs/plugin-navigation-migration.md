# Navigation plugin migration

Base: `origin/custom` at `de6323096`.

## Feature contract

Export `@opencode/plugin-app-custom/navigation/rpc`, namespace `Navigation`,
RPC ID `custom.navigation`, method `list`.

Input preserves `{ after?: Session.ID, limit?: number, sessionID?: Session.ID }`.
Output preserves `{ data: Info[], next?: Session.ID }`, where `Info` contains
`session`, `messageAt?`, `unreadAt?`, `permissionAt?`, and `questionAt?`.
Session values in the portable browser contract must be encoded JSON, including
millisecond timestamps, rather than runtime DateTime values.

## Generic plugin capabilities

Add equivalent Effect/Promise surfaces:

1. `ctx.session.scan({ after?, limit?, sessionID?, archived? })` returns a stable
   ID-ascending page of `{ session, messageAt?, completionAt? }` plus `next`.
   Default limit 200, maximum 1000. Omitted `archived` includes all sessions;
   false selects unarchived and true selects archived sessions.
   `messageAt` is the maximum creation timestamp of user/assistant messages.
   `completionAt` is the latest durable succeeded/failed execution event time.
   It does not incorporate viewed/root/unread rules or projected fallbacks.
   Use bounded metadata SQL without decoding transcripts or replaying logs.
2. `ctx.request.pending()` returns live Location snapshots with Location ref,
   raw permission requests, and raw form records. Inspect only already-live
   Location contexts, never initialize historical Locations. This is a live
   observation, not a cross-Location atomic transaction.

Keep public contracts browser-safe and Core mechanisms independent of the
custom plugin. Existing client-domain methods remain inherited as required by
the Plugin package guide; these capabilities are additions specific to plugins.

## Policy in the plugin

The plugin requests unarchived sessions and classifies attention:

- `unreadAt` only for roots when projected `time.idle > (time.viewed ?? 0)`.
- In that case, use durable `completionAt` if it exceeds the viewed watermark.
- Otherwise fall back to projected idle only for outcome succeeded/failed.
- Preserve this precedence exactly: do not replace it with the maximum of
  durable completion and projected idle.
- Only forms of kind `question` or `websearch.provider` count as questions.
- Reduce outstanding permission/question timestamps per session.

The UI keeps its existing descendant aggregation, live-event invalidation,
ordering and display. Replace the navigation HTTP call/types with this RPC,
including cancellation and stale-response guards. No persisted derived cache.

## Removal and verification

Remove Core/session/navigation, Schema/session-navigation, the old endpoint
and handler, and generated client methods/types. Regenerate the client.
Test stable pagination under renames, message-only clocks, interrupted-after-
completion, projected fallback precedence, viewed/root behavior, archived
filtering, pending request classification and clearing, no historical Location
activation, and numeric wire dates. Verify the real plugin RPC, absence from
OpenAPI, and that the old route no longer returns a successful navigation page.
Currently `/api/session/:sessionID` matches the old path and returns its normal
invalid-ID status 400; do not retain a feature-specific tombstone to force 404.
Exercise sidebar/dashboard browser tests and compare isolated metadata-query
performance before/after with meaningful fixtures; record any upstream fixture
blocker without fixing it.

Keep all other custom plugin features and its registration ID unchanged. Review
before committing, then squash/push to `custom`. No automatic activation, sync,
production preparation, pending/held-release writes, MyEnv changes or restarts.
