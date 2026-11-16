# Finishing a browse handoff from the apps

Rev. 2026-11-16 (browse 0.1.0: an OpenCode session's tabs instead of browse sessions, browse's tools instead of CDP).
Earlier: 2026-11-09 (the resource lasts while agents use the browser; the handoff happens on it), 2026-11-08 (calls
without `session`), 2026-11-07. Contract between this plugin and the MyAgents apps for **finishing a browse handoff
from the iPhone or the Mac**: the existing resource viewer (`resources.md`) shows the agent's tab in Alexandre's real
Chrome, takes his touches and keyboard (secure entry for passwords) and lets him press the handoff card's **Continue**.
It builds on `browser-handoff.md` (a handoff that waits is "Precisa de você"). Findings that hold since rev. 2026-11-16,
checked end to end against browse 0.1.0 (`script/browse-relay-check.ts`): the relay gives clients its tools only (no CDP,
no sessions); every agent's tabs belong to an owner the plugin can compute; Continue lives in a closed shadow root and
checks `isTrusted`, which browse's own `click` satisfies (the relay dispatches it as trusted input, also while the
`handoff` call waits on that tab), and nothing else (no relay route, no tool) ends a handoff. Change it only compatibly
and update this file with the change.

Normative examples: `docs/browse-handoff-remoto/*.json` (decoded by `test/browse-handoff-remoto-contract.test.ts`; the
apps read them in their tests the way they read `live-activity/state-browser.json`). Their resource ID
(`chrome:browse:github-login`) predates owner IDs and stays as an opaque example value.

## Identity

One resource per OpenCode session that uses the browser through browse: `chrome:browse:<owner>`, kind `chrome`, `meta`
`{ kind: "chrome", cdp: "http://127.0.0.1:<relay port>", browse: "<owner>", targetID?, url?, title? }`, where
`targetID` is the followed tab's ID (browse's integer, as a string). The handoff happens on the same resource: it gains
`handoff` and the handoff's locks while the handoff waits and loses them when it ends, staying in the list.

### Owner and tabs (rev. 2026-11-16, browse 0.1.0)

browse 0.1.0 has no sessions. OpenCode gets its plain tools (`browse_navigate`, `browse_click`, `browse_handoff`…, in
Code Mode `tools.browse.<name>`); every page tool names the integer `tab` it acts on, and `navigate` without `tab` or
`tabs` with `action: "new"` opens one and answers with it. browse's MCP server makes each call for an **owner**: `mcp-`
and the first 8 hex digits of the SHA-256 of the (trimmed) `_meta["ai.opencode/sessionID"]` OpenCode sends with every
call, a subagent's own session included. The tabs a call opens are that owner's: the relay shows a call made for it
(`OpenCode-Browser-Owner`) only its own tabs, the ones Alexandre lent browse (`lent: true`, the toolbar button) and the
ones nobody claims (opened by the CLI or by a client that names no agent); other owners' tabs are invisible to it.

The plugin computes the same owner (`browseOwner`, `src/browser-handoff/calls.ts`) and follows the tab each call names
or opens (`callTab`): nothing is guessed any more. Limits: the relay reports no owner per tab, so tabs nobody claims
appear among every owner's; a tab Alexandre lent is shown only while it is the one followed.

## 0. A session's browse resource (rev. 2026-11-09, rev. 2026-11-16)

Alexandre watches the agent's tab live (the Mac stage, the iPhone viewer) and can **"Assumir controle"** as on any
resource, also when no handoff waits.

- **Registered** by the plugin (`src/resources/browse.ts`) on the browse calls that touch a tab: every tool except
  `status`, `settings` and `tabs` listing. A call that still runs after the grace time (3 s) registers with the tab it
  names; when it ends, with the tab it named or opened. A call that names no tab (closing a group of tabs) keeps the
  resource's tab; a quick call that failed registers nothing.
- **Owner**: the agent session that used it last and its root (`owner.sessionID`, `owner.rootSessionID`), as for the
  other resources.
- **State** follows the existing rules (`resources.md`): `agent` while a call runs and for a while after (the activity
  says `browse <tool>`, never its arguments), then `live`/`idle`; `user` while Alexandre holds control; `stopped` while
  the relay does not answer or no browser is connected to it.
- **The tab**: the one the agent's latest call used (`meta.targetID`), while the relay still lists it for the owner;
  else the owner's newest tab (the hub's probe, every 5 s, `tabs` as the owner). While a handoff waits the agent's calls
  never move it off the handoff's tab (the hub keeps it).
