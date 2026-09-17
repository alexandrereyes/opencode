# Beta integration — 2026-09-17

## Baselines

- Custom parent: `804155bd7`.
- Integrated upstream: `e5ecb5719de37759e06c57ff05ffc668e98f6f30` (`upstream/beta`, 2.0.6).
- Local integration branch: `merge-beta`.
- Runtime: Bun 1.4.2.

The upstream-owned `packages/app`, `packages/ui`, and `packages/session-ui` trees
match the integrated upstream revision exactly. Custom web API adaptations are
in `packages/app-custom`; its product behavior and independent UI remain intact.

## Integration points

- Adapt custom consumers to project-scoped worktree APIs, session update/form
  APIs, `resume` interruption, inbox delivery updates and `time.created`.
- Bind the custom worktree RPC to its plugin Location's project. Explicit first
  inventory demand runs native discovery before reading the saved inventory.
- Preserve `session.archived` and replay support for historical
  `session.permissions.updated`, alongside upstream `session.permissions`.
- Retain the optional skill `slash` contract and frontmatter parsing consumed
  by the custom composer. Adopt upstream's skill `path` field.
- Use upstream's per-asset lazy decompression while retaining the custom build's
  `app-custom` asset source.
- Probe `/api/info` in custom release tooling, with `/api/health` fallback for
  activation/rollback involving older installed releases.
- Regenerate Protocol OpenAPI and Client from source; adapt fixtures to the
  current API and asynchronous plugin/MCP startup.

Existing shared implementation overlap against the fixed upstream baseline,
including the inherited custom changes: **53 modified upstream files,
585 added lines, 60 removed lines**. This excludes added custom modules, tests,
package manifests and the generated OpenAPI document. Reproduce with:

```sh
git diff --numstat --diff-filter=M e5ecb5719de37759e06c57ff05ffc668e98f6f30 -- \
  packages/core/src packages/cli/src packages/cli/script packages/server/src \
  packages/protocol/src packages/schema/src packages/plugin/src \
  packages/client/src packages/tui/src
```

## Validation and baseline failures

- Frozen dependency installation and root `bun run check` pass.
- Custom web production build passes.
- Custom web unit suite: 1,048 passed, one skipped.
- Core: 5,454 passed, 21 skipped; Server: 65 passed, three skipped;
  CodeMode: 1,269 passed; custom plugin: 41 passed.
- Custom cold-checkout and sidebar worktree HTTP/client integration tests pass.
- Custom plugin source/bundle session-read, app mentions, server RPC integration,
  and release activation/rollback regression tests pass.
- TUI, Schema, upstream App, Desktop, Util, UI-custom and Session-UI-custom
  package suites were exercised successfully.

The initial merge test run had the following failures, reproduced in separate
clean checkouts rather than assumed to be pre-existing. They were subsequently
addressed in the follow-up below.

| Baseline | Package | Failing tests |
| --- | --- | --- |
| Upstream `e5ecb5719` | Client | 4: Effect view timestamp fixture, import-boundary expectation, file API inventory expectation, interrupt wire-contract expectation |
| Upstream `e5ecb5719` | SDK | 2: transport tests expecting the old session-not-found error tag |
| Upstream `e5ecb5719` | CLI | 12: managed-service subprocess tests and debug-paths expectation in this environment |
| Custom `804155bd7` | App-custom browser | 4 top-level suites: sidebar selection, new-session workspace, model selection, sidebar pins |

The browser suites include nested fixture failures (missing Preferences/Server
contexts and a quick-action expectation); the table counts top-level tests.
The two additional browser failures introduced by worktree API changes were
fixed and rerun successfully.

Test logs are retained under the session's temporary directory with the
`merge-beta-` prefix, including `merge-beta-upstream-{client,sdk,cli}.log` and
`merge-beta-custom-base-browser.log` for baseline evidence.

## Follow-up: remaining test failures

- CLI subprocess fixtures now use the isolated environment helper and the
  intended service-config directory. The inherited `OPENCODE_CONFIG_DIR` had
  redirected tests to installed configuration; the debug-paths fixture also
  clears inherited configuration/database overrides.
- Client fixtures use decoded `DateTime.Utc` inputs, the current file/VCS/shell
  API inventory and the `resume` interrupt query. The Effect service entrypoint
  is explicitly checked to remain independent of Protocol.
- SDK transport tests distinguish the HTTP client's `SessionNotFoundError`
  from the embedded service's `Session.NotFoundError`, exercising both paths.
- Browser fixtures provide the current preference, server, worktree, activity
  and RPC contexts. Assertions cover accessible icon controls, expanded search,
  pinned rows sharing Recent without consuming pagination slots, avatar-hidden
  title/time columns and mobile swipe actions. Activity is reset between the
  clock test's LTR/RTL cases.

No production implementation or public API was changed by this follow-up.

Full affected-suite results after the fixes: **Client 168/168, SDK 32/32,
CLI 295/295 and App-custom browser 204/204 passing**. The latter includes the
nested sidebar, workspace and model-selection fixtures. Root lint/typechecking
and `git diff --check` also pass. Follow-up logs use the `fix-remaining-` prefix
in the same temporary directory.
