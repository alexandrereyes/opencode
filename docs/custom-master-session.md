# Custom master session

Feature base: `aec1c2ce5435dae4a6dce8234f584439af2549c4` (the shared iOS development branch before this feature is committed).
Fixed integrated upstream baseline: `d4a6223d017e17f1beaa91d3e6ecc6511c5132ad`, verified against the unchanged upstream App,
UI and Session UI trees. This is a new custom capability, not an early upstream override.

## Policy ownership

`packages/plugin-app-custom/src/master` owns the hidden Mestra agent, its short invisible instructions, preferred
Sol ultrafast/medium selection and server-default fallback and `custom.master`. Since 2026-10-30 the typed session tools,
with their root/self filtering, compact outputs and prompt-origin metadata, are `src/sessions`, open to every agent (see
"Session tools outside the Mestra" below). Existing native Session services
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
inventory (`master/inventory.ts`, now `sessions/inventory.ts`) and thirteen pinned controls; see
`packages/plugin-app-custom/docs/sessions.md`.

The only runtime extension is `session.view` in the plugin context, the existing client operation, with the same shape
as the earlier `active`/`form.reply` additions. Five upstream-owned files, **7 additions / 1 removal**:

- `packages/plugin/src/effect/session.ts`, `packages/plugin/src/promise/session.ts`: inherit `SessionApi.view`.
- `packages/plugin/src/promise/adapter.ts`: adapt it through its canonical `session.view` endpoint.
- `packages/core/src/plugin/host.ts`: map it to native `Session.view` (idle instant as milliseconds).
- `packages/core/test/plugin/host.ts`: the fixture member.

No Protocol/HttpApi, schema, generated client or upstream implementation body changes.

The web composer resolves a session's agent only among visible agents, so sending from the web to the hidden `mestra`
agent falls back to `build` and switches the session away from Mestra (its controls disappear mid-conversation). The
removed custom web app kept a session's current hidden agent (`packages/app-custom/src/providers/models` at the tag
`web-custom-final`); the standard web app now served by the custom backend (`packages/app`, filter in
`src/providers/models/selection.tsx`) does not, so use the native apps for the Sessão mestra.

Live evaluation used fake repositories, seeded sessions in every state (unread, read, failed, muted, pinned, pending
question, subagent permission, running) and fresh Mestra sessions driven through the HTTP API, checking both the answers
and the resulting server state.

## Agent scoping removed (2026-10-30)

Decision (Alexandre): the thirteen Mestra controls are ordinary plugin tools. The Mestra already allows every tool, and
keeping them from other agents was never a security boundary (any agent with a shell can drive the server through
`opencode2 api`), only context hygiene. The `Tool.Options.agents` allowlist of the "Tool discovery isolation follow-up"
above, its snapshot filter and its call in `session/context.ts` are removed, so those Core and Schema files equal
upstream again; `core/test/tool-opencode-master-visibility.test.ts` and `script/verify-master-visibility.ts` are removed
with them, as is the executors' Mestra-only guard.

The controls move to their own unpinned `mestra` namespace (`tools.mestra.<name>`, names unchanged). Pinned, they would
be listed in every session's Code Mode catalog. Measured in the owned 4177 sandbox (`build` and `mestra` sessions,
rendered catalog, characters / estimated tokens at 4 characters per token):

| Revision                                   | `build` catalog | `mestra` catalog | whole `mestra` context, characters |
| ------------------------------------------ | --------------: | ---------------: | ---------------------------------: |
| Before (Mestra-only, pinned in `opencode`) |   7,293 / 1,823 |   12,568 / 3,142 |                             37,444 |
| Unpinned in `opencode`                     |   8,558 / 2,140 |    8,558 / 2,140 |        33,576 (previous tool list) |
| Unpinned `mestra` namespace (chosen)       |   8,846 / 2,212 |    8,846 / 2,212 |                             34,584 |

Unpinned listings compete for the 2,000-token inline budget, so another agent's catalog grows only to that budget. In
`opencode` the shorter Mestra listings displaced two native listings of `build` (`session_read`, `read_mcp_resource`);
their own namespace costs 72 more tokens and keeps the native `opencode` listings exactly as before. The Mestra's
instructions name each tool by its exact path with its input keys, so it calls them without `search`.

Calls from other sessions: the caller is the calling session's top-level ancestor (a subagent acts for its family), left
out of the lists and refused as a target ("it is the calling session"); Mestra sessions stay excluded and refused; only
the Mestra's messages carry `custom.master` (shown as "Sessão mestra" by the apps), others carry
`custom.sender: {sessionID, agent}`.

