# Finishing a browse handoff from the apps

Rev. 2026-11-09 (the browse session's resource lasts as long as the session; the handoff happens on it). Earlier:
2026-11-08 (calls without `session`), 2026-11-07. Contract between this plugin and the MyAgents apps for **finishing a
browse `handoff()` from the iPhone or the Mac**: the existing resource viewer (`resources.md`) shows the agent's tab in
Alexandre's real Chrome, takes his touches and keyboard (secure entry for passwords) and lets him press the handoff
card's **Continue**. It builds on `browser-handoff.md` (a handoff that waits is "Precisa de você") and on a spike
(2026-11-07, not merged), whose findings hold: the relay scopes a CDP connection to one browse session with its token;
the plugin learns the session from the call's explicit `session`, else as "Sessão do browse" below tells; Continue
lives in a closed shadow root and checks `isTrusted`, which CDP mouse input satisfies, and nothing else (no relay
route, no MCP tool) ends a handoff. Change it only compatibly and update this file with the change.

Normative examples: `docs/browse-handoff-remoto/*.json` (decoded by `test/browse-handoff-remoto-contract.test.ts`; the
apps read them in their tests the way they read `live-activity/state-browser.json`).

## Identity

One resource per browse session: `chrome:browse:<browse session>`, kind `chrome`, `meta` `{ kind: "chrome", cdp:
"http://127.0.0.1:<relay port>", browse: "<browse session>", targetID?, url?, title? }`. The browse session is the call's
explicit `session` argument, else the agent's current one when the plugin can tell it for sure (below). Otherwise the
call gets no resource: the handoff still waits and still is "Precisa de você", but it has no `resourceID`.

Since rev. 2026-11-09 the resource exists **whenever agents use that browse session**, not only during a handoff
(section 0), and a handoff happens on it: it gains `handoff` and the handoff's locks while the handoff waits and loses
them when it ends, staying in the list.

### Sessão do browse (rev. 2026-11-08, browse 0.0.16)

browse 0.0.16's MCP server keeps a **current session per caller**, keyed by the `_meta["ai.opencode/sessionID"]` the
OpenCode server sends with every MCP call (the agent's own session, a subagent's included). Until the agent makes
another current, it is `mcp-` and the first 8 hex digits of the SHA-256 of that session ID; `session_new`,
`session_use`, `session_reset` with an id, `session_adopt` or `execute` with a `session`, and `session_delete` of the
current one (which leaves a random `mcp-…`) change it. It lives only in the MCP process (forgotten when it restarts);
`OPENCODE_BROWSER_SESSION` in its environment shares one for everyone. Nothing outside the process reports it: not the
relay (`/cli/sessions` has no owner, no handoff), not the call's progress.

So the plugin (`browser-handoff/current.ts`) follows each agent session's browse calls through `execute.after` (their
input and structured output) for the sessions that may be current, always with browse's default among them, and takes
those **candidates** as the call starts. At the grace time (3 s) it reads `/cli/sessions` (with the relay token, which
stays in the request header; only ids and `updatedAt` are kept) and takes the **one candidate the relay stamped since
the call began** (browse stamps a session as an `execute` starts in it). Then everything goes as with an explicit
`session`: same identity, same locks, the hub still refuses it without that session's tab.

No resource (as before this revision) when:

- **none** of the candidates was stamped since the call began: the agent's current session is one the plugin cannot
  know (a `session_new` whose answer it did not see, `OPENCODE_BROWSER_SESSION`, a call still queued behind another in
  its session, or the relay not answering);
- **two or more** were: for example parallel calls of one agent in different sessions; either could hold the handoff;
- the relay token or `/cli/sessions` cannot be read.

`test/browser-handoff-current.test.ts` pins the derivation and the calls that move it against the installed package.

## 0. A browse session's resource (rev. 2026-11-09)

Alexandre watches the agent's tab live (the Mac stage, the iPhone viewer) and can **"Assumir controle"** as on any
resource, also when no handoff waits.

- **Registered** by the plugin (`src/resources/browse.ts`) on the browse tools that touch a session: `execute`,
  `session_new`, `session_reset` and the others, except `status`, `session_list`, `session_use`, `settings` (global)
  and `session_delete` (below). A call that still runs after the grace time (3 s) registers the session it names, else
  the one the Resolver above finds; when it ends, the session its result names (`execute`'s `session`, `session_new`'s
  id), else the one it named or was found to use. Nothing is registered when the session cannot be told for sure, nor
  for a failed call that was not found while it ran.
