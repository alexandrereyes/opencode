# Custom master session

Feature base: `aec1c2ce5435dae4a6dce8234f584439af2549c4` (the shared iOS development branch before this feature is committed).
Fixed integrated upstream baseline: `d4a6223d017e17f1beaa91d3e6ecc6511c5132ad`, verified against the unchanged upstream App,
UI and Session UI trees. This is a new custom capability, not an early upstream override.

## Policy ownership

`packages/plugin-app-custom/src/master` owns the hidden Mestra agent, its short invisible instructions, preferred
Sol ultrafast/medium selection and server-default fallback, typed `opencode` control tools, root/self filtering,
agent-only authorization, compact outputs and `custom.master` prompt-origin metadata. Existing native Session services
still own creation, durable prompt admission, queue/steer delivery, interruption, waiting, form validation and permissions.
`custom.preferences` adds optional per-server master pointers plus set/clear intents without a profile-version change.

The native iOS product owns the accessory-only entry, normal composer and first-send creation in managed chats, current
master exclusion from list/attention/global alert shortcuts, marker on target user messages, archive/reset and old-server
capability notice. The optional undo action is omitted because native unarchive does not exist. No web or upstream UI
tree is changed. See `packages/plugin-app-custom/docs/master-session.md` and `packages/ios-custom/README.md` for contracts,
limitations and isolated sandbox/simulator commands.

## Remaining reusable integration points

The initial feature changed four upstream-owned runtime files, **34 additions / 10 removals** relative to the feature base:

- `packages/plugin/src/effect/session.ts`: inherit the existing `SessionApi.active` operation and expose
  `form: Pick<SessionApi["form"], "reply">`; no duplicate input/output contracts.
- `packages/plugin/src/promise/session.ts`: the equivalent Promise client surface.
- `packages/plugin/src/promise/adapter.ts`: adapt both operations using their existing canonical Protocol endpoints.
- `packages/core/src/plugin/host.ts`: map process-local native Session active ownership to the client snapshot; resolve a
  form's owning Session Location, check form/session ownership, and call native `Form.reply`. Permission reply must also
  resolve the target Session Location rather than incorrectly reading the plugin instance's own permission registry.

No implementation body is copied or moved. No Core/Server import is added to the custom plugin. No Protocol, production
HttpApi, schema or generated client changes are required. Tests add two fixture members in `core/test/plugin/host.ts`.

The standard modified-upstream runtime metric against the fixed baseline changes from **46 files / 691 additions /
50 removals** at the feature base to **46 files / 725 additions / 60 removals**. Reproduce with:

```sh
git diff --numstat --diff-filter=M d4a6223d017e17f1beaa91d3e6ecc6511c5132ad -- \
  packages/core/src packages/cli/src packages/cli/script packages/server/src \
  packages/protocol/src packages/schema/src packages/plugin/src packages/client/src packages/tui/src
```

## Validation

- Core `test/plugin/session-controls.test.ts`: real coordinator start/settlement snapshots; native forms and permissions
  across two real temporary Locations; wrong-owner rejection, invalid native answers, answered state, repeated reply,
  missing Session and cross-Location permission resolution. No model or network request.
- Plugin `test/session-controls.test.ts`: Promise adapter output/input parity, native form-ID validation before delegation
  and unmasked native failure propagation, using the existing test host fixture (test-only Core dependency).
- Custom plugin: all tool boundaries and agent guards, top-level/self/archive filters, state, output budgets, preference
  intents, origin metadata, native action delegation and virtual-clock wait timeout.
- iOS: Swift package tests, warning-free simulator build, new master UI cases in both themes, existing four reading UI
  regressions and all app-hosted tests. Live Mestra executes every tool against the private 4179 sandbox and fake repos;
  Sol ultrafast is unavailable in that inventory, so the live run also verifies server-default Astra fallback.
- `bun run check` remains the canonical whole-tree check. Its final log and delivery report record concurrent-tree
  blockers separately from the scoped tests above; those tests do not waive it. Evidence is retained under the approved
  temporary `opencode/ios-mestra-prints/` directory.

Activation remains manual: implementation and verification never update the installed backend.

## Tool discovery isolation follow-up (2026-10-23)

The first implementation guarded execution correctly but attempted to hide tools through `session.context`. That hook
runs after the native snapshot has already rendered the Code Mode catalog and captured its executors. Removing individual
`event.tools.opencode_*` entries therefore cannot remove namespaced tools inside `execute`.

