# Worktree management plugin migration

Base: `origin/custom` at `9b0c0641f`.

## Contract

Move the custom inspection/deletion workflow to the existing custom plugin:

- Export `@opencode/plugin-app-custom/worktrees/rpc`, namespace `Worktrees`.
- RPC ID `custom.worktrees`.
- `inspect({ directory }) -> Inspection`.
- `delete(DeleteInput) -> RemoveResult`.
- Preserve the existing custom `Inspection`, `DeleteInput`, `CleanupResult`,
  and `RemoveResult` fields/optionality, including identity, branch, remote,
  dirty state, force, optional branch deletion, and partial cleanup results.
- Declared error `operation_failed`, data `{ message, forceRequired? }`.
- The owning project is resolved from normal RPC Location options, not an
  unchecked project ID supplied in the payload.

## Runtime ownership

Use public worktree inventory/remove/refresh APIs and public platform APIs.
Move the feature-specific Git inspection and branch-cleanup rules into the
plugin, preserving ownership and identity validation, refusal to remove the
repository root, dirty-worktree confirmation, branch-change detection, and
handling of branches used by other worktrees. Non-Git strategies must retain
their supported behavior or fail explicitly as they currently do.

Keep native create/list/remove/refresh and custom worktree strategies intact.
Remove only the fork's inspection/delete feature surface from Core/Schema/
Protocol/Server and generated clients. Inspect the actual upstream diff before
removing shared Git/worktree code. The plugin must not import Core or Server.
If a guarantee requires an additional generic extension, propose the exact
contract to the reviewer before reducing behavior or adding it.

## UI

Use the new RPC in the existing deletion dialog/workflow. Preserve options,
force confirmation, identity handling, partial-success messages, draft/tab
updates, inventory refresh, and the current subsequent archiving of linked
sessions. Archive itself is a later migration. No fallback to old endpoints.

## Validation and delivery

Use disposable Git repositories, worktrees and local bare remotes only. Test
dirty/force behavior, wrong-owner/root rejection, stale identity and changed
branches, successful and partial cleanup, and custom-strategy behavior. Verify
real plugin loading and HTTP RPC, old inspect/delete routes returning 404, and
native worktree APIs still working. Exercise the UI RPC path and failure
feedback with deterministic fixtures. Never delete real user worktrees or
branches for testing.

Generate clients from `packages/client`, run affected package checks/builds and
focused tests. Follow the App benchmark rule if session/timeline files change.
No upstream bug fixes. Submit for review, then squash/push to `custom` when
approved. Automatic activation remains disabled: no sync, production prepare,
pending/held-release writes, MyEnv/global configuration changes or live restarts.

## Migration result

- Added the browser-safe `Worktrees` RPC contract and registered it in the
  existing `custom.app-mentions` plugin.
- Moved Git inspection, identity and ownership checks, branch confirmation,
  dirty-force handling, and optional local/remote cleanup into the plugin.
- The plugin delegates inventory and removal to public `ctx.worktree` APIs and
  runs Git through argument-vector process calls without Core or Server imports.
- Removed the custom inspect/delete contracts and handlers from Core, Schema,
  Protocol, Server, and regenerated clients. Native create/list/remove/refresh
  remain unchanged.
- Migrated the sidebar deletion flow to `custom.worktrees`, retaining linked
  session archival, draft relocation, inventory refresh, force confirmation,
  and partial-cleanup feedback.
- Verified disposable repositories and local bare remotes for successful and
  forced removal, stale identity/branch, root and wrong-owner refusal, default
  branch protection, local/remote cleanup failures, branches used elsewhere,
  and unsupported strategies.
- Verified real plugin loading and HTTP RPC, exact 404 responses for the removed
  GET inspect and DELETE delete routes, native removal, browser fixtures, and a
  Playwright UI flow with mocked RPC. No session/timeline code changed, so the
  App benchmark rule did not apply.