- **Owner**: the agent session that used it last and its root (`owner.sessionID`, `owner.rootSessionID`), as for the
  other resources (the latest user wins).
- **State** follows the existing rules (`resources.md`): `agent` while a call runs and for a while after (the activity
  says `browse <tool>`, never the code), then `live`/`idle`; `user` while Alexandre holds control; `stopped` while the
  session has no tab or the relay does not answer.
- **The tab**: the probe follows the tab the viewer followed so far while it stays open, else the session's own page
  (the relay's `/cli/sessions`), else another of the session's tabs. An agent's call never picks it (it cannot move a
  viewer off a handoff's tab).
- **Removed** when the relay answers without the session (`/cli/sessions`, read on the hub's probe, every 5 s)
  or at once on a successful `session_delete` of it. Never for inactivity, and kept across server restarts (the hub
  persists it without `handoff`, `capabilities` and `machine`).
- **The tab closes, the session goes on**: the resource stays, `stopped`, and comes back on the session's next tab.
- **`session_reset`**: the session keeps its id, so the resource stays and follows the session's new page.
- **`capabilities`** `{ navigation: true, tabs: true, focus: true }` (`Resources.browseCapabilities`): see section 3.
- **`machine`** (new, top-level): the Chrome's machine identity, as `handoff.machine` (section 4).

### Agents while Alexandre controls it

While he holds control (`control take` until `release` or 2 minutes without input), the plugin refuses, before they
run, the agents' browse calls on that session: the ones that name it (`session`, or `id` for `session_reset`,
`session_delete`, `session_use`) and the ones that name none when it may be their current session (the Resolver's
candidates). The call fails with a tool error:

> Alexandre está controlando pelo app a aba do navegador da sessão do browse "<session>", então esta chamada do browse
> foi bloqueada. Aguarde ele devolver o controle (ou 2 minutos sem toque): você receberá um aviso. Não tente contornar
> a trava por outra sessão, pelo shell ou pela CLI do browse.

plus, for a call without `session`, a line asking to repeat it with the right `session` if it was meant for another
one. Other sessions, `session_new`, `session_use`, `session_list`, `status` and `settings` go through. Shell commands
are refused too, as for any locked resource (`resources.md`): a `browse` CLI command naming the session, or one naming
the relay's port. When he gives control back (or it expires), the agent gets the usual "Alexandre interagiu com o
navegador … e devolveu o controle" notice with its next turn, and its calls run again.

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

- **Starts** when the handoff starts **waiting** (its call has run `limits.graceMs` = 3 s, the same moment
  `custom.browser-handoffs` lists it), never before. The session's resource gets (or, when the session had none yet,
  is created with) `handoff`, `capabilities` `{ navigation: false, tabs: false, focus: true }`, the handoff's message
  as `purpose` and the handoff's tab as `meta.targetID`; an open stream moves to that tab and keeps going without an
  `end`. `rpc.custom.browser-handoffs.changed { sessionID }` and `rpc.custom.resources.changed { ids }` announce it.
