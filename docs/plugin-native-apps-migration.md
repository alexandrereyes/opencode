# Native apps plugin migration

Base: `origin/custom` at `0c24f0817`. This is the next sequential migration in
the single `@opencode/plugin-app-custom` package.

## Contract

- Browser-safe export: `@opencode/plugin-app-custom/native-apps/rpc`.
- Namespace `NativeApps`, RPC `NativeApps.Definition`, ID `custom.native-apps`.
- `list({})` returns `Availability`: `{ os: "macos" | null, apps: ID[] }`.
- `open({ app, path, reveal? })` returns `{}` on success.
- Preserve the current allowlisted app IDs and absolute-path validation.
- Declare `open_failed` RPC error data with reason
  `unsupported | unavailable | invalid-path | launch-failed`; retain the UI's
  existing translated failure presentation.
- Both calls use normal RPC Location options, separate from payload.

## Ownership and behavior

Move host integration and its contracts to `src/native-apps` in the existing
plugin. Preserve macOS bundle discovery, Finder reveal, and literal argv-based
launching. Use public platform APIs; no Core/Server imports in plugin production
code. Keep existing app-mentions and subscriptions registrations and IDs.

The web UI retains local-server gating, VS Code/Rider choices, persisted
preference, duplicate-click protection, and graceful plugin-unavailable state.
The Electron path continues using its platform bridge. Availability must be
refreshed for the current Location/server without stale-context results.

Remove the native-app Core service, Schema contract and barrel exports,
Protocol endpoints, Server handler and service wiring, and generated-client
surface. Regenerate clients through `packages/client`; do not edit generated
files manually. Preserve unrelated custom features and upstream behavior.

## Validation and delivery

Record App's required isolated production benchmark before session-file edits.
Migrate meaningful schema/runtime tests, cover missing apps, unsupported host,
invalid paths and exact argv for paths containing spaces/metacharacters. Verify
the normal plugin RPC path, removed routes returning 404, UI availability/error
states, and compatibility of previously migrated features. Do not launch the
user's real applications during tests; use an isolated process/platform fixture.
Run affected typechecks, focused tests and production plugin/UI builds.

The implementation worker submits for parent review before Git finalization.
After approval, publish a single descriptive squash in `custom`. Automatic
activation is disabled by user request: no sync, pending-release writes, MyEnv
changes, live-server restarts or activation. Preexisting upstream bugs remain
outside scope.

## Implementation result

- Added the frozen `@opencode/plugin-app-custom/native-apps/rpc` contract and
  host implementation to the existing custom plugin. Opening remains
  interruptible: cancellation before launch prevents spawning, and an active
  launcher receives the Effect cancellation signal.
- Moved the web UI to Location-scoped plugin RPC while retaining the desktop
  bridge, local-server gate, preferences, duplicate-click guard and translated
  errors. Availability now keys requests by server and Location and ignores
  stale results.
- Removed the Core and Schema native-app modules, Protocol and Server routes,
  service wiring, tests, exports, and generated client methods. Both former HTTP
  routes are covered as `404` through the real server fixture.
- The isolated production tab benchmark was run before and after the UI edit.
  Both runs stopped at the same preexisting fixture assertion because source
  and child transcripts were prefetched (`requests` was expected to contain
  only `ses_smoke_source`); no timing samples were produced. Raw records are in
  `packages/app/e2e/test-results/native-apps-{baseline,after}/` (ignored).
