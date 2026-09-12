# Subscription quotas plugin migration

## Scope and ownership

Move the custom subscription-quota integration from Server/Protocol into the
existing `@opencode/plugin-app-custom` package. One implementation worker owns
the migration; the parent session reviews it. Existing upstream defects are
outside scope.

Base: `origin/custom` at `89f562067`, including the app-mentions plugin delivery.

## Contract

- Browser-safe export: `@opencode/plugin-app-custom/subscriptions/rpc`.
- Namespace: `Subscriptions`, using the repository self-export convention.
- `Subscriptions.Definition`: portable RPC ID `custom.subscriptions`.
- Method `list`: input `{}`, output `Subscriptions.Info` directly.
- `Info` keeps the exact existing subscription response shape:
  `status: "ok" | "unconfigured" | "unavailable"` and `accounts`.
- Each account preserves `id`, `name`, `enabled`, `plan`, `authenticated`,
  `cooldownSeconds`, `bankedResets`, `remaining`, `resetAt`, `observedAt`, `stale`,
  and `hasCapacity`, with the current nullability and banked-reset fields.
- Location is selected through normal RPC options, not the payload. Quotas
  remain server-host data; selecting another Location does not change their
  meaning or expose another server's cached response.

## Runtime behavior

The plugin reads `OPENCODE_LLM_PROXY_URL` and queries `/_admin/status` server-side.
Preserve the existing normalization, credential/OAuth filtering, eight-second
timeout, absent-configuration result, and unavailable result on failed/malformed
responses. Cancellation must remain effective. Browser code never receives the
raw admin response or accesses the proxy directly.

Keep one installed plugin with feature modules. Preserve the existing plugin
registration ID and app-mentions RPC/export so the already-shipped activation
and MyEnv smoke continue to work. No additional loader or global configuration
change is needed. The plugin implementation must not import Core or Server.
This feature should require no new plugin-host capability.

## UI and removal

Replace the subscription HTTP call and generated subscription types with the
plugin RPC and its public contract. Preserve loading/refresh behavior, the
one-minute refresh interval, manual refresh, account ordering, Pro pool,
banked-reset display, and failure fallback. Keep UI copy and layout unchanged.

Remove `GET /api/server/subscriptions`, its handler, the Server implementation,
and generated standard-client surfaces. Migrate meaningful tests to the plugin;
update UI fixtures to RPC. Preserve all other custom server operations.

## Validation

- Follow App's production benchmark baseline/comparison requirement before
  changing session files, using the isolated benchmark harness.
- Test quota normalization, nullable/missing data, banked resets, output
  sanitization, timeout, and unavailable/unconfigured states.
- Exercise real plugin loading plus generic HTTP RPC with a local HTTP proxy
  fixture; verify the removed endpoint returns 404 and app-mentions still works.
- Run affected UI tests and a production build, package typechecks, client
  generation from `packages/client`, and a release smoke with the existing
  delivery mechanism when applicable.
- Do not restart the live app/server, alter global configuration, or fix
  preexisting upstream bugs. Commit/push/integration follows reviewer approval.

## Implementation validation (2026-09-12)

- Production command-palette benchmark, isolated fixture, one smoke sample per
  scenario: session lookup `1.0 ms` baseline / `0.8 ms` after; Home lookup
  `0.8 ms` baseline / `0.6 ms` after. Both runs passed. This is a regression
  smoke comparison, not a statistically meaningful performance claim.
- Plugin tests cover normalization, nulls, clamping, banked resets, credential
  filtering, upstream failures, malformed payloads, the eight-second timeout,
  and request cancellation.
- Server integration loads the real plugin and calls both RPCs over HTTP against
  real MCP and LLM-proxy fixtures. It also verifies the old route is `404` and
  an unconfigured Location reports `rpc.unavailable`.
- Production UI E2E covers RPC input and Location selection, periodic/manual
  refresh, loading, missing-plugin fallback, account ordering, and Pro pool UI.
  A live `session.moved` change immediately selects the new Location; a delayed
  response from the old Location cannot replace its unavailable result.
- An isolated custom-runtime smoke loaded `packages/plugin-app-custom/dist`,
  observed plugin ID `custom.app-mentions`, called both RPCs, and received `404`
  from the removed endpoint. It used temporary configuration, database, port,
  and process only; no installed service or release activation was touched.