- **Removed** at once when a browser is connected and the owner has no tab left (`gone`). browse itself closes agent
  tabs no call used for 15 minutes, so a resource nobody uses that long goes with them. Kept across server restarts (the
  hub persists it without `handoff`, `capabilities` and `machine`).
- **`capabilities`** `{ navigation: true, tabs: true, focus: true }` (`Resources.browseCapabilities`): see section 3.
- **`machine`** (top-level): the Chrome's machine identity, as `handoff.machine` (section 4).

### Agents while Alexandre controls it

While he holds control (`control take` until `release` or 2 minutes without input), the plugin refuses, before they
run, that session's browse calls that touch a tab, on any of its tabs (another tab would only go around the lock). The
call fails with a tool error:

> Alexandre está controlando pelo app a aba do navegador que esta sessão usa pelo browse, então esta chamada do browse
> foi bloqueada. Aguarde ele devolver o controle (ou 2 minutos sem toque): você receberá um aviso. Não tente contornar
> a trava por outra aba, por outra sessão, pelo shell ou pela CLI do browse.

Other sessions, `status`, `settings` and `tabs` listing go through. Shell commands are refused too, as for any locked
resource (`resources.md`): a `browse` CLI command (which sees every tab) naming the locked tab or the owner, or any
command naming the relay's port. When he gives control back (or it expires), the agent gets the usual "Alexandre
interagiu com o navegador … e devolveu o controle" notice with its next turn, and its calls run again.

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
handoff waits on the resource, so an item without it (or an older server) offers no remote action.

## 2. Lifecycle

- **Starts** when the handoff starts **waiting** (its `handoff` or `demonstrate` call has run `limits.graceMs` = 3 s, the
  same moment `custom.browser-handoffs` lists it), never before. The session's resource gets (or, when it had none yet,
  is created with) `handoff`, `capabilities` `{ navigation: false, tabs: false, focus: true }`, the handoff's message as
  `purpose` and the call's `tab` as `meta.targetID`; the hub first checks with the relay that the owner sees that tab,
  else the handoff gets no resource. An open stream moves to that tab and keeps going without an `end`.
  `rpc.custom.browser-handoffs.changed { sessionID }` and `rpc.custom.resources.changed { ids }` announce it.
