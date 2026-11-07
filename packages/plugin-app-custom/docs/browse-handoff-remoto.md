# Finishing a browse handoff from the apps

Rev. 2026-11-07. Contract between this plugin and the MyAgents apps for **finishing a browse `handoff()` from the
iPhone or the Mac**: the existing resource viewer (`resources.md`) shows the agent's tab in Alexandre's real Chrome,
takes his touches and keyboard (secure entry for passwords) and lets him press the handoff card's **Continue**. It
builds on `browser-handoff.md` (a handoff that waits is "Precisa de você") and on the spike
`spike-browse-handoff-remoto.md`. Change it only compatibly and update this file with the change.

Normative examples: `docs/browse-handoff-remoto/*.json` (decoded by `test/browse-handoff-remoto-contract.test.ts`; the
apps read them in their tests the way they read `live-activity/state-browser.json`).

## Identity

One resource per browse session: `chrome:browse:<browse session>`, kind `chrome`, `meta` `{ kind: "chrome", cdp:
"http://127.0.0.1:<relay port>", browse: "<browse session>", targetID?, url?, title? }`. The browse session is the call's
explicit `session` argument (`session_new` id; `~/.agents/AGENTS.md` asks agents to pass it). A call without one gets no
resource: the handoff still waits and still is "Precisa de você", but it has no `resourceID`.

## 1. From a handoff to its resource

`resourceID` (optional string, the resource ID above) appears wherever a waiting handoff already reaches the apps:

| Surface                                                   | Field                                                          | Example                               |
| --------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------- |
| `custom.browser-handoffs` `list`, each item               | `resourceID`                                                   | `handoffs-list.json`                  |
| `custom.session-family` `snapshot`, each `browser[]` item | `resourceID` (same `Handoff` schema)                           | `handoffs-list.json`                  |
| `custom.navigation` `list`, each Session                  | `browserResourceID` (the newest handoff's, like `browserText`) | `navigation-entry.json`               |
| Live Activity / watch `attention[]`, kind `browser` only  | `resourceID` (the oldest waiting handoff's of that root)       | `../live-activity/state-browser.json` |
| Push `session.attention`, `attention: "browser"`          | `opencode.resourceID`                                          | `push-browser.json`                   |

The app opens the viewer with `custom.resources/get { id: resourceID }` and the usual `ticket` / `control` calls; the
viewer then receives the resource's `capabilities` and `handoff` (below). `resourceID` is present only while the
resource exists, so an item without it (or an older server) offers no remote action.

## 2. Lifecycle

- **Created** when the handoff starts **waiting** (its call has run `limits.graceMs` = 3 s, the same moment
  `custom.browser-handoffs` lists it), never before. `rpc.custom.browser-handoffs.changed { sessionID }` and
  `rpc.custom.resources.changed { ids }` announce it.
- **Owner**: the agent session whose call waits (`owner.sessionID`, a subagent's own session) and its root
  (`owner.rootSessionID`), so `custom.resources/list { sessionID: root }` lists it with the family's resources.
- **Removed** when the handoff stops waiting, whatever the reason. The app receives, in this order:
  1. on every open stream of the resource: `end { reason }` with `handoff_completed`, `handoff_timeout`,
     `handoff_cancelled` or `handoff_failed` (`Resources.handoffEndReasons`), then the socket closes; Alexandre's
     control is released with it (no "Alexandre interagiu…" notice is added to the agent for a handoff's end);
  2. `rpc.custom.browser-handoffs.changed { sessionID, ended: { id, resourceID?, outcome } }` with `outcome`
     `completed` | `timeout` | `cancelled` | `failed` (`changed-ended.json`); a handoff that starts waiting sends the
     event without `ended` (`changed-waiting.json`);
  3. `rpc.custom.resources.changed { ids }`; from then on `custom.resources/get` answers `unavailable { reason:
"not_found" }`, and `snapshot`, `ticket` and `control` do too.
- **Outcomes**: `completed` — the call returned after Continue; `timeout` — browse gave up waiting (its 10 min, or the
  agent's `timeoutMs`); `cancelled` — the call, its Code Mode `execute` or its session was interrupted, deleted or
  archived; `failed` — the call failed for another reason (the tab closed, the relay went away).

## 3. Capabilities and server-side locks

`Resources.Resource` gains two optional fields (`resource.json`):

- `capabilities`: `{ navigation?: boolean, tabs?: boolean, focus?: boolean }`. For `navigation` and `tabs`,
  **`false` means the hub refuses it** and absent means allowed, as on every resource so far. `focus` is the opposite:
  offered only when `true` (section 4). A browse handoff's resource is `{ navigation: false, tabs: false, focus: true }`:
  the app hides the address bar, back, forward, reload and the tab list.
- `handoff`: `{ id, sessionID, message, since, machine? }`, present only on these resources: the viewer may show the
  message; `machine` is section 4's.

What the server enforces, whatever the app shows:

| Rule                            | Enforcement                                                                                                                                                               |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No navigation, no tab switching | `navigate` inputs (`url`, `back`, `forward`, `reload`, `tab`) answer `error { message: "not_allowed" }` and are not applied (`stream-messages.json`).                     |
| Only that tab                   | The adapter's CDP connection is scoped to the browse session by the relay and follows the handoff's target only; other tabs never appear in `meta.tabs`, frames or input. |
| Only while the handoff waits    | The resource exists only then; `control take` before or after answers `not_found`, and the end above releases control.                                                    |
| The session's allowlist         | Links the page itself follows stay under the browse session's allowlist (enforced by the relay).                                                                          |
| No other sessions' tabs         | The relay's `/json/list` covers every session; the plugin keeps only this session's handoff target before anything reaches the hub or the apps.                           |
| Relay token                     | Read from browse's data directory only inside the adapter, never logged, returned, put in `meta` or written to a new file.                                                |
| Typed text                      | `text` inputs (passwords included) are never logged by the hub, the adapter or the relay (browse's debug log names CDP methods only).                                     |

Everything else is the existing viewer: live frames, `touch`, `scroll`, `key`, `text`, `meta.focus.field` (`password`
switches the iPhone keyboard to secure entry), control tickets. Continue is a tap on the card in the page (trusted
CDP input); there is no separate "complete" call.

## 4. On the Mac: the stage and "Abrir no Chrome"

- **iPhone**: the action opens the resource's viewer full screen. **Mac**: it opens the live tab in the stage (the area
  beside the chat that already shows browsers and emulators) and adds **"Abrir no Chrome"**, which brings Alexandre's
  Chrome to the front on that very tab. The button shows only when `capabilities.focus` is `true` **and**
  `handoff.machine` equals the Mac app's own machine identity.

### Machine identity

`machine` = lowercase hex SHA-256 of the UTF-8 bytes of `"opencode-browse-machine/v1\u0000"` + the Mac's
`IOPlatformUUID` (trimmed, uppercased) (`src/resources/machine.ts`; vectors in `machine-identity.json`). The hub reads
its own `IOPlatformUUID` (`ioreg -rd1 -c IOPlatformExpertDevice`); the Mac app reads its own through IOKit
(`IOPlatformExpertDevice` → `IOPlatformUUID`) and hashes it the same way.

The plugin sets `machine` only when it can vouch that the tab's Chrome runs on the hub's Mac: the adapter reaches the
relay on loopback (`meta.cdp` is `127.0.0.1`) **and** the relay accepts browsers on loopback only (the hub checks that
the relay port refuses connections on the Mac's non-loopback addresses; browse's `set hostname 0.0.0.0` or a remote
pairing makes it omit `machine`). Otherwise the field is absent and no Mac shows the button.

Why this does not give false positives:

- The identity is of the machine where the **hub and the relay** run, which is where the Chrome is, not of the server
  the app talks to. When the server runs on the OrbStack Linux machine (`resources.md`, "Remote hub") the hub still
  runs on the Mac, so the identity is the Mac's; a Mac app on another machine, reaching this server through WARP, the
  4096 proxy or any tunnel, has another `IOPlatformUUID` and never matches. Comparing server URLs or "is the server on
  loopback" would be wrong both ways (a tunnel can look local; the Linux server is not on the Mac).
- `IOPlatformUUID` is stable across reboots, network changes and app reinstalls, unique per Mac, and identical for the
  hub and the app on one Mac. The hash keeps the raw hardware UUID off the network (the resource also reaches the
  iPhone and the watch) while staying comparable.
- It is not an authorization: the server trusts the app already. A wrong match could at most bring the app's own local
  Chrome forward; the `focus` action itself keeps every lock of section 3.

### Focus action

`custom.resources/focus { id }` → `{}` (`focus.json`). The plugin brings the handoff's tab to the front of its window
and that window to the front of the browser, through the relay on that session's tab (`Target.activateTarget`; if
the relay refuses it, `focus` answers `failed` and the app still activates Chrome). The Mac app calls it and, once it answers, activates the Chrome
app (`com.google.Chrome`; the button hides while no Chrome runs). Same locks as input:

- only resources with `capabilities.focus: true` and a waiting `handoff`, only their own target (the session-scoped
  connection cannot address another tab);
- `unavailable { reason: "unsupported" }` for any other resource or after its handoff stopped waiting, `not_found` once
  the resource is gone, `failed` when the relay refuses the activation;
- it neither navigates nor changes tabs of other sessions, and it needs no control ticket (it only shows the tab;
  typing still requires `control take`).

## 5. Compatibility

- **Old app, new server**: unknown fields are ignored. The resource appears in the family's resource list like any
  Chrome resource; opening it works, and the navigation controls it still shows are refused by the hub
  (`error not_allowed`). Old apps show the `end` reason as a generic end.
- **New app, old server**: no `resourceID`, no `capabilities`, no `handoff`: the app offers no remote action and
  everything else behaves as before.
- **Mac app with a server without `focus` or `machine`**: no "Abrir no Chrome"; the stage still shows the tab.
- New optional fields and one new RPC method only; no existing field, literal or reason changes meaning. `Unavailable.reason` keeps its
  literals (a refused input is a stream `error`, not an RPC reason).

## Examples

| File                                  | Shape                                                                |
| ------------------------------------- | -------------------------------------------------------------------- |
| `handoffs-list.json`                  | `custom.browser-handoffs/list` output: with and without `resourceID` |
| `changed-waiting.json`                | `changed` when a handoff starts waiting                              |
| `changed-ended.json`                  | `changed` for each outcome                                           |
| `navigation-entry.json`               | one `custom.navigation` entry (built by `list`)                      |
| `resource.json`                       | `custom.resources/get` of a browse handoff's resource                |
| `stream-messages.json`                | `meta` of the tab, `error not_allowed` and each `end` reason         |
| `push-browser.json`                   | the APNs body (built by `notifications/index.ts` `body`)             |
| `../live-activity/state-browser.json` | Live Activity state with a `browser` attention and its `resourceID`  |
| `focus.json`                          | `custom.resources/focus` input, output and its errors                |
| `machine-identity.json`               | the machine identity's prefix, encoding and test vectors             |