## Session tools outside the Mestra (2026-10-30)

The thirteen controls and the custom `tools.opencode.session_read` are a generic capability, so they leave `master/`
for `packages/plugin-app-custom/src/sessions` (`index.ts`, `inventory.ts`, `read.ts`) and one Code Mode namespace with
neutral descriptions, `sessions`. `master/` keeps the agent, its persona, instructions and permissions, the
`custom.master` RPC (`info`, `ensure`, the pointer) and the model memory.

| Former path                      | New path                   |
| -------------------------------- | -------------------------- |
| `tools.mestra.sessions_list`     | `tools.sessions.list`      |
| `tools.mestra.projects_list`     | `tools.sessions.projects`  |
| `tools.mestra.session_status`    | `tools.sessions.status`    |
| `tools.opencode.session_read`    | `tools.sessions.read`      |
| `tools.mestra.sessions_search`   | `tools.sessions.search`    |
| `tools.mestra.session_send`      | `tools.sessions.send`      |
| `tools.mestra.session_create`    | `tools.sessions.create`    |
| `tools.mestra.session_update`    | `tools.sessions.update`    |
| `tools.mestra.session_interrupt` | `tools.sessions.interrupt` |
| `tools.mestra.session_mark_read` | `tools.sessions.mark_read` |
| `tools.mestra.session_archive`   | `tools.sessions.archive`   |
| `tools.mestra.session_wait`      | `tools.sessions.wait`      |
| `tools.mestra.requests_list`     | `tools.sessions.requests`  |
| `tools.mestra.request_answer`    | `tools.sessions.answer`    |

`read` and `search` repeat the names of the native file tool and of Code Mode's `search(...)`, but the call forms
differ (`tools.sessions.read(...)`, `tools.sessions.search(...)` against a bare `read` call and `search(...)`), so they
stay; narration resolves the qualified name and never a bare one. Tool IDs and permission actions follow the namespace
(`sessions_<name>`, formerly `mestra_<name>` and `opencode_session_read`); no configuration, test or plugin rule named
the former actions. The custom registration no longer redefines the `opencode` namespace description, so upstream's
applies.

Pinning, measured in the owned 4177 sandbox (`build` and `mestra` sessions, rendered catalog, characters / estimated
tokens at 4 characters per token):

| Revision                                                          | `build` catalog | `mestra` catalog | whole `mestra` context, characters | `sessions` listings shown                             |
| ----------------------------------------------------------------- | --------------: | ---------------: | ---------------------------------: | ----------------------------------------------------- |
| Before (`bb29a8eed`: `mestra` namespace, `opencode.session_read`) |   8,846 / 2,212 |    8,846 / 2,212 |                             34,584 | `session_read` in `opencode`                          |
| `sessions`, nothing pinned                                        |   8,805 / 2,201 |    8,805 / 2,201 |                             34,477 | `answer`, `archive`, `interrupt`, `mark_read`, `send` |
| `sessions`, `read` pinned (chosen)                                |   8,917 / 2,229 |    8,917 / 2,229 |                             34,590 | `answer`, `archive`, `interrupt`, `read`, `send`      |

`session_read` was never pinned: it was listed because it fitted the inline budget. Unpinned in the larger `sessions`
namespace it no longer fits, and shorter listings take its place. Pinning `read` costs 28 tokens over nothing pinned
(18 over before) and displaces `mark_read`, which other agents rarely need; `read` is what other agents use routinely,
and the apps' session mentions name it. The other tools stay unpinned: the Mestra's instructions name every path and
input key, so it calls them without `search`, and other agents find them with `search`.

Compatibility: the Watch narration (`watch/delegation.ts`) and the apps' voice narration (`VoiceMasterProgress` in
`OpenCodeKit/Voice.swift`, used by `VoiceMaster.swift`) map the current path, the tool ID and every former name to the
same text, so an older server or transcript still narrates. The apps' session mention now reads "Use
tools.sessions.read (tools.opencode.session_read on older servers)"; an older app talking to a newer server names only
the former path, whose call fails as an unknown tool, and the model falls back to `search`.

Sandbox (4177, own home, shell denied and the probe guard blocking the launchers): a Mestra session (`claude-haiku-5-5`)
answered "quais sessões precisam de mim?" with `tools.sessions.requests` and `tools.sessions.list`, created a throwaway
session with `tools.sessions.create`, waited with `tools.sessions.wait`, sent with `tools.sessions.send`, all without
`search`; both admitted prompts carry `custom.master`. A `build` session given an app-style session mention read it with
`tools.sessions.read` directly and found `tools.sessions.list` with one `search`.