- **Owner**: the agent session whose call waits (`owner.sessionID`, a subagent's own session) and its root
  (`owner.rootSessionID`), so `custom.resources/list { sessionID: root }` lists it with the family's resources.
- **Ends** when the handoff stops waiting, whatever the reason. The app receives, in this order:
  1. on every open stream of the resource: `end { reason, kept: true }` with `handoff_completed`, `handoff_timeout`,
     `handoff_cancelled` or `handoff_failed` (`Resources.handoffEndReasons`), then the socket closes; Alexandre's
     control is released with it (no "Alexandre interagiu…" notice is added to the agent for a handoff's end);
  2. `rpc.custom.browser-handoffs.changed { sessionID, ended: { id, resourceID?, outcome } }` with `outcome`
     `completed` | `timeout` | `cancelled` | `failed` (`changed-ended.json`); a handoff that starts waiting sends the
     event without `ended` (`changed-waiting.json`);
  3. `rpc.custom.resources.changed { ids }`. The resource **stays**, as section 0's: without `handoff`, with
     `browseCapabilities`, its earlier `purpose` (or none), no control; `get`, `snapshot`, `ticket` and `control` answer
     as for any resource. `kept: true` on the `end` says so: a viewer may open it again with a new ticket.
- **Outcomes** (browse 0.1.0 answers `{"outcome": …, "tab": …}`): `completed` — Continue, on the card or the browse
  toolbar button; `timeout` — browse gave up waiting (its 10 minutes, or the call's `timeoutSeconds`); `cancelled` — the
  call, its Code Mode `execute` or its session was interrupted, deleted or archived, another handoff replaced it on the
  same tab, or the relay stopped the call; `failed` — the tab closed (`closed`) or the call failed otherwise (the relay
  went away, an unresponsive browser).

## 3. Capabilities and server-side locks

`Resources.Resource` has three optional fields for this (`resource.json`, `resource-session.json`):

- `capabilities`: `{ navigation?: boolean, tabs?: boolean, focus?: boolean }`. For `navigation` and `tabs`,
  **`false` means the hub refuses it** and absent means allowed, as on every resource. `focus` is the opposite: offered
  only when `true` (section 4). Present on browse resources only:
  - while a handoff waits, `{ navigation: false, tabs: false, focus: true }` (`Resources.handoffCapabilities`): the app
    hides the address bar, back, forward, reload and the tab list;
  - otherwise `{ navigation: true, tabs: true, focus: true }` (`Resources.browseCapabilities`): the usual Chrome viewer,
    with the session's own tabs.
- `handoff`: `{ id, sessionID, message, since, machine? }`, present only while a handoff waits: the viewer may show
  the message; `machine` is section 4's.
- `machine`: the same identity as `handoff.machine`, on every browse resource (section 4).

**Why navigation outside a handoff.** Input of any kind, navigation included, needs control (`control take`), so the
address bar and the tabs act only while Alexandre holds it: it is him acting, and the agent is locked out meanwhile
(section 0). What he reaches stays the agent's: the viewer lists and acts on the owner's tabs only, and browse applies
each tab's allowlist to every navigation, his included. A handoff keeps its stricter locks because the agent is waiting
on that very page: leaving it would strand the handoff's card.

What the server enforces, whatever the app shows:

| Rule                                    | Enforcement                                                                                                                                                          |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| While a handoff waits: no navigation    | `navigate` inputs (`url`, `back`, `forward`, `reload`, `tab`) answer `error { message: "not_allowed" }` and are not applied (`stream-messages.json`).                |
| While a handoff waits: only that tab    | The adapter captures and acts on the handoff's tab only; `meta.tabs` lists only it. A stream open when the handoff starts moves there; when it ends the tabs return. |
| The handoff's locks only while it waits | `capabilities` and the viewer change back when it ends (section 2); control taken during the handoff is released by its end.                                         |
| Only that session's tabs                | Every relay call carries the session's owner (`OpenCode-Browser-Owner`): the relay neither shows nor acts on another owner's tab.                                    |
| The tab's allowlist                     | Navigations, his and the page's own, stay under the tab's allowlist (enforced by browse).                                                                            |
| Relay token                             | Read from browse's data directory per request, only inside the plugin and the hub's adapter; never logged, returned, put in `meta` or written to a new file.         |
| Typed text                              | `text` inputs (passwords included) are never logged by the hub or the adapter; a failed `type` reports no relay message.                                             |
| The agent while he controls it          | Its browse calls and shell commands on the session's tabs are refused (section 0).                                                                                   |

### Live view (rev. 2026-11-16)

browse 0.1.0 has no screencast and no CDP for clients, so the viewer is built from its tools
(`src/resources/adapters/chrome-browse.ts`). Same wire protocol as before (`resources.md`); what changes is cadence:

- **Frames** are `screenshot { tab, format: "jpeg", scale: "css" }`: one image pixel per CSS pixel (browse scales a
  capture over 8000 px down and says by how much; the adapter maps through it), so touches map to CSS pixels with no
  zoom correction. Captures are polled, never two at once: every 250 ms while Alexandre controls the tab (from his
  first input), every second while he only watches, every 2 s on the `economy` profile, and at once after each input.
  An unchanged frame is not sent again. Measured (`script/browse-relay-check.ts`, headless Chromium, 1265 × 657 CSS px):
  `screenshot` p50 25 ms, p90 35 ms; 4 fps in control, 1 fps watching. A scroll shows its end, not its motion.
- **State** (`meta`, the same `ChromeState`): address, title and history (`navigation.canGoBack`/`canGoForward`) and
  the focused field come from `eval` in browse's isolated world, every 2 s while streaming and after each input; the
  tab list is the owner's `tabs`. Field values are never read.
- **Input**: a tap is `click { x, y }` in CSS pixels at the release point; a finger (or the Mac's mouse) that moves
  past 8 px scrolls the page with `scroll` (the opposite way, like a phone browser), or, when held 0.5 s before moving,
  `drag { from, to }` on release; the Mac's wheel is `scroll` with its deltas summed while one is in flight (browse
  scrolls the page's own scroller, not the element under the pointer); `key` is `press` (`Meta+Shift+K` combos);
  `text` is `type` into the focused element; `navigate` is browse's `navigate` (`url` or `back`/`forward`/`reload`,
  answering once the navigation commits); `tab` switches the followed tab among the owner's.
- **Pacing.** browse's human-like input (its `humanInput` setting, on by default) applies to the viewer's input too: a
  click takes about 0.5 s and typing about 80 ms per character; inputs run one after another.
- **The tab looks busy.** Each capture is a browse call on the tab, so while someone watches browse shows it in use
  (`RUN` badge) and keeps it focused for the page. Alexandre's toolbar click still takes it back and stops the call.
- Gone with CDP: the blocked-tap notice (a Chrome dialog over the tab); instead a capture the browser refuses (another
  extension's popup over the page) shows browse's reason as a `notice`, at most every 10 s.

## 4. On the Mac: the stage and "Abrir no Chrome"

- **iPhone**: the action opens the resource's viewer full screen. **Mac**: it opens the live tab in the stage (the area
  beside the chat that already shows browsers and emulators) and adds **"Abrir no Chrome"**, which brings Alexandre's
  Chrome to the front on that very tab. The button shows only when `capabilities.focus` is `true` **and** the
  resource's `machine` (on older servers only `handoff.machine`) equals the Mac app's own machine identity: every
  browse resource on the same Mac, with or without a handoff.

### Machine identity

`machine` = lowercase hex SHA-256 of the UTF-8 bytes of `"opencode-browse-machine/v1\u0000"` + the Mac's
`IOPlatformUUID` (trimmed, uppercased) (`src/resources/machine.ts`; vectors in `machine-identity.json`). The hub reads
its own `IOPlatformUUID` (`ioreg -rd1 -c IOPlatformExpertDevice`); the Mac app reads its own through IOKit
(`IOPlatformExpertDevice` → `IOPlatformUUID`) and hashes it the same way.

The plugin sets `machine` only when it can vouch that the tab's Chrome runs on the hub's Mac: the adapter reaches the
relay on loopback (`meta.cdp` is `127.0.0.1`) **and** the relay accepts browsers on loopback only (the hub checks that
the relay port refuses connections on the Mac's non-loopback addresses; browse's `hostname 0.0.0.0` makes it omit
`machine`). Otherwise the field is absent and no Mac shows the button.

Why this does not give false positives:

- The identity is of the machine where the **hub and the relay** run, which is where the Chrome is, not of the server
  the app talks to. When the server runs on the OrbStack Linux machine (`resources.md`, "Remote hub") the hub still
  runs on the Mac, so the identity is the Mac's; a Mac app on another machine, reaching this server through WARP, the
  4096 proxy or any tunnel, has another `IOPlatformUUID` and never matches.
- `IOPlatformUUID` is stable across reboots, network changes and app reinstalls, unique per Mac, and identical for the
  hub and the app on one Mac. The hash keeps the raw hardware UUID off the network while staying comparable.
- It is not an authorization: the server trusts the app already. A wrong match could at most bring the app's own local
  Chrome forward; the `focus` action itself keeps every lock of section 3.

### Focus action

`custom.resources/focus { id }` → `{}` (`focus.json`). **Since rev. 2026-11-16 it always answers `failed`, at once:**
browse 0.1.0 brings no tab to the front (its `bringToFront` does nothing) and gives clients no CDP to activate one.
`capabilities.focus` stays `true`, so the button keeps showing, because the Mac app's fallback (decided by Alexandre
on 2026-11-07, when browse 0.0.14 refused the activation too) does the work: when `focus` answers anything but
`not_found`, `unsupported` or `gone`, the app selects the resource's tab itself through Chrome's AppleScript (the tab
showing `meta.url`, `meta.title` to break ties) and activates Chrome. `unsupported` and `not_found` still mean no
button. Same locks as input: only browse resources with `capabilities.focus: true` (with a handoff, only while the
plugin's registry still has it waiting), `unsupported` for any other resource, `not_found` once the resource is gone;
it needs no control ticket.

## 5. Compatibility

- **Old app, new server**: unknown fields are ignored. The resource appears in the family's resource list like any
  Chrome resource; opening it works, and the navigation controls it still shows are refused by the hub
  (`error not_allowed`). Old apps show the `end` reason as a generic end.
- **New app, old server**: no `resourceID`, no `capabilities`, no `handoff`: the app offers no remote action.
- **Mac app with a server without `focus` or `machine`**: no "Abrir no Chrome"; the stage still shows the tab.
- New optional fields and one new RPC method only; no existing field, literal or reason changes meaning.
  `Unavailable.reason` keeps its literals (a refused input is a stream `error`, not an RPC reason).

Rev. 2026-11-16, with an app built for rev. 2026-11-09: nothing to change. IDs stay opaque (`meta.browse` is an owner
ID such as `mcp-9ccafeff`, `targetID` and `tabs[].id` are numeric strings the app passes back as `navigate { action:
"tab", target }`); the viewer receives fewer frames per second; "Abrir no Chrome" always takes the AppleScript path;
`end`, `kept`, the capabilities and the order of events at a handoff's end are unchanged.

## 6. Implementation notes

Compatible precisions found while implementing; none changes a schema.

- **A refused batch is refused whole.** An `input` message (or `POST …/input`) whose `events` hold one refused input
  answers one `error not_allowed` and applies none of them.
- **`ticket` for a resource that is gone answers `not_found`** for every kind; a `control` ticket without control still
  answers `failed`.
- **Order at the start is not guaranteed.** The hub announces a new resource (`resources.changed`) on its own, so it may
  arrive just before or just after the handoff's `browser-handoffs.changed`; the order at the end is (section 2).
- **Only that tab, literally.** Tabs the page opens during the handoff (an OAuth popup) are the owner's too, but the
  viewer stays on the handoff's tab until it ends. If the handoff's tab closes, the stream ends with an error and the
  resource may show `state: "stopped"` for a moment before its end arrives with `handoff_failed`.
- **Where things run.** The plugin registers the handoff through the hub's upsert with `meta { cdp: <relay endpoint>,
browse: <owner>, targetID: <tab> }`, `capabilities` and `handoff`. The relay endpoint is browse's own resolution:
  `OPENCODE_BROWSER_PORT`, else the port a live relay recorded in `<state>/relays/19988/relay.json` (a relay that found
  19988 taken moves to 19990–19997), else 19988. The hub asks the Chrome adapter to confirm the tab (`tabs` as the
  owner) and refuses the registration without it; it computes `handoff.machine` and keeps `handoff`, `capabilities` and
  `machine` in memory only. At the end it calls `POST /admin/resources/<id>/end { reason }`, emits
  `browser-handoffs.changed` with `ended`, then `POST /admin/announce`. A hub from before this contract ignores
  `handoff`; the plugin then removes what it registered and gives the handoff no `resourceID`.
- **The session's resource** (`src/resources/browse.ts`) is registered with the same `meta` (with the call's tab, when
  it names or opens one), `used` and an activity; the hub's probe confirms the tab or picks another. When the tab or the
  locks change on a resource being streamed, the hub calls the adapter's `update`, which moves the stream without
  ending it. The plugin's refusal runs in `execute.before` ahead of the handoff tracking, so a refused call never
  records a handoff.
- **Relay token.** Read per request from where browse keeps it (`OPENCODE_BROWSER_HOME`, else `$XDG_DATA_HOME/browse`,
  else `~/.local/share/browse`; `OPENCODE_BROWSE_RELAY_TOKEN_FILE` names the file, for sandboxes whose XDG directories
  are their own). It goes only into the `authorization` header. The hub never sends its process ID
  (`OpenCode-Browser-Client-Pid`): browse would then keep a managed relay alive as long as the hub lives.
- **The hub's log stays empty** (`<state>/resources-hub/hub.log`) unless something fails: it logs no routine events,
  and never inputs.
- **End to end**: `script/browse-relay-check.ts` runs a real browse 0.1.0 relay in a temporary home on its own port
  (never 19988), a headless Chromium with the unpacked extension paired through `relay-pairing.json`, a local login page,
  and the real hub with the real Chrome adapter: the probe shows only the owner's tab, `screenshot` latency and the
  stream's frame rate are measured, and a real `handoff` ends `continued` from a viewer's tap on its card. On macOS a
  headless Chrome needs `--use-mock-keychain` (else it waits on a Keychain prompt and the extension never connects).
  `script/e2e-browser-handoff.ts` checks every surface with real models against a fake browse MCP.

## Examples

| File                                  | Shape                                                                |
| ------------------------------------- | -------------------------------------------------------------------- |
| `handoffs-list.json`                  | `custom.browser-handoffs/list` output: with and without `resourceID` |
| `changed-waiting.json`                | `changed` when a handoff starts waiting                              |
| `changed-ended.json`                  | `changed` for each outcome                                           |
| `navigation-entry.json`               | one `custom.navigation` entry (built by `list`)                      |
| `resource.json`                       | `custom.resources/get` of a browse handoff's resource                |
| `resource-session.json`               | the same resource without a handoff, Alexandre in control            |
| `stream-messages.json`                | `meta` of the tab, `error not_allowed` and each `end` (with `kept`)  |
| `push-browser.json`                   | the APNs body (built by `notifications/index.ts` `body`)             |
| `../live-activity/state-browser.json` | Live Activity state with a `browser` attention and its `resourceID`  |
| `focus.json`                          | `custom.resources/focus` input, output and its errors                |
| `machine-identity.json`               | the machine identity's prefix, encoding and test vectors             |