- **Owner**: the agent session whose call waits (`owner.sessionID`, a subagent's own session) and its root
  (`owner.rootSessionID`), so `custom.resources/list { sessionID: root }` lists it with the family's resources.
- **Ends** when the handoff stops waiting, whatever the reason. The app receives, in this order:
  1. on every open stream of the resource: `end { reason, kept: true }` with `handoff_completed`, `handoff_timeout`,
     `handoff_cancelled` or `handoff_failed` (`Resources.handoffEndReasons`), then the socket closes; Alexandre's
     control is released with it (no "Alexandre interagiu…" notice is added to the agent for a handoff's end);
  2. `rpc.custom.browser-handoffs.changed { sessionID, ended: { id, resourceID?, outcome } }` with `outcome`
     `completed` | `timeout` | `cancelled` | `failed` (`changed-ended.json`); a handoff that starts waiting sends the
     event without `ended` (`changed-waiting.json`);
  3. `rpc.custom.resources.changed { ids }`. Until rev. 2026-11-09 the resource was gone from then on (`not_found`).
     Now it **stays**, as section 0's: without `handoff`, with `browseCapabilities`, its earlier `purpose` (or none),
     no control; `get`, `snapshot`, `ticket` and `control` answer as for any resource. `kept: true` on the `end` says
     so: a viewer may open it again with a new ticket, or close as before.
- **Outcomes**: `completed` — the call returned after Continue; `timeout` — browse gave up waiting (its 10 min, or the
  agent's `timeoutMs`); `cancelled` — the call, its Code Mode `execute` or its session was interrupted, deleted or
  archived; `failed` — the call failed for another reason (the tab closed, the relay went away).

## 3. Capabilities and server-side locks

`Resources.Resource` gains three optional fields (`resource.json`, `resource-session.json`):

- `capabilities`: `{ navigation?: boolean, tabs?: boolean, focus?: boolean }`. For `navigation` and `tabs`,
  **`false` means the hub refuses it** and absent means allowed, as on every resource so far. `focus` is the opposite:
  offered only when `true` (section 4). Present on browse sessions' resources only:
  - while a handoff waits, `{ navigation: false, tabs: false, focus: true }` (`Resources.handoffCapabilities`): the app
    hides the address bar, back, forward, reload and the tab list;
  - otherwise (rev. 2026-11-09) `{ navigation: true, tabs: true, focus: true }` (`Resources.browseCapabilities`): the
    usual Chrome viewer, with the session's own tabs.
- `handoff`: `{ id, sessionID, message, since, machine? }`, present only while a handoff waits: the viewer may show
  the message; `machine` is section 4's.
- `machine` (rev. 2026-11-09): the same identity as `handoff.machine`, on every browse session's resource (section 4).

**Why navigation outside a handoff.** Input of any kind, navigation included, needs control (`control take`), so the
address bar and the tabs act only while Alexandre holds it: it is him acting, and the agent is locked out meanwhile
(section 0). What he reaches stays the agent's session: the connection sees only its tabs, and the relay applies the
session's allowlist to every navigation, his included. A handoff keeps its stricter locks because the agent is waiting
on that very page: leaving it would strand the handoff's card.

What the server enforces, whatever the app shows:

| Rule                                    | Enforcement                                                                                                                                                                                           |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| While a handoff waits: no navigation    | `navigate` inputs (`url`, `back`, `forward`, `reload`, `tab`) answer `error { message: "not_allowed" }` and are not applied (`stream-messages.json`).                                                 |
| While a handoff waits: only that tab    | The adapter's connection follows the handoff's target only; other tabs never appear in `meta.tabs`, frames or input. A stream open when the handoff starts moves there; when it ends the tabs return. |
| The handoff's locks only while it waits | `capabilities` and the connection change back when it ends (section 2); control taken during the handoff is released by its end.                                                                      |
| Only that session's tabs                | The relay scopes the adapter's CDP connection to the browse session (also outside a handoff).                                                                                                         |
| The session's allowlist                 | Navigations, his and the page's own, stay under the browse session's allowlist (enforced by the relay).                                                                                               |
| No other sessions' tabs                 | The relay's `/json/list` covers every session; the plugin keeps only this session's tabs before anything reaches the hub or the apps.                                                                 |
| Relay token                             | Read from browse's data directory only inside the adapter, never logged, returned, put in `meta` or written to a new file.                                                                            |
| Typed text                              | `text` inputs (passwords included) are never logged by the hub, the adapter or the relay (browse's debug log names CDP methods only).                                                                 |
| The agent while he controls it          | Its browse calls and shell commands on the session are refused (section 0).                                                                                                                           |

Everything else is the existing viewer: live frames, `touch`, `scroll`, `key`, `text`, `meta.focus.field` (`password`
switches the iPhone keyboard to secure entry), control tickets. Continue is a tap on the card in the page (trusted
CDP input); there is no separate "complete" call.

## 4. On the Mac: the stage and "Abrir no Chrome"

- **iPhone**: the action opens the resource's viewer full screen. **Mac**: it opens the live tab in the stage (the area
  beside the chat that already shows browsers and emulators) and adds **"Abrir no Chrome"**, which brings Alexandre's
  Chrome to the front on that very tab. The button shows only when `capabilities.focus` is `true` **and** the
  resource's `machine` (rev. 2026-11-09; on older servers only `handoff.machine`) equals the Mac app's own machine
  identity. Since rev. 2026-11-09 that holds for every browse session's resource on the same Mac, with or without a
  handoff: bringing the agent's own tab forward needs no extra lock (it neither navigates nor types).

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

`custom.resources/focus { id }` → `{}` (`focus.json`). The plugin brings the resource's tab to the front of its window
and that window to the front of the browser, through the relay on that session's tab (`Target.activateTarget`; if
the relay refuses it, `focus` answers `failed` and the app still activates Chrome). The Mac app calls it and, once it
answers (either way), activates the Chrome app (`com.google.Chrome`; the button hides while no Chrome runs).

**With browse 0.0.14 it always answers `failed`** (rev. 2026-11-07, found end to end): Chrome refuses
`Target.activateTarget` to extensions (`Not allowed`), and the relay blocks the fallback, `Page.bringToFront`, unless
its own environment sets `OPENCODE_BROWSER_ALLOW_FOREGROUND=1` (which would also let agents raise the window). The
plugin tries both on every call, so `focus` starts answering `{}` whenever browse allows one, with no app change.

**Decision (Alexandre, rev. 2026-11-07): the Mac app falls back to AppleScript.** It always calls `focus` first; when
it answers `failed`, the app selects the resource's tab itself through Chrome's AppleScript (the tab showing `meta.url`,
`meta.title` to break ties) and activates Chrome, which asks macOS once for the app's Automation permission over
Chrome. `unsupported` and `not_found` still mean no button. The relay keeps
`OPENCODE_BROWSER_ALLOW_FOREGROUND` unset, and the schema is unchanged. Same locks as input:

- only browse sessions' resources with `capabilities.focus: true` (rev. 2026-11-09: also without a handoff; with one,
  only while the plugin's registry still has it waiting), only their own target (the session-scoped connection cannot
  address another tab);
- `unavailable { reason: "unsupported" }` for any other resource, `not_found` once the resource is gone, `failed` when
  the relay refuses the activation;
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

Rev. 2026-11-09, with an app built for rev. 2026-11-08:

- The browse session's resource shows in Recursos as a Chrome resource while agents use the session, and its viewer
  works as for any Chrome resource (address bar and tabs act while he holds control).
- A handoff's end still sends `end` on every stream and closes it, then `browser-handoffs.changed` with `ended`, then
  `resources.changed`, in that order: the app closes the viewer and shows its notice as before. It ignores `kept`; the
  resource simply stays in the list (and opens again from there).
- A viewer opened **before** the handoff starts keeps streaming (now on the handoff's tab) with the capabilities it
  read when it opened, so it may still show the address bar; the hub refuses those inputs (`error not_allowed`). The
  handoff's actions (`resourceID` on the card, Live Activity, push) open the viewer anew, with the handoff's
  capabilities.
- "Abrir no Chrome" reads `handoff.machine`, so it shows only during a handoff, as before.
- The agent's block needs nothing from the app: the agent sees a failed browse call with the message of section 0.

## 6. Implementation notes (rev. 2026-11-07)

Compatible precisions found while implementing; none changes a schema or an example.

- **A refused batch is refused whole.** An `input` message (or `POST …/input`) whose `events` hold one refused input
  answers one `error not_allowed` and applies none of them; the app never mixes navigation with other input anyway.
- **Browser shortcuts are no way around `navigation: false`.** `key` inputs reach the page only: Chrome does not run
  its accelerators for DevTools input (`script/browse-handoff-check.ts --scenario keys`, in Alexandre's Chrome: Cmd+L
  and a typed URL, Cmd+T, Cmd+W, Cmd+[, Cmd+], Alt+←, Cmd+R and Backspace outside a field leave the URL, the session's
  tabs and the page's focus as they were, with history both ways). A page's own key handlers stay under the allowlist.
- **`ticket` for a resource that is gone answers `not_found`** for every kind, as section 2 asks; it used to answer
  `failed` (the hub's 409). The apps (`ResourceViewerModel`, iPhone and Mac) treat both alike: the viewer shows "Sem
  conexão com o recurso; tentando de novo…" and retries; existing resources still get their tickets as before, and a
  `control` ticket without control still answers `failed`.
- **Order at the start is not guaranteed.** The hub announces a new resource (`resources.changed`) on its own, so it may
  arrive just before or just after the handoff's `browser-handoffs.changed`; the order at the end is (section 2).
- **Only that tab, literally.** Popups or tabs the page opens during the handoff (an OAuth window) are not shown and
  cannot be reached from the viewer. If the handoff's tab closes, the resource may show `state: "stopped"` for a
  moment before its end arrives with `handoff_failed` or `handoff_cancelled` (rev. 2026-11-09; it was `gone`).
- **A Chrome dialog over the tab swallows every tap** (rev. 2026-11-08, found on the iPhone): after a login with a
  password Chrome finds in a data breach (the-internet.herokuapp.com's public `tomsmith` / `SuperSecretPassword!`),
  its password manager covers the tab with a warning, and Chrome then drops all input to that tab, from the viewer and
  from browse's own Playwright alike, while CDP still answers each command. The frames show only the page, so Continue
  seemed to do nothing. The adapter counts the trusted pointer events the page receives (from an isolated world, never
  the page's own scripts) and, when a tap never arrives, sends the viewers the existing `notice` (a tap over an
  `iframe`, `frame`, `embed` or `object`, such as a captcha or a 3-D Secure frame, reaches that document instead and is
  not checked): "O Chrome do Mac
  está ignorando os toques: um aviso do próprio Chrome cobre a página (por exemplo, sobre uma senha exposta em
  vazamento). Feche-o no Mac para continuar." (at most every 10 s). Closing the warning on the Mac lets the taps
  through again; turning off Chrome's "Avisar se as senhas forem expostas em uma violação de dados" avoids it.
  Nothing in browse 0.0.15 changed here (its card, relay handoff code and the extension's content script are as in
  0.0.14); a tab nobody shows also takes about 5 s per tap, but the taps arrive.
- **A tab in the background** keeps streaming (about 7 fps); the stream sends the existing `notice` when Chrome reports
  it hidden.
- **Browser zoom.** Touches and `meta.viewport` are in CSS pixels also when Alexandre's Chrome is zoomed (125 % today):
  `viewport` is the page's size (for example 1120 × 662 at 125 % for frames of 1400 × 828); frames keep their own size.
- **Where things run.** The plugin (`browser-handoff/index.ts`) registers the handoff through the hub's upsert with
  `meta { cdp: "http://127.0.0.1:<OPENCODE_BROWSER_PORT or 19988>", browse }`, `capabilities` and `handoff`; the hub
  asks the Chrome adapter to identify the session's tab first (`/json/list` filtered to that session, the session's
  own page preferred) and refuses the registration without one; it computes `handoff.machine` and keeps `handoff`,
  `capabilities` and `machine` in memory only. At the end it calls `POST /admin/resources/<id>/end { reason }` (viewers
  end with `kept`, control is dropped without a hand-back notice, the adapter's locked connection closes, no event; a
  browse resource without a waiting handoff answers `not_found`), emits `browser-handoffs.changed` with `ended`, then
  `POST /admin/announce`. A hub from before this contract ignores `handoff`; the plugin then removes what it
  registered and gives the handoff no `resourceID`.
- **The session's resource** (rev. 2026-11-09, `src/resources/browse.ts`) is registered with the same `meta` without
  `targetID`, `used` and an activity; for it the hub skips `identify` (the probe picks the tab, `probeBrowse` in
  `adapters/chrome.ts`) and computes the top-level `machine`. When a handoff starts or ends on a resource being
  streamed, the hub calls the adapter's `update`, which moves the stream to the new tab and applies or lifts the locks
  without ending it. The plugin's refusal runs in `execute.before` ahead of the handoff tracking, so a refused call
  never records a handoff; `browser-handoff/current.ts` keeps one tracker of current sessions for both.
- **Relay token.** The hub's adapter reads it per request from where browse keeps it (`OPENCODE_BROWSER_HOME`, else
  `$XDG_DATA_HOME/browse`, else `~/.local/share/browse`; `OPENCODE_BROWSE_RELAY_TOKEN_FILE` names the file, for
  sandboxes whose XDG directories are their own). It goes only into request headers and the WebSocket URL, which
  stays in memory; connection errors print URLs without their query. browse's own MCP in such a sandbox
  finds the relay only through the `relay-token` of the XDG directories it runs with: give it the real ones (or put the
  token there).
- **The hub's log stays empty** (`<state>/resources-hub/hub.log`) unless something fails: it logs no routine events,
  and never inputs.
- **End to end**: `script/browse-handoff-check.ts` drives a sandbox agent's real handoff in Alexandre's Chrome on the
  login fixture, for `completed`, `timeout`, `cancelled`, `failed`, `keys` and `bare` (`completed` with a call that
  names no browse session, which gets the Resolver all the same); with `--app` it waits for the iPhone or Mac app to act
  instead of acting itself. (`nosession`, a call without a Resolver, is gone with this revision.) Since rev. 2026-11-09
  each checks that the resource stays after the end. `script/browse-resource-check.ts` drives section 0 end to end: an
  agent's use shows the resource with frames; Alexandre takes control and navigates; the agent's call is refused with
  the message; he gives it back and the agent's next call runs (and hears the notice); a handoff on the same resource
  ends with `end kept` and the resource stays; `session_delete` removes it.

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
