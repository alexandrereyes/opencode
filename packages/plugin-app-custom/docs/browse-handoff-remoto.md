# Finishing a browse handoff from the apps

Rev. 2026-11-22 (browse 0.1.5: every agent sees every tab, so the plugin keeps which tabs are a session's; chosen tab
ids). Earlier: 2026-11-16 (browse 0.1.0: an OpenCode session's tabs instead of browse sessions, browse's tools instead
of CDP), 2026-11-09 (the resource lasts while agents use the browser; the handoff happens on it), 2026-11-08 (calls
without `session`), 2026-11-07. Contract between this plugin and the MyAgents apps for **finishing a browse handoff
from the iPhone or the Mac**: the existing resource viewer (`resources.md`) shows the agent's tab in Alexandre's real
Chrome, takes his touches and keyboard (secure entry for passwords) and lets him press the handoff card's **Continue**.
It builds on `browser-handoff.md` (a handoff that waits is "Precisa de você"). Findings that hold since rev. 2026-11-22,
checked end to end against browse 0.1.5 (`script/browse-relay-check.ts`): the relay gives clients its tools only (no CDP,
no sessions) and, since browse 0.1.1, no owners either: every call lists and may use every agent tab and every lent
one, so which tabs are a session's is known only to this plugin (section "Sessions and tabs"); Continue lives in a
closed shadow root and checks `isTrusted`, which browse's own `click` satisfies (the relay dispatches it as trusted
input, also while the `handoff` call waits on that tab), and nothing else (no relay route, no tool) ends a handoff.
Change it only compatibly and update this file with the change.

Normative examples: `docs/browse-handoff-remoto/*.json` (decoded by `test/browse-handoff-remoto-contract.test.ts`; the
apps read them in their tests the way they read `live-activity/state-browser.json`). Their resource ID
(`chrome:browse:github-login`) predates owner IDs and stays as an opaque example value.

## Identity

One resource per OpenCode session that uses the browser through browse: `chrome:browse:<owner>`, kind `chrome`, `meta`
`{ kind: "chrome", cdp: "http://127.0.0.1:<relay port>", browse: "<owner>", targetID?, url?, title? }`, where
`targetID` is the followed tab's ID (browse's integer, as a string). The handoff happens on the same resource: it gains
`handoff` and the handoff's locks while the handoff waits and loses them when it ends, staying in the list. `<owner>`
is `mcp-` and the first 8 hex digits of the SHA-256 of the (trimmed) session ID, a subagent's own session included
(`browseOwner`, `src/browser-handoff/calls.ts`): the owner browse 0.1.0 gave the session's tabs, kept since rev.
2026-11-22 only as the resource's ID.

### Sessions and tabs (rev. 2026-11-22, browse 0.1.5)

browse has no sessions. OpenCode gets its plain tools (`browse_navigate`, `browse_click`, `browse_handoff`…, in Code
Mode `tools.browse.<name>`); every page tool names the `tab` it acts on, and `navigate` without `tab` or `tabs` with
`action: "new"` opens one and answers with its integer.

**Why the plugin keeps the tabs.** Up to browse 0.1.0 the relay kept each agent's tabs apart: every call went for an
owner derived from OpenCode's `_meta["ai.opencode/sessionID"]`, and the relay showed a call (`OpenCode-Browser-Owner`)
only its owner's tabs. browse 0.1.1 removed that isolation: the relay ignores the header, browse's MCP server no
longer reads that `_meta`, and every call lists and may use every agent tab and every lent one by its ID. browse still
tells agent tabs (`lent: false`) from the ones Alexandre lent (`lent: true`, the toolbar button). Listing the relay's
tabs would now show any session every agent's tabs, the lent ones and the CLI's, so the resource holds its own:

- **Its tabs** (`Entry.tabs`, in the hub, persisted with the resource, never in `Resources.Resource`): the tabs its
  session's browse calls named (`tab`) or opened (the `tab` of `navigate` without `tab` and of `tabs new`), and the
  popups those opened: the relay's `tabs` list gives each tab's `opener` (browse reports the same tabs as a call's
  `newTabs`), and a popup joins the resource of the tab that opened it unless another holds it already. Tabs the
  session never touched (another agent's, a lent one it did not use, one the CLI opened) never appear in it. An entry
  from before this revision holds the tab it followed.
- **Chosen ids** (browse 0.1.2). `tabs new` with an `id` like `work-mail` opens a tab (or answers with the one that
  already has that id, without navigating it) and every tool takes that id as `tab`, as well as the integer. The plugin
  registers the call's tab as named; the hub resolves a chosen id through the relay's `tabs` list (each entry's `id`)
  to browse's integer, which is all `meta.targetID` and the hub keep (an id the relay does not list registers no tab).
- **One resource per tab, the last user's.** When a session's call names a tab another resource holds, the tab moves
  to the caller's resource, which follows it; the other keeps the rest (and goes if it had no other). A tab shown in two
  resources would have two viewers driving one page and two locks for it, and Alexandre's control of one would not
  hold the other. The exception: a tab a handoff waits on stays with its handoff (another handoff on it takes it,
  browse cancels the first).
- **The followed tab** (`meta.targetID`): the one the session's latest call used, while it is open; else the one of
  its tabs a call used last (`lastUsed` in the relay's list).

Limits: the hub's probe reads the list every 5 s, so a popup joins its resource within that time unless the call that
opened it registers first (each registration probes at once). A tab closed and listed again soon after (a relay
restart while the browser reconnects) may leave the resource if a probe ran in between; the session's next call on it
brings it back. Since 0.1.2 a call naming a tab by its chosen id fails with `<id> is busy` while another call runs in
that tab, and the viewer's captures are calls (section 3, "Live view"): an agent that names its tab by chosen id while
Alexandre watches it may get that error now and then, and browse tells it to try again.

## 0. A session's browse resource (rev. 2026-11-09, rev. 2026-11-16, rev. 2026-11-22)

Alexandre watches the agent's tab live (the Mac stage, the iPhone viewer) and can **"Assumir controle"** as on any
resource, also when no handoff waits.

- **Registered** by the plugin (`src/resources/browse.ts`) on the browse calls that touch a tab: every tool except
  `status`, `settings` and `tabs` listing. A call that names its tab (integer or chosen id) and still runs after the
  grace time (3 s) registers with it; when a call ends, it registers with the tab it named or opened. A call that names
  none while it runs (`navigate` opening a tab) registers only when it answers; one that names no tab at all (closing a
  group of tabs) keeps the resource's tab; a quick call that failed registers nothing. Each registration adds the tab to
  the resource's own (section "Sessions and tabs").
- **Owner**: the agent session that used it last and its root (`owner.sessionID`, `owner.rootSessionID`), as for the
  other resources.
- **State** follows the existing rules (`resources.md`): `agent` while a call runs and for a while after (the activity
  says `browse <tool>`, never its arguments), then `live`/`idle`; `user` while Alexandre holds control; `stopped` while
  the relay does not answer or no browser is connected to it.
- **The tab**: the one the agent's latest call used (`meta.targetID`), while the relay still lists it; else the one of
  the resource's tabs a call used last (the hub's probe, every 5 s: one `tabs` list for every browse resource). While a
  handoff waits the agent's calls never move it off the handoff's tab (the hub keeps it).
- **Removed** at once when a browser is connected and none of the resource's tabs is open (`gone`), also when another
  session took its last one. browse itself closes agent tabs no call used for a while (its `idleMinutes` setting, 15
  minutes by default; `keepOpen` tabs stay), so a resource nobody uses that long goes with them. Kept across server
  restarts (the hub persists it, its tabs included, without `handoff`, `capabilities` and `machine`).
- **`capabilities`** `{ navigation: true, tabs: true, focus: true }` (`Resources.browseCapabilities`): see section 3.
- **`machine`** (top-level): the Chrome's machine identity, as `handoff.machine` (section 4).

### Agents while Alexandre controls it

While he holds control (`control take` until `release` or 2 minutes without input), the plugin refuses, before they
run:

- that session's browse calls that touch a tab, on any tab, its own or not, and new ones (another tab would only go
  around the lock). The call fails with a tool error:

  > Alexandre está controlando pelo app a aba do navegador que esta sessão usa pelo browse, então esta chamada do
  > browse foi bloqueada. Aguarde ele devolver o controle (ou 2 minutos sem toque): você receberá um aviso. Não tente
  > contornar a trava por outra aba, por outra sessão, pelo shell ou pela CLI do browse.

- since rev. 2026-11-22, any other session's browse call that would act on one of the resource's tabs (browse lets
  every agent use every tab): one it names as `tab` (integer or chosen id), the `tabs` it closes, a group it closes
  whole (`tabs close { group }`) that holds one of them, or `tabs new` with the chosen id of one of them (which would
  answer with that tab):

  > Alexandre está controlando pelo app a aba do navegador que esta chamada do browse usaria (uma aba de outra
  > sessão), então ela foi bloqueada. Use uma aba sua ou aguarde ele devolver o controle (até 2 minutos sem toque);
  > esta sessão não recebe aviso. Não tente contornar a trava pelo shell ou pela CLI do browse.

Other sessions' calls on other tabs or opening new ones, `status`, `settings` and `tabs` listing go through. Shell
commands are refused too, as for any locked resource (`resources.md`): a `browse` CLI command (which may use every
tab) naming one of the resource's tabs by integer or chosen id, or any command naming the relay's port. When he gives
control back (or it expires), the resource's session gets the usual "Alexandre interagiu com o navegador … e devolveu
o controle" notice with its next turn, and the calls run again.

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
  `purpose` and the call's `tab` as `meta.targetID` (browse's integer; a chosen id is resolved, rev. 2026-11-22); the
  hub first checks with the relay that the tab is open, else the handoff gets no resource. The tab joins the resource's
  own and leaves any other's (section "Sessions and tabs"). An open stream moves to that tab and keeps going without an
  `end`.
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
- **Outcomes** (browse 0.1.0 to 0.1.5 answer `{"outcome": …, "tab": …}`): `completed` — Continue, on the card or the
  browse toolbar button; `timeout` — browse gave up waiting (its 10 minutes, or the call's `timeoutSeconds`);
  `cancelled` — the call, its Code Mode `execute` or its session was interrupted, deleted or archived, another handoff
  replaced it on the same tab, or the relay stopped the call; `failed` — the tab closed (`closed`) or the call failed otherwise (the relay
  went away, an unresponsive browser).

## 3. Capabilities and server-side locks

`Resources.Resource` has three optional fields for this (`resource.json`, `resource-session.json`):

- `capabilities`: `{ navigation?: boolean, tabs?: boolean, focus?: boolean }`. For `navigation` and `tabs`,
  **`false` means the hub refuses it** and absent means allowed, as on every resource. `focus` is the opposite: offered
  only when `true` (section 4). Present on browse resources only:
  - while a handoff waits, `{ navigation: false, tabs: false, focus: true }` (`Resources.handoffCapabilities`): the app
    hides the address bar, back, forward, reload and the tab list;
  - otherwise `{ navigation: true, tabs: true, focus: true }` (`Resources.browseCapabilities`): the usual Chrome viewer,
    with the resource's own tabs (section "Sessions and tabs").
- `handoff`: `{ id, sessionID, message, since, machine? }`, present only while a handoff waits: the viewer may show
  the message; `machine` is section 4's.
- `machine`: the same identity as `handoff.machine`, on every browse resource (section 4).

**Why navigation outside a handoff.** Input of any kind, navigation included, needs control (`control take`), so the
address bar and the tabs act only while Alexandre holds it: it is him acting, and the agent is locked out meanwhile
(section 0). What he reaches stays the agent's: the viewer lists and acts on the resource's own tabs only, and browse
applies each tab's allowlist to every navigation, his included. A handoff keeps its stricter locks because the agent is
waiting on that very page: leaving it would strand the handoff's card.

What the server enforces, whatever the app shows:

| Rule                                    | Enforcement                                                                                                                                                          |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| While a handoff waits: no navigation    | `navigate` inputs (`url`, `back`, `forward`, `reload`, `tab`) answer `error { message: "not_allowed" }` and are not applied (`stream-messages.json`).                |
| While a handoff waits: only that tab    | The adapter captures and acts on the handoff's tab only; `meta.tabs` lists only it. A stream open when the handoff starts moves there; when it ends the tabs return. |
| The handoff's locks only while it waits | `capabilities` and the viewer change back when it ends (section 2); control taken during the handoff is released by its end.                                         |
| Only that session's tabs                | Rev. 2026-11-22: the relay lists every tab to all; the adapter shows and acts only on the resource's own (`Entry.tabs`), never another's, a lent one or the CLI's.   |
| The tab's allowlist                     | Navigations, his and the page's own, stay under the tab's allowlist (enforced by browse).                                                                            |
| Relay token                             | Read from browse's data directory per request, only inside the plugin and the hub's adapter; never logged, returned, put in `meta` or written to a new file.         |
| Typed text                              | `text` inputs (passwords included) are never logged by the hub or the adapter; a failed `type` reports no relay message.                                             |
| The agents while he controls it         | The session's browse calls, any session's call on the resource's tabs, and shell commands on them are refused (section 0).                                           |

### Live view (rev. 2026-11-16, rev. 2026-11-22)

browse (0.1.0 to 0.1.5) has no screencast and no CDP for clients, so the viewer is built from its tools
(`src/resources/adapters/chrome-browse.ts`). Same wire protocol as before (`resources.md`); what changes is cadence:

- **Frames** are `screenshot { tab, format: "jpeg", scale: "css" }`: one image pixel per CSS pixel (browse scales a
  capture over 8000 px down and says by how much; the adapter maps through it), so touches map to CSS pixels with no
  zoom correction. Captures are polled, never two at once: every 250 ms while Alexandre controls the tab (from his
  first input), every second while he only watches, every 2 s on the `economy` profile, and at once after each input.
  An unchanged frame is not sent again. Measured (`script/browse-relay-check.ts`, headless Chromium): browse 0.1.0,
  1265 × 657 CSS px, `screenshot` p50 25 ms, p90 35 ms; browse 0.1.5 (2026-11-22, which rounds captures to whole
  pixels), 1280 × 657, p50 27 ms, p90 41–56 ms (three runs on a loaded Mac); both 4 fps in control, 1 fps watching
  (one loaded run: 2 and 0.8), and a tap on Continue ends the handoff in about 1.2 s (browse's human-like click
  included). A scroll shows its end, not its motion.
- **State** (`meta`, the same `ChromeState`): address, title and history (`navigation.canGoBack`/`canGoForward`) and
  the focused field come from `eval` in browse's isolated world, every 2 s while streaming and after each input; the
  tab list is the relay's `tabs` narrowed to the resource's own (the hub tells the viewer when they change: a popup
  joins, another session takes one). Field values are never read.
- **Input**: a tap is `click { x, y }` in CSS pixels at the release point; a finger (or the Mac's mouse) that moves
  past 8 px scrolls the page with `scroll` (the opposite way, like a phone browser), or, when held 0.5 s before moving,
  `drag { from, to }` on release; the Mac's wheel is `scroll` with its deltas summed while one is in flight (browse
  scrolls the page's own scroller, not the element under the pointer); `key` is `press` (`Meta+Shift+K` combos);
  `text` is `type` into the focused element; `navigate` is browse's `navigate` (`url` or `back`/`forward`/`reload`,
  answering once the navigation commits); `tab` switches the followed tab among the resource's own (his pick stays
  until an agent's call moves the resource to another tab, a handoff starts, or another session takes that tab).
- **Pacing.** browse's human-like input (its `humanInput` setting, on by default) applies to the viewer's input too: a
  click takes about 0.5 s and typing about 80 ms per character; inputs run one after another.
- **The tab looks busy.** Each capture is a browse call on the tab, so while someone watches browse shows it in use
  (`RUN` badge, `busy: true` in `tabs`), keeps it focused for the page and counts it as used (`lastUsed`, idle
  cleanup). Alexandre's toolbar click still takes it back and stops the call. Since browse 0.1.2 an agent call that
  names the tab by its chosen id while a capture runs answers `<id> is busy`, and the agent retries (section "Sessions
  and tabs").
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
browse (0.1.0 to 0.1.5) brings no tab to the front (its `bringToFront` does nothing) and gives clients no CDP to
activate one.
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

Rev. 2026-11-22, with an app built for rev. 2026-11-16: nothing to change. Resource IDs, `meta` (`targetID` stays
browse's integer, never a chosen id), the stream's `meta.tabs`, the events and the RPC are the same. What the app may
notice: a resource's tab list can change while it is open (a popup joins, another session takes a tab; a `meta` with
the new list arrives), and a resource can go away because another session took its last tab.

## 6. Implementation notes

Compatible precisions found while implementing; none changes a schema.

- **A refused batch is refused whole.** An `input` message (or `POST …/input`) whose `events` hold one refused input
  answers one `error not_allowed` and applies none of them.
- **`ticket` for a resource that is gone answers `not_found`** for every kind; a `control` ticket without control still
  answers `failed`.
- **Order at the start is not guaranteed.** The hub announces a new resource (`resources.changed`) on its own, so it may
  arrive just before or just after the handoff's `browser-handoffs.changed`; the order at the end is (section 2).
- **Only that tab, literally.** Tabs the page opens during the handoff (an OAuth popup) join the resource too (their
  `opener` is its tab), but the viewer stays on the handoff's tab until it ends. If the handoff's tab closes, the stream
  ends with an error and the resource may show `state: "stopped"` for a moment before its end arrives with
  `handoff_failed`.
- **Where things run.** The plugin registers the handoff through the hub's upsert with `meta { cdp: <relay endpoint>,
browse: <owner>, targetID: <tab> }`, `capabilities` and `handoff`. The relay endpoint is browse's own resolution:
  `OPENCODE_BROWSER_PORT`, else the port a live relay recorded in `<state>/relays/19988/relay.json` (a relay that found
  19988 taken moves to 19990–19997), else 19988. The hub asks the Chrome adapter to confirm the tab (the relay's
  `tabs`, by integer or chosen id, rev. 2026-11-22) and refuses the registration without it; it computes
  `handoff.machine` and keeps `handoff`, `capabilities` and `machine` in memory only. At the end it calls
  `POST /admin/resources/<id>/end { reason }`, emits `browser-handoffs.changed` with `ended`, then
  `POST /admin/announce`. A hub from before this contract ignores `handoff`; the plugin then removes what it registered
  and gives the handoff no `resourceID`.
- **The session's resource** (`src/resources/browse.ts`) is registered with the same `meta` (with the call's tab, when
  it names or opens one: as `targetID`, browse's integer or a chosen id, which the hub resolves through the adapter's
  `identify`), `used` and an activity. The hub adds the tab to the resource's `tabs`, takes it from any other browse
  resource, and its probe (one `tabs` list for all of them) drops the tabs that closed, adds popups and confirms the
  followed tab or picks another; a registration made while a probe runs is kept (the probe's answer for that resource
  only removes what was there when it started, and the registration's own probe checks its tab). `GET /admin/locks`
  gives each browse resource's `tabs`, for the plugin's refusal. When the tab, the tabs or the locks change on a
  resource being streamed, the hub calls the adapter's `update`, which moves the stream without ending it. The plugin's
  refusal runs in `execute.before` ahead of the handoff tracking, so a refused call never records a handoff.
- **No owner header** (rev. 2026-11-22). The relay ignores `OpenCode-Browser-Owner` since browse 0.1.1, so the adapter
  no longer sends it; it lists and acts on tabs by browse's integer only.
- **Relay token.** Read per request from where browse keeps it (`OPENCODE_BROWSER_HOME`, else `$XDG_DATA_HOME/browse`,
  else `~/.local/share/browse`; `OPENCODE_BROWSE_RELAY_TOKEN_FILE` names the file, for sandboxes whose XDG directories
  are their own). It goes only into the `authorization` header. The hub never sends its process ID
  (`OpenCode-Browser-Client-Pid`): browse would then keep a managed relay alive as long as the hub lives.
- **The hub's log stays empty** (`<state>/resources-hub/hub.log`) unless something fails: it logs no routine events,
  and never inputs.
- **End to end**: `script/browse-relay-check.ts` runs a real browse 0.1.5 relay in a temporary home on its own port
  (never 19988), a headless Chromium with the unpacked extension paired through `relay-pairing.json`, a local login page,
  and the real hub with the real Chrome adapter behind the plugin's real hooks for two simulated sessions (one with a
  chosen tab id): each resource holds only its own tabs, a call of one session on the other's tab is refused while
  Alexandre controls it, `screenshot` latency and the stream's frame rate are measured, and a real `handoff` ends
  `continued` from a viewer's tap on its card. On macOS a headless Chrome needs `--use-mock-keychain` (else it waits on
  a Keychain prompt and the extension never connects). `script/e2e-browser-handoff.ts` checks every surface with real
  models against a fake browse MCP.

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