The existing `Tool.snapshot` supports whole-tool permission denies and applies them before Code Mode generation. However,
appending denies with `agent.transform` cannot enforce an all-other-agents policy: configured agents are added later by
`ConfigAgentPlugin` (post-plugins), and session rules follow agent rules. No existing tool visibility predicate is exposed.
Rather than reorder registries or repeat policy in Core, this follow-up adds a generic optional `Tool.Options.agents`
allowlist. Unscoped tools retain their behavior. Scoped tools are omitted when the selected agent is absent/not listed;
an empty allowlist hides a tool from all snapshots. Permission denies can still narrow an allowed agent's snapshot.
Raw `ctx.tool.list()` remains administrative registration inventory, not a model-facing catalog. Tool executors retain
their own authorization checks; this visibility option does not replace the Mestra guard.

Minimal reusable runtime changes relative to `a0039c2400c997dbff20a1cb0422094f68f0d952`: three files,
**6 additions / 3 removals**:

- `packages/schema/src/tool.ts`: optional typed `agents` registration option, inherited by Effect/Promise plugin tools.
- `packages/core/src/tool.ts`: optional agent argument on native snapshot; exclude agent-scoped tools before direct
  definitions and Code Mode inventory/catalog construction. Existing catalog cache remains keyed by visible tool names.
- `packages/core/src/session/context.ts`: pass the selected agent ID to that snapshot for every Session/child/auxiliary read.

`plugin-app-custom` sets `[mestra]` on its eight controls and removes the ineffective per-tool context deletion.
No Protocol/HttpApi or generated client changes, no copied upstream implementation, no iOS/web edits.

Proof: `core/test/tool-opencode-master-visibility.test.ts` fails on the original implementation, then passes for Mestra,
build, explore/subagent and a configured-later agent, checking both native resolved catalogs and real `execute/search`
results with an all-allow session rule. Repeating Mestra after other agents checks cache isolation. Generic direct and
Code Mode allowlist, omitted-agent, empty-list and permission-deny cases live in `core/test/tool-registry.test.ts`.
The existing custom test still directly exercises all eight unauthorized executors as defense in depth.

Live verification uses only `http://127.0.0.1:4179` and the fake repository under its private sandbox home. The script
`packages/plugin-app-custom/script/verify-master-visibility.ts` asks real build, Mestra, general-child and late-configured
sessions to search the complete `opencode` inventory without invoking control tools. Expected master counts: **0 / 8 / 0 / 0**.
Evidence: `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/master-tool-visibility/summary.json`.
Installed `1042585c28` predates this fix; Alexandre must trigger another `custom:update` to deploy it.

## Conversational interface follow-up (2026-10-27)

Goal: Mestra answers anything the app lists show and performs what their controls do. A baseline run against the owned
4183 sandbox showed four tool-level gaps the prompt could not fix: no unread or failed state, subagent requests and work
invisible to the root, no mark-as-read, and every turn starting with a catalog `search`. The plugin now owns a session
inventory (`master/inventory.ts`) and thirteen pinned controls; see `packages/plugin-app-custom/docs/master-session.md`.

The only runtime extension is `session.view` in the plugin context, the existing client operation, with the same shape
as the earlier `active`/`form.reply` additions. Five upstream-owned files, **7 additions / 1 removal**:

- `packages/plugin/src/effect/session.ts`, `packages/plugin/src/promise/session.ts`: inherit `SessionApi.view`.
- `packages/plugin/src/promise/adapter.ts`: adapt it through its canonical `session.view` endpoint.
- `packages/core/src/plugin/host.ts`: map it to native `Session.view` (idle instant as milliseconds).
- `packages/core/test/plugin/host.ts`: the fixture member.

No Protocol/HttpApi, schema, generated client or upstream implementation body changes.

The custom web composer resolved a session's agent only among visible agents, so sending from the web to the hidden
`mestra` agent fell back to `build` and switched the session away from Mestra (its controls disappeared mid-conversation).
`packages/app-custom/src/providers/models` now keeps a session's current hidden agent while the picker still lists only
visible agents.

Live evaluation used fake repositories, seeded sessions in every state (unread, read, failed, muted, pinned, pending
question, subagent permission, running) and fresh Mestra sessions driven through the HTTP API, checking both the answers
and the resulting server state.
