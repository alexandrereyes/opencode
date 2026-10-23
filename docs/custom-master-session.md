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

Four upstream-owned runtime files, **34 additions / 10 removals** relative to the feature base:

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

Production is not activated: Alexandre must run `custom:update` to replace the older installed backend.
