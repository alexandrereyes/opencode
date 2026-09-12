# App mentions plugin POC

## Goal

Move the computer-use app autocomplete out of OpenCode's built-in MCP HTTP API
and into one configurable plugin. Keep only a reusable MCP invocation capability
in the plugin host. This POC starts from the existing custom implementation.

## Frozen UI/plugin contract

- Package: `@opencode/plugin-app-custom` in `packages/plugin-app-custom`.
- Browser-safe entrypoint: `@opencode/plugin-app-custom/rpc`.
- Namespace export: `AppMentions` (the repository's self-export pattern).
- `AppMentions.App`: Effect Schema and same-name type with the existing persisted
  shape: `{ server: string, name: string, path?: string, bundleID: string,
running: boolean }`. Optional `path` remains omitted when unavailable.
- `AppMentions.Definition`: portable RPC definition, ID `custom.app-mentions`.
- Method `list`: input `{}`, output `{ apps: App[] }`.
- Location comes from the RPC call options, not from the payload:
  `client.rpc(AppMentions.Definition).list({}, { location: { directory } })`.
- No application-specific field remains in `@opencode/schema/mcp` or the
  generated standard client.

## Plugin behavior

The plugin uses its public context only, with no Core/Server imports. In its
Location, prefer connected `open-computer-use`, then connected
`codex-computer-use`. Invoke `list_apps` with empty arguments, preserve the
existing parser and deduplication by bundle ID, and never infer an app path.
Preserve the five-second discovery timeout and empty-list behavior for missing
servers, failed calls, MCP error results, and unusable output. Cancellation must
propagate rather than leak work after plugin unload/request cancellation.

Load the plugin through normal configuration/discovery, not a new built-in
Core dependency. Provide a project-local loader for this POC and document how
to configure it for other Locations. Do not edit the user's global config.

## Reusable plugin-host capability

Add `ctx.mcp.callTool({ server, name, args? })` to both Effect and Promise plugin
contexts. It invokes an existing MCP connection in the plugin's Location and
returns a typed, generic MCP result (`server`, `tool`, `isError`, `content`, and
structured output where present). Define the public result/error boundary
without importing Core types into Plugin or exposing connection credentials.
This is a plugin capability, not a new public arbitrary-tool HTTP endpoint.
Promise calls support cancellation through the repository's established options
pattern; Effect calls use Effect interruption. Domain API inheritance must
continue following `packages/plugin/AGENTS.md`.

## UI behavior

Keep autocomplete lazy and scoped to the current server and Location. Preserve
selection, insertion, prompt serialization, drafts, history, and queued app
references. Plugin absence or failure produces no app suggestions and must not
break the rest of the composer. Do not fall back to the removed HTTP endpoint.

## Removal scope

Remove the app-specific MCP HTTP endpoint, handler, Core parser module, public
MCP app schema, and their generated client surfaces. Move feature tests to the
plugin or update them to test its actual implementation. Other custom features
remain outside this POC.

## Parallel ownership

- Backend worker: Plugin API/adapter/host, the new plugin package and RPC
  contract, project-local loader, Core/Protocol/Schema/Server removals, generated
  clients, backend/plugin tests, dependency installation and lockfile.
- UI worker: `packages/app/**`, including package dependency, composer schema,
  RPC consumer, fixtures and applicable tests. Do not edit the lockfile or the
  shared contract implementation.
- Reviewer: contract, review, integration verification, and final assessment.

## Acceptance

1. The real plugin is loadable by the normal plugin mechanism and callable over
   the generic RPC transport.
2. A fixture MCP server exercises the generic capability and plugin discovery;
   include missing/error cases and Location behavior where meaningful.
3. Composer tests cover RPC-based app selection and preserved reference payload.
4. Existing app references decode with the new owning schema.
5. No feature-specific Core implementation or old endpoint consumers remain.
6. Run generation after Protocol removal and package-level typechecks/tests.
7. Do not restart the live app/server or change global configuration. No commits,
   pushes, or deployment are part of this POC.

## Activate and verify the POC

During the POC, this worktree included `.opencode/plugins/app-custom.ts` for
project-local discovery. The loader was removed when activation moved into the
custom runtime because retaining both sources would produce a duplicate plugin
ID. With `open-computer-use` (preferred) or `codex-computer-use` connected,
opening app autocomplete calls the plugin RPC in the active Location; without
either server it returns no suggestions.

For a standard OpenCode deployment outside this custom runtime, install or
publish the package and add `@opencode/plugin-app-custom` to the desired
project or global `plugins` configuration. The project-local source loader was
only a historical POC mechanism and is no longer shipped. The POC did not
modify global configuration.

The custom macOS runtime now supplies the release-built
`packages/plugin-app-custom/dist` directory through its final virtual configuration
document. This activates the plugin for every Location served by that runtime
without changing user configuration, publishing npm, or retaining a path to a
development worktree. Do not also configure this custom-only package globally or
through a project-local loader.

### Backend verification result

The POC integration test starts an ephemeral HTTP server and two real stdio MCP
fixtures. Through the public `@opencode/client` RPC client it verifies normal
`.opencode/plugins` discovery, `open-computer-use` preference over the legacy
server, and an isolated second Location where the plugin RPC is unavailable. It
also verifies that `GET /api/mcp/computer-use/app` returns 404. Separate host
tests cover the five-second timeout and cancellation from Effect interruption,
Promise request abort, and Promise plugin-scope closure.

## Review outcome

The POC meets the agreed contract. The app imports only the portable plugin
contract, and the plugin production source has no Core or Server imports.
The MCP Protocol group, public MCP schema, and Server MCP handler are now
identical to `upstream/beta` at the comparison ref used for this POC.

The upstream-facing runtime change is a generic plugin capability: one Core
host adapter (22 added lines), public Effect/Promise interfaces, public MCP
result/error types, and Promise cancellation handling. The removed feature
implementation comprised 41 Core lines, 32 Protocol/Schema/Server lines, and
49 generated-client lines. The custom plugin owns 76 production lines plus
its project-local loader. These numbers describe this migration, not a
measurement of conflict rates in future merges.

Review caught and corrected an unstable Solid resource source that could have
rediscovered apps on every keystroke. Browser regression coverage now checks
one request while typing in the same context, a fresh request when reopening,
preserved app insertion/submission, and empty app suggestions on plugin failure.
Persistence tests assert both legacy and current app references explicitly.

Validation completed:

- 7 Core integration tests, 1 HTTP integration test, 4 plugin tests, and
  9 composer schema tests passed.
- The focused composer browser regression and its E2E typecheck passed.
- Package typechecks passed for Plugin, the custom plugin, Schema, Protocol,
  Core, Server, Client, and App; plugin package builds passed.
- Client generation, frozen-lockfile installation, and diff checks passed.
- A preexisting Plugin host test failure involving macOS `/var` versus
  `/private/var` was reproduced in the original checkout and left untouched.

This validates migration through a reusable plugin operation and existing RPC
transport. It does not establish that causal undo can be implemented with
ordinary lifecycle hooks; that requires its own contract and POC.
