# Upstream integrations

Each upstream revision integrated into `custom`, newest first: its baselines,
integration points, and validation. Upstream overrides and their reconciliation
live in `docs/upstream-overrides.md`.

## V2 integration — 2026-10-11

### Baselines

- Custom parent: `4c34a869d`.
- Integrated upstream: `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (`upstream/v2`,
  source of the published 2.0.26 `latest` release; 443 commits after `dd786c62a`).
  The 44 later `upstream/v2` commits, including the Effect 4.0.1 upgrade and #53641,
  are not integrated.
- Merged directly on `custom`.
- Runtime: Bun 1.4.2.

The upstream-owned `packages/app`, `packages/ui`, `packages/session-ui`, and
`packages/tui` trees match the integrated upstream revision exactly. Upstream UI
work in this range, including the move of GUI features into
`packages/gui-extensions` (#52369), is not ported; `docs/upstream-overrides.md`
marks the affected custom ports as `reconcile`.

The local clone fetches `upstream` with `blob:none`. The first merge attempt
aborted on a blob the lazy fetch could not obtain and left the tree partly
updated; fetching the 1,622 missing blobs of the target tree in one batch
(`git fetch upstream --filter=blob:none --stdin`) before merging avoids it.

### Integration points

- `@pierre/diffs` 1.5.1 (#51236) is a shared catalog bump, so its session-ui
  change is ported into `packages/session-ui-custom` (two-argument diff option
  types, `word-line` diffs, separator and annotation CSS, SSR fallback); see the
  #51236 entry in `docs/upstream-overrides.md`.
- `packages/core/src/filesystem.ts` takes upstream's streaming `read` (`File`) and
  keeps the anticipated #53641 `list` failure; `packages/util/src/path.ts` adopts
  the `upstream/v2` layout of #53641. Both files now equal `upstream/v2`.
- Skill frontmatter keeps the custom `slash` field alongside upstream's
  `disable-model-invocation` (#52747) and broader boolean parsing.
- Plugin docs keep `session.scan`/`archive` next to upstream's `update` (formerly
  `rename`), `move`, `compact`, `remove`, and `context`.
- The CLI web UI archive takes upstream's binary format (#53643–#53645) and keeps
  the `--custom` build of `packages/app-custom`. The web shell CSP keeps the custom
  blob frame/media/font sources and adds upstream's `worker-src 'self' blob:`.
- Storybook stays on the custom packages and does not load `gui-extensions` stories
  or the `ExtensionStory` wrapper. CI runs upstream's new component-test steps
  against `packages/session-ui-custom` and `packages/app-custom`.
- Root `lint` adopts upstream's ast-grep GUI-extension rules and SDK doc check;
  `bench:devex` stays on `packages/app-custom`.
- Core test fixtures: the plugin layer adds `Config.node` with a shared
  `configLayer` beside the custom `SessionFamily` and offline variant; the new
  policy fixture supplies the custom `mcp.callTool`; the session-read test handles
  upstream's blocked plugin load result; an unused import is removed for upstream's
  `noUnusedLocals`.
- Upstream desktop browser tests that #52369 removed are dropped with their custom
  stabilizations.
- Regenerating the Client from source restores the custom types (`slash`,
  `session.archived`, `session.permissions.updated`, `created`). The Protocol
  OpenAPI documents keep the merged text: regenerating also emits upstream drift
  (for example #52668's `LocationNotFoundError`) that upstream's committed document
  lacks.
- New database migration `20261007190000_azure_cli_external_credential` turns
  Azure CLI OAuth credentials into external references.

Shared implementation overlap against the fixed upstream baseline, measured with
the command below using `5e73d5cb1`: **59 modified upstream files, 723 added lines,
71 removed lines**.

### Validation

- `bun.lock` is regenerated with `bun install` from upstream's lockfile; frozen
  installation, root `bun run check`, and the custom web production build pass.
- Core 6,598 passed, 23 skipped; Server 79 (five skipped); CLI 364 (nine skipped);
  custom plugin 59; Client 224; SDK 36; CodeMode 1,373; Plugin 9; App-custom unit
  1,320 (one skipped) and browser 226; Session-UI-custom 251; UI-custom 114.
- Failures not caused by the merge:
  - Core GitLab OAuth (11): local port 8080 is held by OrbStack.
  - Core `Git trees` check-ignore and `Worktree` dirty-removal, custom plugin
    worktree cleanup (2) and the server's custom worktree route: Git prints
    localized (pt-BR) messages on this Mac. They pass with `LC_ALL=C`.
  - Server OpenAI OAuth port fallback (2–3) and the custom worktree route: the
    installed, signed-in Azure CLI makes upstream's Azure discovery (#50053,
    #53794) call `management.azure.com`, which the test guard blocks. With an
    empty `AZURE_CONFIG_DIR` and `LC_ALL=C` the Server suite passes completely.
  - Core `LocationActivity eviction` (4): `82615eb0f` (`fix(core): keep locations
    alive while awaiting user input`) intentionally keeps Locations with pending
    questions alive, which these upstream tests reject. `location-activity.ts` is
    unchanged by upstream in this range, and the tests pass with upstream's file.
  - Client `exposes every standard HTTP API group`: upstream's own test omits
    #53672's `integration.connect.external`; it also fails at `5e73d5cb1` and is
    not fixed on `upstream/v2`.
  - App-custom browser: the five known sidebar suites recorded on `4c34a869d`.

## V2 integration — 2026-09-28

### Baselines

- Custom parent: `d0eae5000`.
- Integrated upstream: `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (`upstream/v2`,
  after the 2.0.18 release sync).
- Merged directly on `custom`.
- Runtime: Bun 1.4.2.

The upstream-owned `packages/app`, `packages/ui`, and `packages/session-ui` trees
match the integrated upstream revision exactly. The upstream UI work in this range
is not ported yet; `docs/upstream-overrides.md` marks the affected custom ports as
`reconcile`.

### Integration points

- `packages/core/src/tool/read-filesystem.ts`: take upstream's line-counting
  `makeTextPage` call (#51011) and keep the custom `Effect.die(new Error(...))`.
- `bun.lock`: regenerated with `bun install` from upstream's lockfile.
- Upstream removed the unused `SessionRunnerRetry.transient` (#51667); compaction
  now runs its own retry loop through `SessionRunnerRetry.policy`, which still
  carries the custom frozen HTTP metadata into the `session.retry` hook. The custom
  test for `transient` is removed; the policy metadata tests remain.
- The custom app-mentions MCP fixture adds upstream's new `Mcp.Interface.resources`
  (#50680).
- `opencode pair` now prints single-use `/auth/connect/<code>` links (#50970). The
  server still accepts the password, but the custom web QR scanner does not decode
  these links until the pairing UI is ported.
- Regenerating the Client from source produces no changes.

Shared implementation overlap against the fixed upstream baseline, measured with
the command below using `dd786c62a`: **55 modified upstream files, 682 added lines,
65 removed lines**.

### Validation

- Frozen dependency installation and root `bun run check` pass.
- Core 5,560 passed, 21 skipped; Server 69 (three skipped); CLI 328 (nine
  skipped); custom plugin 57.
- Core's 12 failures are environment-only: the known `preload.test.ts` home
  isolation check, and 11 new upstream GitLab OAuth tests (#50422) that need
  local port 8080, which OrbStack occupies on this machine.

## V2 integration — 2026-09-23

### Baselines

- Custom parent: `bea19bc71`.
- Integrated upstream: `8ce629be225b551416d3009e87f02031824c5747` (`upstream/v2`,
  source of the published 2.0.15 release; tag `v2.0.15` only adds the version bump).
  `upstream/beta` stopped at `e5ecb5719` (2.0.6), already integrated below; the
  official `latest` channel is now built from `refs/heads/v2`.
- Local integration branch: `merge-upstream`.
- Runtime: Bun 1.4.2.

The upstream-owned `packages/app`, `packages/ui`, and `packages/session-ui` trees
match the integrated upstream revision exactly.

### Integration points

- Keep custom `session.archived` and replay-only `session.permissions.updated`
  alongside upstream's new `session.metadata.updated` event (schema, projector,
  message updater, event manifest test).
- Promise plugin adapter: adopt upstream's `runtime` context name for the custom
  `mcp.callTool` unload signal.
- Plugin test fixture: keep the custom shared node list and offline layer, adding
  upstream's `ManagedPolicy.node`.
- `packages/schema/src/integration.ts` returns to upstream: upstream's hygiene test
  now permits `Schema.Any` there, making the custom `Schema.Unknown` substitution
  redundant. The custom opaque-metadata test still passes.
- `packages/codemode/test/openapi.test.ts` takes upstream's isolated fixture spec,
  replacing the custom assertion against the live server spec.
- App-custom fixtures add upstream's required `Project.Time.active`; the image test
  follows upstream's declared-errors-as-`Error` client change (#50788).
- Regenerate the Client from source.

Shared implementation overlap against the fixed upstream baseline, measured with
the command below using `8ce629be2`: **53 modified upstream files, 656 added lines,
57 removed lines**.

### Validation

- Frozen dependency installation, root `bun run check` and custom web production
  build pass.
- Core 5,508 passed, 21 skipped; Schema 68; Client 175; CodeMode 1,318;
  Server 67 (three skipped); SDK 32; CLI 323 (nine skipped); TUI 1,362 (two
  skipped); custom plugin 44; App-custom unit 1,116 (one skipped) and browser 219;
  UI-custom 109; Session-UI-custom 208.
- Plugin 9 passed with a symlink-free `TMPDIR`; with the default macOS `TMPDIR`,
  one `host.test.ts` expectation differs only by the `/var` → `/private/var`
  symlink.

## Beta integration — 2026-09-17

### Baselines

- Custom parent: `804155bd7`.
- Integrated upstream: `e5ecb5719de37759e06c57ff05ffc668e98f6f30` (`upstream/beta`, 2.0.6).
- Local integration branch: `merge-beta`.
- Runtime: Bun 1.4.2.

The upstream-owned `packages/app`, `packages/ui`, and `packages/session-ui` trees
match the integrated upstream revision exactly. Custom web API adaptations are
in `packages/app-custom`; its product behavior and independent UI remain intact.

### Integration points

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

### Validation and baseline failures

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

### Follow-up: remaining test failures

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
