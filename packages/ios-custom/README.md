# OpenCode iOS (custom)

Native iOS client, written in Swift, for the OpenCode backend. It talks to the same server as the TUI and the custom
web app (`packages/app-custom`), and adds no separate backend of its own.

The goal is to replace the custom web app on the phone, where it runs today as a PWA, with a native experience. It
will grow feature by feature until the phone no longer needs the web app. Other form factors (iPad, Mac) may follow
later.

This is a personal app. It is distributed only through a private TestFlight (internal testing) and will never be
submitted to the App Store.

> **Status:** the "Sessões" screen is done (see [First screen: Sessões](#first-screen-sessões)). The conversation
> screen is being built in waves (see [Second screen: Conversa](#second-screen-conversa)).

## Ownership

- This package exists only on the `custom` branch. Branch from `custom` (or `origin/custom`) and target `custom`.
- It is not a Bun workspace package: it has no `package.json`, and Turbo and `bun run check` do not build it. Use the
  Xcode toolchain to build it.
- It must not require changes to the upstream-owned `packages/app`, `packages/ui`, or `packages/session-ui`, or to
  the custom web packages.
- Backend needs follow the repository order: use the existing endpoints and `packages/plugin-app-custom` RPCs first.
  Extend the plugin with a small, reusable extension point when needed. Use backend aggregation only as a last
  resort. Mobile-specific policy, such as push notifications or aggregated reads to save round trips on cellular,
  belongs in the plugin, not in shared backend packages.
- Priorities, in order: stability, simplicity, performance.

## Goals

- Connect to a server, by default the Mac reached through Cloudflare One (see [Network access](#network-access)).
  Other servers can be added by scanning `opencode pair` or entering the address and password manually, with
  credentials in the Keychain.
- Browse projects, worktrees, and sessions, including the custom navigation, archive, and session-family views.
- Read transcripts with live streaming, including Markdown, code, diffs, and tool output.
- Act on sessions: prompt and steer, manage the inbox queue, interrupt, choose the model and agent, answer permissions
  and forms, revert, and fork.
- Use the custom features exposed by the plugin, such as snippets, chats, requests, app mentions, and preferences.
- After the MVP: push notifications sent by the backend (see [Notifications](#notifications)).
- Integrate with the platform where it clearly beats the web: share sheet, Live Activities for running sessions,
  widgets, and App Intents.

Out of scope at first: iPad and Mac layouts, offline editing, and terminals (PTY).

## First screen: Sessões

The equivalent of WhatsApp's "Conversas": the same sessions, in the same order, as "Recentes" in the custom web
app's sidebar, with a different presentation. The web app is the behavior reference
(`packages/app-custom/src/shell/titlebar/sidebar-model.ts`, `sidebar-order.ts`, `sidebar-rows.ts`, and
`packages/app-custom/src/shell/notifications/session-attention.ts`) and is not changed by this work.

- **Rows:** only root sessions, without archived sessions or chats. Running state, permissions, and questions of
  subagents roll up into their root session. Pinned sessions come first, then the activity order. When a session has
  several states, the priority is permission > question > running > unread.
- **Data:** the `custom.navigation` RPC (paginated by 500), `custom.preferences` (selected repositories, pinned and
  muted sessions), `custom.subscriptions` (usage strip), and `custom.transcript/list` for previews. Previews read the
  latest messages of each visible session, as `packages/app-custom/src/agent-dashboard/preview.ts` does.
- **"Precisa de você" card:** sessions with a pending question or permission, which leave the main list while pending.
  "Permitir" and "Negar" answer the permission; "Responder" opens the session.
- **Working:** list, status and repository filters (including removing, reordering, and adding repositories), opening
  a session (the native conversation reader), Permitir/Negar, archive, pin, mute, "Marcar todas como lidas",
  "Atualizar", and the list of archived sessions (read-only: the backend has no unarchive).
- **Visual only for now:** new session, voice, "Sessão mestra", "Selecionar sessões", "Configurações", and the other
  tabs.
- **Unread:** a dot, with no count. Marking a session as unread is not offered, because the backend only moves the
  viewed watermark forward.
- **Muting:** stored in `custom.preferences` (`mutedSessions`, intent `sidebar.mute`), so that future notifications
  can respect it. For now, a muted session shows a crossed-out bell, appears in the "Silenciadas" filter, and shows
  its unread dot in a neutral color. It still appears in "Precisa de você".
- **Avatar:** two-letter monogram of the repository (the first letters of the first two words, or the first two
  letters of a single word: `abacato-v2` → `AV`, `opencode2` → `OP`). The color comes from `project.icon.color`, or a
  stable choice from the project ID when the project has none, through the theme's avatar tokens.
- **Components:** native iOS components themed by tokens: Liquid Glass tab bar, `tabViewBottomAccessory` for the
  "Sessão mestra" pill, `swipeActions`, `contextMenu` for long presses, and a large title with toolbar buttons.

## Second screen: Conversa

The conversation of one session, opened from "Sessões" (row tap and "Responder"). It replaces the provisional session
screen. The layout was approved through mockups; the mockups and the full layout briefing live outside the repository,
in `.agent-artifacts/tela-conversa/` of the working tree that produced them (`BRIEFING.md`, `r2-*`, `r4-*`, `r5-*`,
`r6-*`). The custom web app is the behavior reference (`packages/app-custom/src/session`, `src/composer`, and
`packages/session-ui-custom`), and it is not changed by this work. The backend contract for every element is recorded
in [`docs/conversation-contract.md`](docs/conversation-contract.md).

### Layout decisions

- **Header:** back; repository avatar whose ring is the **context window** (static arc of the used fraction, neutral
  color, warning color above 80%; tapping opens the usage details); title; a status line below it, like WhatsApp's
  "digitando…" (`neon-mountain · trabalhando…`, `aguardando você`); on the right, a glass capsule with the running
  agents counter (animated 5×5 pixel grid and the number of active subagents and background tasks; tapping lists them
  and opens a child session; hidden when nothing runs) and a separate `…` button.
- **Messages:** the user's messages are bubbles on the right with the time inside. The agent's text uses the full
  width, without a bubble, and is rendered as Markdown (lists, inline code, fenced code blocks with a copy button; no
  syntax highlighting yet).
- **Steps:** each step is a group, `Usou 6 · Ler, Shell, Editar e Agente`. Inside it, in order: `Pensou 6s` (with its
  sparkle icon), tool lines (`Leu docs/infra.md · 212 linhas`, `Rodou docker stack ls · 2s`, `Editou … +48 −0`, the
  running one highlighted with its elapsed time), and subagents as discreet cards (agent icon and name in the agent's
  color, description, time, `›`). The agent icon is the web app's: an animated pixel grid while running and the static
  subagent icon when done. The running step is expanded; finished steps are collapsed into one line.
- **Response footer:** only when the response finishes, a discreet line with model, effort, date, and copy
  (`Opus 5.5 · xhigh · 21/10 10:42 ⧉`).
- **Sticky message:** the last user message sticks below the header, truncated to two lines, while its response
  scrolls underneath, as in the web app. There is no other pinned banner.
- **Requests:** permission (`Quer rodar: …`, `Negar` outlined, `Permitir` filled) and question (options as buttons,
  free answer) cards inside the conversation.
- **Tray above the composer:** one tray with the running pill (`Opus 5.5 · trabalhando`, `Background`, `■ Parar`) and
  the queued messages (`Enviar agora`, edit, `×`).
- **Composer (V2):** one rounded card with the text at full width and, inside it below the text, a row with a small
  outlined `+` (attachments), `Opus 5.5 · xhigh`, a flexible space, the agent (`build`), and a round button: send when
  there is text, microphone when the field is empty (WhatsApp style).
- **Triggers:** `@` context (files, sessions, agents), `/` commands, `$` skills, and `#` snippets open a suggestion
  panel above the composer; the chosen item becomes a colored token in the field.
- **Selection:** selecting text in a response shows the native edit menu with `Copiar`, `Comentar`, and `Pergunta
paralela`. A comment attaches the quoted passage above the composer (`Citações · 1`) and is sent with the message.
  The side question (`/btw`) opens in a sheet that is not saved to the conversation.
- **Other:** plain background, day chips (`Hoje`, `Ontem`), the `Novas mensagens` divider, and a scroll-to-bottom
  button. The tab bar and the "Sessão mestra" accessory are hidden inside the conversation.
- **Token colors** come from the theme, never from fixed values: dedicated semantic roles for context mentions,
  agent mentions, commands, skills, and snippets, generated by `script/generate-themes.ts` from the same web tokens the
  web composer uses where they exist (files: `syntax-property`; agents: `syntax-type`; snippets and sessions:
  `v2-text-text-accent`) and, for commands and skills, which the web leaves uncolored, from the theme's `info` and
  `accent` palette colors.

### Waves

Each wave is implemented by a fresh agent, ends with a warning-free build, passing tests, and real simulator
screenshots against the sandbox in both themes, and is reviewed before the next one starts. The waves are committed
on one feature branch and integrated into `custom` together at the end. Order: 0–4, then 6, 5, and 7 (wave 5's
search navigates to messages and reuses wave 6's position restoration).

| Wave                     | Scope                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0. Contract and fixtures | Map the endpoints, events, and RPCs of every element into `docs/conversation-contract.md`; seed reproducible conversation states in the sandbox; capture sanitized JSON fixtures.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| 1. Reading               | Open from "Sessões"; header with context ring, status line, and agents capsule; bubbles, Markdown, code blocks, step groups, tools, subagents, footer; sticky message, day chips, `Novas mensagens`, scroll-to-bottom; older pages; live updates; marks the session viewed; opens child sessions from subagent cards (read-only, no composer). The composer appears in its V2 shape but is not functional yet.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 2. Acting                | Composer V2 with send and model/effort/agent selection; running tray with stop and background; queue with `Enviar agora`, edit, and remove; permission and question cards; agents list from the header capsule; context usage details. Model picker as in the web app (search over name, ID, and provider; favorites; default model; model and provider visibility); reusable toasts.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| 3. Advanced composer     | `@ / $ #` triggers with the suggestion panel and tokens; commands; snippets; attachments through `+`. Full-screen composer; drafts (with tokens and attachments) kept across app launches.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| 4. Selection             | Native edit menu on responses; comments with quotes sent with the message; side question sheet. Copy a user message from its long-press menu.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| 5. Session and reading   | Rename and archive from the `…` menu; session details sheet (project, worktree, branch, +/−, MCP/plugin/skill/LSP configuration); search in the conversation (loaded messages, then older pages on demand; there is no server-side search); incompatible-server and missing-directory notices. V2 removed `todowrite`: its historical parts remain suppressed. Native components, approved from real screenshots without mockups. |
| 6. Reading continuity    | Final-answer divider with the web rule (`finish stop`, completed, no error or retry, after activity, prefers `final_answer`, possibly several per exchange). Reading position per server and session (follow the tail, or message ID plus offset), kept in memory and across launches, restored with cancellable paging and a fallback to the tail. Selecting text pauses following the tail. Expanded tools remembered per session (IDs only). "Ir às novas mensagens" when unread messages are above. Shift+Return sends and Return alone inserts a newline, on hardware keyboards (`UIKeyCommand`) and on the software keyboard through the private `UIKeyboardImpl` state (`isShifted` without `isAutoShifted` or `isShiftLocked`), isolated in one file and falling back to a newline; remove it if TestFlight processing rejects the build (`ITMS-90338`). Edge-swipe back keeps working. |
| 7. Subagents and alerts  | Composer in child sessions, keeping the child's agent and with no notice; replies sent after the child delivered its result stay in the child (automatic delivery to the parent would need backend work and is out). In-app banner, tappable, when another session finishes, fails, or needs you, respecting mutes, ignoring child completions, deduplicated. Light haptics on explicit actions.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |

Out of scope for this screen for now: the microphone (visual only), "Alterações" and "Arquivos" in the `…` menu,
syntax highlighting, and balloon actions such as fork and revert.

Wave 1 must already render text in a way that supports a custom selection menu (wave 4), and the composer must be
able to hold attributed tokens (wave 3), so later waves do not rewrite earlier ones.

## Language

The app is Portuguese (pt-BR) only, since it is for personal use. User-visible strings are written in pt-BR, which is
the project's development language; there is no English source copy.

## Themes

No view uses a fixed color: every color comes from semantic tokens of a registered theme. Themes are generated, not
written by hand: a Bun script in this package runs the custom web app's own resolver
(`packages/ui-custom/src/theme`) over the OpenCode theme JSON files and writes the resolved tokens, which the app
bundles. Adding a theme means running the script. The first themes are OpenChamber dark and light. The theme is
selected through a local preference and a launch argument; a selector in Settings comes later.

## Platform and distribution

- **Only the latest iOS.** The deployment target is always the current major version (iOS 27 today) and moves up with
  each new major release. There is no support for older versions: use the newest APIs directly, without
  `#available` branches or fallbacks.
- **Private TestFlight only.** Builds go to an internal testing group in App Store Connect with automatic
  distribution, so every processed build reaches the iPhone without Beta App Review. App Store requirements (review
  guidelines, public privacy disclosures, screenshots) do not apply.
- **Signing:** Alexandre's personal Apple Developer team (`ERRYZ68LX5`), with automatic signing.
- **Identifiers:** bundle ID `br.com.alexandrem.opencode`, following the `alexandrem.com.br` domain already used by
  the Cloudflare One hostnames. Extensions use `br.com.alexandrem.opencode.<extension>`, and data shared between the
  app and its extensions uses the App Group `group.br.com.alexandrem.opencode`.
- **Upload:** a local script in this package, with no CI and nothing outside the Mac:
  1. `xcodebuild archive` for `generic/platform=iOS`;
  2. `xcodebuild -exportArchive` with an `ExportOptions.plist` containing `method = app-store-connect` and
     `destination = upload`, plus `-allowProvisioningUpdates` and an App Store Connect API key passed through
     `-authenticationKeyPath`, `-authenticationKeyID`, and `-authenticationKeyIssuerID`. The key stays outside the
     repository, in `~/.appstoreconnect/private_keys/`.
- **Versions:** the build number (`CURRENT_PROJECT_VERSION`) is the UTC timestamp of the upload, so it always
  increases, and Info.plist carries the short commit SHA to identify the build. `ITSAppUsesNonExemptEncryption = NO`
  skips the export-compliance question on every build, since the app uses only the system's encryption.
- Because nothing goes through review, prefer the simplest correct configuration over App Store conventions, while
  keeping the security that matters: credentials in the Keychain and transport exceptions limited to the private
  hostname.

## Network access

The iPhone reaches the Mac's OpenCode through a **Cloudflare One route that already exists**. It is managed in the
`core-infra` repository (`cloudflare-one/`, section "Conector local do Mac e OpenCode"), not in this repository:

```text
iPhone (WARP, org alexandrerm, master@alexandrem.com.br)
  → Gateway private DNS: opencode2-mac.alexandrem.com.br → 10.203.96.2
  → private route on the macbook-pro-alexandre tunnel (cloudflared on OrbStack)
  → nginx on 10.203.96.2:80
  → loopback proxy on the Mac, 127.0.0.1:4096
  → custom OpenCode server, 127.0.0.1:4178
```

- **Address:** `http://opencode2-mac.alexandrem.com.br`, on port 80. Use the full name, not `opencode2-mac`: the ATS
  exception and DNS resolution depend on it. Port 4096 still works but exists only for compatibility.
- **Access:** there is no public DNS. Gateway allows only TCP 80 and 4096 to that IP, and only for the identity
  `master@alexandrem.com.br`. The iPhone must be enrolled in WARP (org `alexandrerm`) with that identity, and its
  device profile must include `10.203.96.2/32` in Split Tunnels.
- **Authentication:** the Mac's loopback proxy injects the server credentials, so on this route Cloudflare One is the
  only access control and the app sends no password. Basic authentication and pairing are still supported for other
  servers.
- **Preferences scope:** `custom.preferences` stores the selected repositories per server. The custom web app stores
  the server that serves it under the key `"local"`, and the app uses the same key for this route, so both share
  one selection. Pinned and muted sessions are global.
- **Transport:** plain HTTP inside the WARP tunnel. HTTP handles requests, and SSE (`/api/event`) handles live
  events. This is the server's native contract, and it already sends an SSE heartbeat every 15 seconds. The nginx on
  the route has buffering disabled, a one-hour read timeout, and WebSocket upgrades enabled. A WebSocket for events
  would require a new backend endpoint and bring no gain, so WebSocket is used only where the server already offers
  it (PTY, when terminals come into scope).
- **App Transport Security:** allow plain HTTP only for `opencode2-mac.alexandrem.com.br`, through
  `NSExceptionDomains` with `NSExceptionAllowsInsecureHTTPLoads`. Do not use `NSAllowsArbitraryLoads`. Traffic is
  already encrypted by the WARP tunnel.
- **Origin:** nginx rejects requests whose `Origin` is not on its list. `URLSession` sends no `Origin`, so do not
  add one.
- **Availability:** the route depends on the Mac being on and awake and on the OrbStack containers being healthy.
  The infrastructure manifest records that the end-to-end test over WARP had not been done yet. Before relying on the
  route, open `http://opencode2-mac.alexandrem.com.br/api/info` in the iPhone's Safari with WARP on, and confirm that
  it returns JSON.
- `https://mac.alexandrem.com.br` points to the same nginx, but it is public and protected by Cloudflare Access,
  which requires a browser login. The app does not use it.
- **Without Cloudflare One:** `opencode pair` (LAN, after `opencode service set hostname 0.0.0.0`) and
  `opencode pair --remote` (tunnel) still work and are useful for development. The Local Network permission
  (`NSLocalNetworkUsageDescription`) is needed only for direct connections over Wi-Fi.

## Backend contract

### Source of truth

- HTTP API: `packages/protocol/openapi.json`, generated from the protocol `ClientApi` by `bun run generate` in
  `packages/protocol`. Do not edit it by hand.
- TypeScript clients: `packages/client`. The Swift client is written by hand (see [API layer](#api-layer)).
- Custom plugin RPCs: `packages/plugin-app-custom/src/*/rpc.ts`, all exported from `src/rpc.ts`. **Their schemas
  are not in `openapi.json`**, so the Swift side must mirror them deliberately.
- Behavior reference: `packages/app-custom`. When in doubt about a flow (pairing, reconnecting, list refresh), copy
  the custom web app's behavior, not just its endpoints.

### Authentication

- Every route under `/api` uses HTTP Basic: username `opencode`, password = the server password **or** the session
  token obtained by pairing. Send the `Authorization` header on every request to servers that require it. On the
  Cloudflare One route, the Mac's proxy injects these credentials.
- `GET /api/info` returns `version`, `urls`, and `capabilities`. Use it as the health check and to detect an
  incompatible server.

### Pairing

`opencode pair` creates a single-use code that expires after a few minutes:

- it prints links in the form `<url>/auth/connect/<code>`;
- it shows a QR code containing `{"code": "...", "urls": ["..."]}`, with only addresses reachable from other devices
  (no loopback).

To redeem it, call `GET /auth/connect/{code}` with `Accept: application/json`. The response is `{ "token": "..." }`,
and the token becomes the Basic password. Since the code works only once, try all `urls` in parallel and keep the
first address on the list whenever it answers. This is the same strategy as `redeemPairingLink` in
`packages/app-custom/src/servers/connect/pairing.ts`.

### Location

Location-scoped endpoints receive the directory as the `location[directory]=<absolute path>` query parameter or the
`x-opencode-directory` header (URL-encoded). Without either, the server uses its own working directory.

### Events

`GET /api/event` is an SSE stream with events from **all** Locations, including `server.connected` and `rpc.*` events
from plugins. The server sends a `: heartbeat` comment every 15 seconds. The stream is volatile by contract:

- a slow consumer has its stream closed;
- events missed while disconnected are not replayed.

So:

- after every (re)connection, reload the visible state before applying incremental events;
- treat about 45 seconds without any byte (three missed heartbeats) as a dead connection and reconnect;
- on iOS the connection drops whenever the app goes to the background, so treat every return to the foreground as
  a reconnection.

### Plugin RPC

```http
POST /api/rpc/{rpcID}/{method}?location[directory]=/abs/path
Content-Type: application/json

{ "input": ... }
```

The response is `{ "output": ... }`. RPC IDs follow the `custom.<area>` pattern, for example `custom.worktrees`.

### Quick check with curl

```sh
curl http://opencode2-mac.alexandrem.com.br/api/info
curl -N http://opencode2-mac.alexandrem.com.br/api/event
curl -u "opencode:$PASSWORD" http://<host>:<port>/api/info   # servers that require a password
```

## API layer

`Codable` models and client in Swift, written by hand in `OpenCodeKit`, covering only what the app uses:

- organized by the same groups as the protocol (`session`, `message`, `permission`, `form`, `event`, and so on), and
  following the schemas in `packages/schema` and `packages/protocol`;
- tagged unions as Swift `enum`s that decode the discriminant (`type`, `_tag`) and have an `unknown` case, so a newer
  server does not break decoding;
- plugin RPCs follow the same pattern, each mirroring its `rpc.ts`;
- contract tests decode JSON fixtures captured from the real server. When the custom server is updated, capture the
  fixtures again and run the tests.

The OpenAPI generator (`swift-openapi-generator`) was ruled out. The document has about 375 `anyOf` without a
discriminator, it describes the event payload only as an opaque JSON string, and it does not include the plugin RPCs.
If manual maintenance becomes costly, the next step is to emit Swift from the same Effect contract that
`packages/httpapi-codegen` already reflects, which would also cover the RPCs.

## Notifications

Not part of the MVP. When they arrive, push notifications will come from the OpenCode backend, through a new area in
`packages/plugin-app-custom` that follows the same pattern as the existing areas (an `index.ts` that registers the
behavior and an `rpc.ts` with the contract):

1. **Registration:** the app requests permission, obtains the APNs device token, and sends it to the plugin over RPC,
   together with the APNs environment.
2. **Triggers:** the plugin observes events with `ctx.event.subscribe` (as `chats` already does) and decides what
   deserves a notification. Candidates: a session finished or became idle, a permission or form is waiting for an
   answer, and a run failed.
3. **Delivery:** the plugin calls APNs over HTTP/2 with token-based authentication (a `.p8` key, its Key ID, and the
   Team ID). The key stays in the server configuration and is never committed to the repository.
4. **Opening:** the payload carries the server and the Session, so tapping the notification opens the right session.

TestFlight builds use the **production** APNs environment (`api.push.apple.com`), while builds installed from Xcode
use **sandbox** (`api.sandbox.push.apple.com`). Store the environment with each token. Live Activity updates can later
reuse the same delivery channel.

## Technical direction

- Swift 6 with strict concurrency, SwiftUI, Observation (`@Observable`), and `async`/`await`.
- Networking with `URLSession`, including SSE (`bytes(for:)`), with no third-party networking dependencies.
- The only package dependency is Apple's `swift-markdown` (GitHub-flavored Markdown parsing for responses).
  Rendering stays in the app; adding any other dependency needs an explicit decision.
- Separate the client layer (models, HTTP, SSE, pairing, credentials) from the UI so it can be tested without the
  simulator and reused by extensions (notifications, widgets, Live Activities, share sheet).
- The server is the source of truth. The app keeps only cache and local preferences, and does not duplicate rules the
  backend already enforces.

### Project structure

A standard Xcode iOS project in Swift, committed to the repository, with no generator such as XcodeGen or Tuist. The
targets use synchronized folders (Xcode 16 and later): files added to a folder enter the target without editing
`project.pbxproj`, which avoids most merge conflicts. Code with no UI lives in a local Swift package.

```text
packages/ios-custom/
  README.md
  OpenCode.xcodeproj/
  OpenCode/              # app target: entry point, navigation, feature screens
  OpenCodeKit/           # local Swift package with no UI: API, models, SSE, pairing, Keychain
  OpenCodeUITests/       # sandbox-only native interaction/continuity tests
  OpenCodeTests/         # app-hosted UIKit key-command tests
```

## Development

- Requirements: Xcode 27.1 / Swift 6.4 and a reachable OpenCode server.
- **No CI.** Build, tests, and TestFlight uploads all run locally on this Mac.
- Development backend: an isolated custom instance created by `packages/cli/script/custom-sandbox.ts` (see
  "Isolated source development" in `docs/custom-macos.md`). `bun dev serve` is not enough, because it does not load
  the custom plugin whose RPCs the app uses. Never use ports 4096 or 4178, and **never restart an existing backend or
  proxy**, especially the one serving live sessions.
- The simulator shares the Mac's network and reaches `http://localhost:<port>` directly. A physical device uses the
  Cloudflare One route (see [Network access](#network-access)), the LAN address, or the tunnel.
- Push notifications require a physical device. Builds installed from Xcode receive notifications only through the
  APNs sandbox.
- The physical test devices are shared with other agents. Reserve one through the device lease before installing or
  driving the app, and release it when you are done.
- The committed `OpenCode.xcodeproj` has one iPhone app target (`OpenCode`), automatic signing for team
  `ERRYZ68LX5`, and a local `OpenCodeKit` package. The app uses synchronized folders; adding a Swift file does not
  require editing the project. TestFlight upload automation is not implemented yet.

### Generate themes, build, and test

Run from the repository root:

```sh
bun packages/ios-custom/script/generate-themes.ts
xcodebuild -list -project packages/ios-custom/OpenCode.xcodeproj
xcodebuild -project packages/ios-custom/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=OpenCode Sessoes' \
  -derivedDataPath /private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-sessoes-derived build
```

Run the Swift Testing suite from the package directory (no simulator required):

```sh
cd packages/ios-custom/OpenCodeKit
swift test
```

The theme script imports both custom web resolvers and generates all bundled light/dark variants under
`OpenCode/Resources/Themes`. Each file records its role-to-source-token mapping. Primary/status/accent colors use
the theme's semantic palette seeds through resolver overrides; surfaces, text, borders, icons, and filled buttons
use the resolved web tokens. Avatar hues come from the web's avatar tokens, with equal OKLCH lightness/chroma within
each mode so one repository never appears faded compared with another. There are no hard-coded colors in views.

### Dedicated simulator and isolated server

Create the simulator **once**; reuse it on subsequent runs. Do not use a physical device or an existing project's
simulator for this workflow.

```sh
xcrun simctl create "OpenCode Sessoes" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0
```

Look up the dedicated simulator by name. Boot it if it is not already running, then install and launch:

```sh
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for group in json.load(sys.stdin)["devices"].values() for d in group if d["name"] == "OpenCode Sessoes"))')
DERIVED=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-sessoes-derived
SANDBOX=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/custom-sandbox-4177
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$DERIVED/Build/Products/Debug-iphonesimulator/OpenCode.app"
SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD="$(cat "$SANDBOX/password")" \
  xcrun simctl launch "$DEVICE" br.com.alexandrem.opencode \
  -OpenCodeServerURL http://127.0.0.1:4177 -OpenCodeTheme openchamber-dark
```

To change themes, terminate **only this simulator app**, then repeat the launch with `openchamber-light`:

```sh
xcrun simctl terminate "$DEVICE" br.com.alexandrem.opencode
SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD="$(cat "$SANDBOX/password")" \
  xcrun simctl launch "$DEVICE" br.com.alexandrem.opencode \
  -OpenCodeServerURL http://127.0.0.1:4177 -OpenCodeTheme openchamber-light
xcrun simctl io "$DEVICE" screenshot /path/to/light.png
```

`-OpenCodeServerPassword <password>` is also accepted, as are the `OpenCodeServerURL` / `OpenCodeServerPassword`
environment variables (uppercase `OPENCODE_SERVER_URL` / `OPENCODE_SERVER_PASSWORD` aliases are supported).
The default URL remains `http://opencode2-mac.alexandrem.com.br`. The launch theme wins over the local
`UserDefaults` key `OpenCodeTheme`; absent both, OpenChamber dark is used. Loopback HTTP was verified in the iOS 27
simulator without an ATS exception; only the private Cloudflare hostname has an exception.

### Conversation reader verification

Append `-OpenCodeOpenSession <sessionID>` to the simulator launch to open a conversation directly. It is applied once
per app launch; Back returns to Sessões normally. Resolve current IDs from the seed manifest, not this README:

```sh
SESSION=$(jq -r '.sessions[] | select(.role == "working") | .id' "$SANDBOX/seed-conversation.json")
PRINTS=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda1
mkdir -p "$PRINTS"
xcrun simctl status_bar "$DEVICE" override --time '10:58' --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
xcrun simctl terminate "$DEVICE" br.com.alexandrem.opencode
SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD="$(cat "$SANDBOX/password")" \
  xcrun simctl launch "$DEVICE" br.com.alexandrem.opencode \
  -OpenCodeServerURL http://127.0.0.1:4177 -OpenCodeTheme openchamber-dark \
  -OpenCodeOpenSession "$SESSION"
# Wait for the transcript, then scroll or expand the desired tool before capturing.
xcrun simctl io "$DEVICE" screenshot "$PRINTS/a-dark.png"
```

Repeat with `openchamber-light`; manifest roles `permission`, `history`, and `child-0` cover the other screens. For
history, capture the initial quote, scroll up to the image/unread boundary, expand the tools and the diff/error,
then scroll to the beginning to exercise all three pages. An already-viewed session correctly has no new-message
divider on the next launch; do not move its watermark backwards or consume the pending permission/question to
recreate a screenshot. The app acknowledges only observed idle watermarks, not wall-clock time.

Waves 1–6 are complete. Wave 6's physical-keyboard path still has the manual device check described below;
its command registration, dispatch and blocked states are covered by app-hosted tests.
Child sessions have a return-to-parent action and no ordinary composer, but their
permission/question cards remain actionable. Their capsule counts the parent's other work. Colors follow the
generated web tokens, including the actual catalog's agent colors; the sandbox model is Luna 6 / low, not the
mockup's illustrative Opus model.

`ConversationStore` reads only `custom.transcript/list`, first 40 and then older 40-message pages. A recycling plain
`List` keeps native text views only for its current rows; off-screen rows release parsed Markdown and thumbnails,
retaining cheap wire values and measured heights. It preserves loaded history during tail merges, and re-reads
loaded coverage after an external revert. Paging automatically starts near the top, preserves an existing row's
screen coordinate while the new Markdown blocks are measured, and removes its small indicator after an empty page.
`EventHub` owns the one SSE connection shared
with Sessões. Screens receive decoded events with local sequence numbers: text/reasoning/tool changes batch at
32 ms; structural/terminal events and missing targets revalidate in 500 ms windows. A snapshot invalidates buffered
deltas that may already be included in it, preventing duplicate text during reconnect. Foreground returns reload.

Response text is parsed off the main actor by swift-markdown 0.7.3 into blocks and displayed by non-editable,
selectable TextKit 2 views. Each carries its message ID, type-specific part ID and rendered-to-source UTF-16 mapping.
`ResponseTextView` adds the native comment/side-question edit menu; source text remains the authority (especially for
selections spanning Markdown delimiters). Tables are deliberately simple rows, not an interactive spreadsheet; no syntax highlighting.
Images are decoded through `CGImageSourceCreateThumbnailAtIndex` at the displayed pixel size, never as full-size
bitmaps. Invalid images use a compact filename/“Imagem indisponível” placeholder. The seed image is now a valid
96×64 PNG; tests retain the old corrupt sample to verify rejection before painting.

The native pinned section header is the user bubble itself, not a duplicated overlay. It clamps to two lines only
after reaching the top. Auto-follow stops on user scrolling; the round glass button resumes following the tail.
Tests in `ConversationTests.swift` cover all 41 fixtures, paging, tool summaries/groups, model/context identity,
agent counts, replayed SSE, dates/sticky/unread/viewed decisions and Markdown source mapping. Frame-health sampling
is unavailable for iOS simulators in agent-device; do not report an inferred FPS figure.

### Conversation actions (wave 2)

- `ConversationDraft` keeps one attributed draft per session in `SessionStore.drafts`, including the pending queue
  edit and local model/agent choices. Wave 3 adds protected on-disk persistence, tokens, attachments and the `+` menu
  (details below). `ComposerTextView` is a TextKit 2 `UITextView`, growing to six lines before scrolling, with native
  selection. Dragging or tapping the transcript dismisses the keyboard; no accessory row consumes conversation
  space. Empty input shows a disabled microphone with “Em breve”.
- `PromptRequest` and `PromptSubmission` own serialization and sending. New sends have a unique `msg_` ID,
  `metadata.displayText` and `comments:[]`. Admission gets one automatic transport/5xx retry with the exact same ID;
  a failed attempt keeps the text and request for a manual retry. Steer applies agent, then model, then prompt;
  queue applies neither selection endpoint. Busy sends read `followUpBehavior`; long-pressing Send offers its
  alternate. Idle sends always steer. Queued model/agent metadata is presentation, not a per-prompt execution
  override: later delivery uses the active session selection, just like the web.
- The model sheet shows explicit `visibility:"show"` entries only and excludes disabled models. Favorites remain in
  stored order at the top and in their provider groups. Provider order follows saved ranks, then the PWA's popular
  providers, then provider name; rows sort by model name. Search mirrors the PWA's Unicode letter/number normalization,
  substring and no-spaces matching across model name, ID and **provider name**. Effort uses the model's real variants.
  Stars mutate `model.favorite` without making hidden models visible. A row's swipe/context menu sets or clears
  `model.default` with its variant; a badge and a separate Clear action identify the default for new sessions.
  `Gerenciar modelos` lists every enabled model, including hidden search results. Model/provider switches send
  `model.visibility` intents; provider switches affect **all** enabled models of that provider, not only search matches.
  Mutations retain the newest acknowledged preference revision while SSE snapshots catch up. The agent menu lists
  non-hidden primary and `all` agents. A session without a selected model uses preferences/default-model discovery.
- The tray has Stop (`resume=true`), conditional Background and queued user items. Pending request cards take its
  running row's place while the session waits for you; queued items remain available. Editing submits a replacement
  ID before cancelling the original; no text PATCH or ID reuse is attempted. All inbox events revalidate the tray.
- Permission decisions are once, reject, and explicit always (the small `…` or long press), sent to the request's
  actual owner. Question cards use option values, support multiselect and custom text, omit hidden/inactive fields,
  and dismiss with DELETE. Sending a normal prompt never answers a form. Generic non-question forms and field types
  other than string/multiselect are not implemented by this wave and are identified as unsupported rather than
  silently interpreted. Pending tool lines show “Aguardando permissão/resposta” without a ticking elapsed timer.
  Questions use the info role for their icon/title/border and pending tool line; permissions retain the error role.
- The agents sheet and header share one running-work projection. It excludes foreground shells and the viewed
  child, opens real child IDs, reveals a background shell's tool (expanding its group), and confirms individual
  interruption, with a visible stop button as well as trailing swipe/context actions. Wave 3 sizes the sheet from
  its measured rows. It colors the agent name and keeps elapsed time on the row. Context details start at medium height and expand
  to large; they use the last measured assistant and its model, with token components, cache hit,
  session/descendant/total cost, model/provider, branch and directory. No extra child transcript is fetched for usage.
- The transcript is still a recycling `List`. An empty older-page response no longer keeps a top anchor during
  initial Markdown measurement; active tail-following does not acquire a history anchor. No off-screen parsed text,
  image or UIKit view cache was added by the action cards.
- `ToastCenter.show(_:kind:)` and `.toastOverlay(_:)` are the shared feedback API for later waves. The glass capsule
  sits below the conversation/sheet header, replaces the preceding toast, announces through VoiceOver and dismisses
  after four seconds (six for errors). Copy response/code/diff, sending failures, request replies, queue operations,
  interruption/background and model preference changes all use it. Failed drafts retain their persistent error too.

The Swift Testing suite includes `ConversationActionTests.swift`: wire bodies and HTTP methods/owners, admission
retry identity/order, queue replacement/failure, permission and form responses including dismissal, visibility and
favorites, running-work rules, context math and pending tool labels. The review adds the exact PWA search cases,
provider ordering and all three model preference intent encodings. There are 57 tests across the package.

Wave 2 was built without new warnings and exercised against port 4177: idle/busy and alternate submission, model and
effort selection, a primary-agent switch to `utra` on send, queue edit/promote/remove, Background, root/child/shell
interruption, once/reject/always permission decisions, question answer/dismissal, child navigation and context
details. Prompt executions used only `llm-proxy/gpt-6-luna` / `low`. The conversation seed was recreated with
`seed-conversation.ts --reset` after the action checks; no Sessões request was consumed. Simulator evidence for both
themes lives in `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda2/`:
`a-{dark,light}.png`, `b-{dark,light}.png`, `d-{dark,light}.png`, `models-{dark,light}.png`,
`effort-{dark,light}.png`, `agents-{dark,light}.png` and `context-{dark,light}.png`.
`context-info-{dark,light}.png` shows the lower cost/model/directory section. Review evidence adds
`models-search-{dark,light}.png`, `models-manage-{dark,light}.png`, and `toast-{dark,light}.png`.
The sandbox is deliberately left with Luna 6, Luna 6 - fast, Anthropic Haiku 5.5 and Opus 5.5 visible, Luna 6 favorited,
and Luna 6 / low the default for new sessions, all configured through the native UI. Other servers' preferences are
unchanged. The three obsolete debug captures were deleted. Error toasts were exercised with genuinely stale B/D
requests (only those owned seed sessions were deleted); `seed-conversation.ts --reset` now skips already absent
manifest members so this verification remains safely repeatable.

“Permitir sempre” persists a **project** permission, not a session-only choice. Before resetting its test, list
`/api/permission/saved?projectID=<conversation-project>` and remove only the exact newly created test rule via
`DELETE /api/permission/saved/<id>`; never clear shared rules indiscriminately. Otherwise a fresh B can finish
without asking and the seed's readiness wait times out. The wave-2 test's own rule was removed before the final
reset. During the first wave-2 capture, one restored Explore child finished with “Não encontrei uma ferramenta shell
disponível” after a tool-catalog rescan. The capsule always reflects actual runtime activity rather than fabricating
the intended two tasks. The root shell, queue, B's permission and D's question are restored for final captures.

### Advanced composer (wave 3)

- `ComposerDocument` / `ComposerSpan` model the plain display text plus typed token ranges in UTF-16. The TextKit 2
  editor retains encoded token attributes, snaps the caret out of tokens and deletes an intersected token as a unit.
  Raw trigger text remains plain text. `ComposerTrigger` recognizes word boundaries; `/` is only active at offset 0.
  Space, Escape and a tap in the transcript dismiss suggestions. Trigger queries disable autocorrection,
  autocapitalization and predictive suggestions; prose restores the keyboard defaults. Unselected correction
  ranges cannot replace a token.
- `ComposerSources` merges files, recent root sessions, mentionable agents and visible references for `@`; supported
  local commands plus backend commands and noncolliding slash skills for `/`; skills for `$`; project-over-global
  case-insensitive snippets (including aliases) for `#`. File/session searches debounce 180 ms and cancel stale reads.
  The glass panel highlights the first result, groups by source and has explicit empty/error states. Catalog
  descriptions retain their server-provided language; native labels are pt-BR. Apps and MCP resources are omitted.
  Across sources, name/ID/alias prefixes rank before name substrings, then description-only matches. File basenames
  participate in name ranking. Equal-ranked items retain their catalog order, and section headings never move
  description matches ahead of name matches.
- `PromptRequest(document:…)` normalizes newlines, expands snippets and adjusts later mention offsets, adds session
  reference instructions and `metadata.sessions`, and sends URI-only files, agents and skills. `displayText` remains
  the typed text, `comments:[]` is retained, and additive `metadata.composerTokens` restores native token styling in
  drafts/queued edits/sent bubbles. Directory references use file URIs. Backend command tokens dispatch to `/command`
  with argument-relative mentions, without an automatic retry (that endpoint has no idempotency key). Slash skills
  remain prompts. `/model` and `/agent` open local pickers; `/compact` admits manual compaction. Unsupported client
  commands and shell mode are not advertised. Ordinary prompt admission retains the wave-2 exact-ID retry, including
  when only the cursor moved after a failed send.
- `+` → **Imagens e arquivos** opens the system multi-photo or document picker. Images are decoded off the main actor;
  HEIC/HEIF becomes JPEG and oversized supported images are scaled to a maximum side of 2048 px. Every blob is staged
  as raw bytes under the server's `paths.tmp/uploads/<uuid>/<name>`. PNG/JPEG/GIF/WebP/PDF additionally travel inline
  only up to 20 MiB and when the selected model advertises the matching input. Other files remain path references
  with `Attached file: …` and `metadata.attachments`. Chips show a bounded thumbnail or file icon, filename and remove
  action; preparation/upload progress and failures use the shared toast. No camera, paste or drag/drop was added.
- The small, muted in-card expand button (over three lines or with attachments), `+` menu and upward swipe open the same composer UI full screen, with the same draft,
  attachments and selection controls. Recollection preserves cursor and tokens. An explicit editor owner prevents
  the outgoing sheet and incoming compact editor from competing for first responder during the transition.
  The full-screen editor has one collapse control in its header; neither editor has a keyboard accessory row.
- `DraftPersistence` stores JSON and separate attachment files under Application Support, keyed by the server URL
  hash and session ID, using atomic writes and iOS file protection. Writes debounce 250 ms and flush on leaving or
  backgrounding. Model/effort/agent, cursor and pending queue replacement ID are retained. Attachments are capped at
  25 MiB total per draft; missing/oversized restored bytes are dropped with a toast. Removing/sending cleans bytes;
  launch cleanup deletes a session's draft only after an authoritative HTTP 404 (not a missing navigation row).
  Materialized inline files restored from the queue become local bytes again, never invalid prompt-input objects.
- The model picker uses only the “Padrão” badge (no extra pin icon), and the running-agents sheet follows its content.

`ComposerTests.swift` adds trigger, catalog filtering/precedence, UTF-16/emoji/accent/newline serialization, snippet
offset shifts, command/skill dispatch, session instructions, inline/staged attachment rules, real image downscaling,
raw upload/command HTTP bodies, materialized queue restoration, suggestion ranking and protected-draft round-trip/cleanup tests. The package has 76 tests.

Verification uses only the dedicated **OpenCode Sessoes** simulator and port 4177. A separate session in the fake
conversation repository sends the file, agent, session, skill, snippet and attachment probes, runs
`conversation-review` and `/compact`, and remains available for inspection. The Photos probe is a generated 600×400
PNG added with `simctl addmedia`; the text file is selected through the real document picker. The conversation seed
is reset with `seed-conversation.ts --reset` before final captures; no Sessões request is consumed. Evidence for both
themes is in `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda3/`:
`context-*`, `commands-*`, `skills-*`, `snippets-*`, `menu-*`, `attachments-*`, `fullscreen-*`, `restored-*`, `sent-*`.
`agents-fit-light.png` and `default-badge-light.png` cover the two wave-2 review fixes. The C draft is kept local and
unsent during review; the separate verification session is idle. The composer review adds `long-draft-*` and
`keyboard-*` and refreshes all four trigger panels and `fullscreen-*` without a keyboard accessory row.
Native keyboards and system picker presentation deliberately replace the mockup's illustrative keyboard.
Token backgrounds use attributed text highlights rather than a separately drawn rounded chip view.

### Selection (wave 4)

- Assistant text blocks use `UITextViewDelegate.textView(_:editMenuForTextIn:suggestedActions:)` to retain the system
  edit menu and add **Comentar** and **Pergunta paralela** after Copy. Code, tools and user bubbles do not get these
  actions. UIKit derives the translucent selection from the theme's primary tint. A `ChatQuote` maps the rendered
  range through `MarkdownBlock` to exact source UTF-16 offsets, with the stable message/part IDs and the exact source
  substring. Identity/content changes and dismantling clear selection, source and callbacks; no off-screen text cache
  or additional SSE stream was added. Selection is bounded to one rendered Markdown block, as in the wave-1 renderer.
  Both TextKit subclasses use the designated initializer: UIKit's `textViewUsingTextLayoutManager` factory bypasses
  Swift subclass property defaults. The designated initializer retains the platform's TextKit 2 default.
- **Comentar** presents a native sheet with a read-only passage, token-capable comment editor, Concluir and Remover.
  In comments, `@`, `$`, and `#` work as in the main composer; `/` does not, as in the web.
  A sandbox UI/server check selects a file, Explore, the fixture skill and `#resumo` in the real comment editor,
  concludes, relaunches, then sends with a short main text/file mention. The comment's file/agent/skill arrive in
  structured arrays without main-text ranges; the main file keeps UTF-16 range 33–47. The model-facing `User comment:`
  expands `#resumo`, while the sent bubble preserves the authored token text. Sessions/references and snippets in
  comments also have package tests. Evidence: `comment-tokens-panel-*`, `comment-sent-*` and the sanitized
  `comment-server-verification.json` in the wave-6 final screenshots directory.
  `Citações · N` is collapsed by default above the composer card and expands to edit/remove individual quotes.
  Quotes survive relaunch through `DraftSnapshot` (old wave-3 snapshots decode with an empty quote array), restore
  from queued messages, count as sendable content on their own, and clear only after successful submission.
  Comments support the existing `@`, `$` and `#` suggestions; there is no separate binary-attachment picker in a comment.
- `PromptRequest(document:…quotes:)` emits the web's `metadata.quotes` and `commentPrompt` ComposerPart shapes, keeps
  `displayText`/`comments:[]`, and appends `Comments on earlier assistant messages:` after the main text/context.
  Comment file/agent/skill tokens travel without `mention` ranges; main offsets remain untouched. Snippets expand
  only in the model-facing comment. Restored web quote attachments retain their quote ownership in the protected
  draft; inline files follow main files in quote/part order and staged files stay referenced inside their quote.
  The sent bubbles reuse the existing quote presentation with aligned side bars.
- **Pergunta paralela** is a medium/large glass sheet. Selection prefills the blockquote; `/btw` suggestions open the
  same sheet, and submitting `/btw <question>` sends the first local question immediately. It shows the committed
  session model, not an unsubmitted composer selection. Answers use the response Markdown renderer, with copy.
  `SideQuestionRequest` carries exactly the web instruction prefix and at most five completed local Q&As, capped at
  1,000/3,000 UTF-16 units (without splitting a surrogate). `POST /generate` is JSON, never a durable prompt or SSE.
  Parar cancels only its URLSession task and restores the question; closing discards the thread. Failure has both a
  retryable shared toast and a local retry button.
- A native `UIContextMenuInteraction` overlay handles **Copiar** and **Copiar citação** even in List's sticky section
  headers, where SwiftUI's `contextMenu` does not install an interaction. Copiar uses only `displayText`; the quote
  action copies blockquoted passages and comments. Both confirm through the shared toast.

`SelectionTests.swift` covers plain/emphasis/code/link/list/accent/emoji source mapping, generated markers, quote
wire metadata and exact appended block, comment mentions without shifted main offsets, quote-only messages, snippet
comments, inline quote file order/staged delivery, protected-draft round trips and backwards compatibility,
`/btw` prefix/history/truncation/HTTP, and user copy. The package has **85 tests**, all passing. The simulator build
introduces no warnings.

Live checks used only the dedicated simulator and sandbox 4177. The separate session
`ses_e9f6a2ed3ffeA7XsEWNVj4NTVK` (Onda 4 — seleção e perguntas) contains the two-quote/text and quote-only sends,
both confirmed through `custom.transcript/list` with exact metadata/appendices and rendered bubbles. All calls used
Luna 6 / low. A B draft with one quote/comment and main text survived termination/relaunch and remains unsent locally.
The B and verification-session transcripts were compared before/after side questions and stayed identical (6 and
11 messages respectively); the stop check restored its unsent question with no answer. Clipboard contents were read
back for both user-copy actions. No seed prompt, inbox or request was changed, so no seed reset was needed; B's
permission and D's question remain pending. Screenshots in both themes:
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda4/`, files
`selection-*`, `comment-*`, `quotes-collapsed-*`, `quotes-expanded-*`, `sent-*`, `side-empty-*`, `side-loading-*`,
`side-answer-*`, `btw-suggestion-*`, `user-menu-*`; `side-stopped-dark.png` adds cancellation evidence.

For wave 7: preserve the quote array in `DraftSnapshot` and the exact-ID failed-send comparison, the rendered/source
mapping, recycling timeline and shared SSE hub. File
review comments are still separate from chat quotes and are not exposed by this screen. A failed backend command
cannot be retried exactly-once; do not imply otherwise in its UI. The microphone remains visual only.

For memory checks, build with `-configuration Release`, install `Release-iphonesimulator/OpenCode.app`, and run
`vmmap -summary <app-pid>` after Sessões settles, after opening C's tail, at the first history page, and after returning
to the tail. The app PID is printed by `simctl launch`. Compare **physical footprint**, not just `ps` RSS, which
includes shared framework pages. On the dedicated simulator the review measured 45.3/64.0/66.2/73.7 MiB before
recycling and 45.8/62.1/61.6/62.9 MiB after it; another full round trip reached 63.5 MiB. No simulator FPS claim is
made. Scope includes only the 89-message seed; the native recycling container, not a guessed per-message slope, is
the protection for longer sessions.

### Session and reading (wave 5)

**Status: complete, awaiting screenshot review.** The native `…` menu offers search, rename, session details and,
only on roots, archive. Rename uses a native text-field alert, trims empty/unchanged values, optimistically updates
the header and rolls back on failure with the shared toast. `PATCH /api/session/{id}` emits the existing events that
refresh Sessões. Archive reuses `custom.archive/archive` and the Sessões confirmation, then returns with a toast;
the backend owns interruption and cascading to descendants. Neither action retries automatically.

- The medium/large details sheet joins the existing project catalog and `custom.worktrees/locate` checkout root.
  It reads `/api/vcs`, `/api/vcs/diff?mode=working`, `/api/mcp`, `/api/plugin`, `/api/skill` and `/api/config` with the
  session's Location. The +/− is **current working-copy changes**, as on the web, not a sum of historical tool edits.
  Built-in plugins are omitted. Independent read failures say **Indisponível**, never “none”. LSP shows merged
  configuration only, explicitly identifying runtime connection status as unavailable. Usage links to wave 2.
- `ConversationSearch` searches raw user text and assistant text parts in loaded sequence/part/occurrence order,
  excluding reasoning and tools. Literal non-overlapping matching folds case and accents and retains original
  UTF-16 ranges, including emoji. Source ranges map onto visible Markdown runs for translucent primary highlights;
  Markdown punctuation remains part of the searched source, like the web. A `UISearchTextField` replaces the header,
  with Cancelar, a `3 de 12` counter and previous/next controls above the keyboard. Older search explicitly loads at
  most three pages per attempt, stops at the first page with new matches and can be cancelled. Navigation wraps the
  loaded matches. There is no server-side full-transcript search or off-screen parsed-text cache.
- Search reuses `revealMessage(_:offset:persist:)` with `persist: false`. A visible TextKit occurrence refines the
  message-relative offset after materialization. Explicit navigation still wins over restoration and tail-following;
  closing preserves the current screen position but leaves the saved bookmark unchanged until a real user scroll.
  Normal transcript/runtime publication stays atomic so restoration cannot lose concurrently prepended pages.
  Markdown parsing restarts explicitly when a recycled row reappears with unchanged text after releasing its blocks;
  the regression suite caught a blank-row case when returning from historical reading to the tail.
- V2 **removed `todowrite`**, with no replacement. No task-list feature or model probe was added. All its historical
  parts, including failures, are suppressed in rendering, step counts/kinds and final-answer activity projection.
- Missing/non-string `/api/info.version` produces the incompatible-server notice and retry, including on Sessões
  when a legacy server cannot open a conversation. No app/server semver equality is assumed. A missing directory is
  established only by `custom.worktrees/available == false` (queried in the default Location) or a matching typed
  `LocationNotFoundError`. Arbitrary 404s/network errors are not misclassified. History remains readable and the
  composer is replaced by an explanation; retry rechecks availability. Choosing/moving directories remains out of scope.

`SessionReadingTests.swift` in OpenCodeKit covers matching, source highlights, order/counter, the older-page budget,
rename/rollback, removed tools, HTTP methods/Location scoping, independent service errors, LSP precedence and notice
classification. The package has **106 passing Swift tests**. The warning-free simulator build and four app-hosted
tests pass. The existing seven UI cases pass with the expected already-viewed unread skip; the four new Wave-5 UI
cases pass in both themes, including the Sessões rename event, root/child details, two-page older search, an unchanged
saved tail bookmark after closing search, archive and a real removed test directory. UIKit's Unicode `typeText` can
hide the Simulator keyboard: the rename test restores it before resolving the alert button's shifted frame.

Run `python3 packages/ios-custom/script/test-session-reading.py` after `xcodebuild … build-for-testing`; set
`OPENCODE_TEST_THEME=openchamber-light` for light. It uses only the dedicated Simulator and explicit sandbox-4177
arguments, imports its own disposable sessions, archives only its own root, renames/removes only its own empty
directory, and never calls a model or answers a seeded request. No conversation seed reset was needed: transcripts,
inboxes and pending requests were unchanged. Ordinary viewed acknowledgement is intentionally not rolled backwards.

Evidence: `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda5/`:
`menu-*`, `rename-*`, `renamed-list-*`, `archive-confirmation-*`, `archived-toast-*`, `details-*`,
`search-results-*`, `search-older-offer-*`, `search-older-result-*`, `search-closed-position-*`,
`missing-directory-*` and `verification-openchamber-{dark,light}.json`. Both themes use the 10:58 status bar.
`incompatible-component-{dark,light}.png` are app-hosted renders of the **real notice component**, driven by a
version-less info response in a test transport; they are not claimed as live incompatible-server screenshots.
The actual sandbox remains V2-compatible and was never modified/restarted to manufacture that condition.

For wave 7: retain the non-persisting search request, the Location notice's send guard, atomic initial publication,
recycled Markdown lifetime and the single shared SSE hub. Enabling the child composer must not enable archive on
children or bypass a server/directory notice. Reuse `SessionStore.toast` for feedback after returning to Sessões.

### Reading continuity (wave 6)

**Status: complete.** The package's 95 Swift tests, three app-hosted tests and simulator build pass without new
compiler warnings. The enabled `testHistoryNavigationAndRelaunch` checks five reopenings plus cold relaunch in each
theme, including an anchor outside the initial tail page. Every measured difference is 0 points (dark: floating-point
noise below `0.000001`), with 0 growth across cycles, inside the 24-point acceptance bound. The full native suite has
nine passing tests and one expected unread skip after its watermark has already been acknowledged.
App-hosted `OpenCodeTests/ComposerKeyCommandTests.swift` checks hardware Return registration and actual UIKit action
dispatch, including suppression during sending, marked text, suggestions and auxiliary editing. The physical-keyboard
path still needs a **manual check on a device**: XCUITest does not deliver hardware Return in this Simulator setup.
The shared Simulator keyboard settings are never changed. Actual software-keyboard taps verify the private path.
`OpenCodeTests/ReadingGeometryTests.swift` also checks the real native-cell/zero-size-probe boundary and correction
against a captured viewport origin.

- `ConversationProjection.finalAnswerDividers(_:)` is a pure projection across each user group. It considers only
  rendered activity, completed error/retry-free `stop` assistants, explicit `final_answer` phases and the legacy
  first-text-of-last-message fallback. Each eligible sequence can have its own divider, including in history.
  The 1-point full-width line uses `borderStrong` from `v2-border-border-strong`, has 12 points below it and is hidden
  from accessibility. Text/part IDs, selection and quote source mapping are unchanged.
- `SessionStore.reading` owns a separate `ReadingPositionStore`: the same URL hash as drafts, then session ID (no
  directory or credentials). Up to 200 LRU entries contain only follow-tail intent or a message ID/point offset and
  update time. Protected JSON in `Application Support/OpenCode/Reading` uses atomic writes. Scroll-idle capture
  debounces 250 ms; leaving, opening a child and backgrounding flush immediately. A weak map of **mounted** UIKit row
  probes measures partially visible responses and natural user bubbles below the actual sticky header.
  Probe views identify their current recycled cell, but geometry comes from the native cell's bounds: a SwiftUI
  background representable can be zero-sized or inset and must not stand in for the message rectangle. The position
  also records the captured usable-top edge (`viewportTop`) so natural/pinned header transitions do not redefine the
  coordinate origin when reopening; old JSON without that optional field still decodes.
  Restoration and layout never recapture their own geometry: only real user scrolling or an explicit new target may
  change a bookmark. Negative offsets are real gaps before a message and are preserved, not clamped to an arbitrary
  negative limit. That former `-32` clamp caused a systematic upward shift when a captured gap was larger.
- Saved anchors suppress the initial tail jump and live following. Restoration loads at most five older pages per
  attempt, offers **Retomar leitura** beyond that budget, materializes the message and corrects its offset using real
  Markdown/image geometry. User interaction cancels it; a missing message after exhausting history falls back to the
  tail. Layout changes retain the anchor and clamp the offset to the measured message height. New messages do not
  steal a non-following position. The app's existing portrait-only orientation policy is unchanged.
- **Wave 5 API:** `ConversationStore.revealMessage(messageID, offset: 0)` requests explicit navigation through the
  same cancellable path, taking priority over saved position and tail. Search may page its own results before calling
  it. A new request has a fresh token even for the same message. Tool reveal also pauses following and expands the
  actual group. Do not overwrite the reading store or the viewed watermark to navigate.
- The entire composer/quotes/tray/queue region is a real sibling below the recycling List, not a bottom overlay.
  Its measured layout always reduces the transcript viewport, including while the keyboard is shown. A non-empty
  response selection pauses following until **Ir para o fim** is tapped. **Novas mensagens ↑** is an explicit jump
  when the captured unread boundary is above the viewport; it does not change viewed acknowledgement semantics.
- Step/detail expansion is stored as IDs and explicit booleans in a separate 16-session memory LRU. Outputs, parsed
  Markdown, images and views are never cached there. The native edge-pop recognizer is enabled for the hidden-bar
  conversation, with root/transition guards and its previous delegate restored on departure.
  The pinned bubble's native background is opaque and full width, with only a 14-point bottom gradient; no inset
  material/rectangle is painted over the code block beneath it.
- Return inserts a newline; **Shift+Return sends** through the button's exact predicate/action in both main composer
  sizes. Hardware uses a priority `UIKeyCommand`; software consults the keyboard **before mutation**. Suggestions and
  marked text take precedence. The side-question editor has its own submit action; comment editors have no submit
  shortcut. `SoftwareKeyboardShift.swift` alone resolves private `UIKeyboardImpl` state at runtime, checks selectors
  and calls BOOL getters with their proper signature. Automatic Shift, Caps Lock and unavailable state all fall back
  to a newline. **Private API warning:** internal TestFlight still processes the binary and may reject this with
  `ITMS-90338`; remove that file/software path and retain hardware Shift+Return if that happens. Third-party keyboards
  and future UIKit versions have no guaranteed private-state contract.

Swift Testing adds divider sequences/eligibility/history/visibility, partial-row capture, restoration decisions,
protected serialization/server separation/LRU, expansion memory and all Shift-state/editor-state combinations
(`ReadingContinuityTests.swift`). Run `swift test` from `OpenCodeKit`. The `OpenCodeUITests` target drives
the actual software keyboard keys, five repeated navigation cycles plus cold relaunch, comment tokens and expanded
quote layout. Hardware actions are checked in the app-hosted `OpenCodeTests` target. After
`xcodebuild … build-for-testing`, run `python3 packages/ios-custom/script/test-reading.py [testMethod …]`. It only uses
the dedicated simulator and port 4177, creates/deletes isolated Luna 6 / low keyboard sessions, reads the sandbox password without
printing it and removes its protected temporary xctestrun configuration. Never launch the app without explicit
`-OpenCodeServerURL http://127.0.0.1:4177`, including in automation relaunches.
The scheme's test action also has the explicit sandbox URL, including the app-hosted target. The runner serializes
the dedicated Simulator and uses uniquely named, private xctestrun files. Select hosted tests with, for example,
`python3 packages/ios-custom/script/test-reading.py OpenCodeTests/ComposerKeyCommandTests`.

Run `testUnreadJump` immediately after `seed-conversation.ts --reset`; later opens correctly have no unread boundary
after viewed acknowledgement, so that case skips rather than moving the watermark backwards. The B seed now includes
one imported read before its existing Markdown answer: the former simple reply correctly had no final divider and
could not exercise the requested after-tools screenshot. No web/backend implementation or Sessões request changes
are needed. Wave 7 should keep child navigation on this same reading/expansion store and reuse the optional editor
submit action instead of adding a second keyboard handler.

Verified on **OpenCode Sessoes / iOS 27.0** with the clean 10:58 status bar, against sandbox 4177 only:

| Input on the real software keyboard | Result |
| --- | --- |
| Return after prose | Newline; no send |
| Return with automatic sentence capitalization | Newline; no send |
| Caps Lock, then Return | Newline; no send |
| Manual Shift, then Return | One send; no newline |
| Hardware Return + Shift | App-hosted action test; physical keyboard remains a manual device check |

Live evidence is under
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda6/final/`:
`b-final-divider-*`, `c-original-*`, `c-cycle-{1…5}-*`, `c-after-relaunch-*`,
`c-sticky-code-*`, `c-reading-comparison-*`, `comment-tokens-panel-*`, `comment-sent-*`, `b-expanded-quotes-*`, `expanded-before-child-*`,
`expanded-after-child-*`, `expanded-reopened-*`, and `keyboard-*`. The history test compares the same anchor passage
within 24 points of the original and allows at most two points of range across five reopenings plus cold relaunch.
Both root and child edge swipes are
exercised. The conversation seed was reset before final captures; B's permission and D's question remain pending,
and keyboard-test sessions are deleted by the runner. The B quote remains an unsent local draft.
The side-by-side comparisons show the original, fifth visit and cold relaunch. Stale unthemed duplicates and the old
boxed-header captures were removed from `final/`. The conversation seed's transcript/requests were not changed by
this iteration; only separate disposable verification sessions received the tiny Luna 6 / low prompts.

### Live data and contract fixtures

`SessionStore` is main-actor `@Observable` state. `OpenCodeKit` owns Codable wire models, HTTP/Basic authentication,
SSE framing, root-family rollup, attention, recent ordering, preview extraction, and pt-BR timestamps. The UI owns
only presentation and client-side filters.

- Navigation is paginated at 500. Pins/mutes match a session ID across all stored server keys, including legacy bare
  IDs. New entries use the Mac web app's `JSON.stringify(["http://localhost:4096", sessionID])` key; removing a pin or
  mute removes every matching entry. Repository selection remains under `projects["local"]`.
- Requests use the global `custom.requests/permissions` snapshot and `/api/form` only for directories with pending
  questions. This avoids loading every Location. `custom.session-family/snapshot` is mirrored in the client but is
  not required by this screen.
- Branches are loaded in one `custom.worktrees/locate` call, without booting each repository's Location.
- `custom.navigation` excludes archives by contract. The archived list pages root metadata from `/api/session` and
  retains only archived sessions; it never loads their transcripts.
- Previews use only `custom.transcript/list` (three messages, at most four concurrent reads), never the native message
  endpoint. Streaming text/tool events debounce preview refreshes; structural events invalidate the snapshots.
- Each SSE connection and foreground return reloads the snapshots. URLSession's 45-second no-data timeout includes
  heartbeat bytes; reconnects back off from one to fifteen seconds. SSE is framed from bytes because Foundation's
  `AsyncBytes.lines` drops the empty lines that delimit events. Full event-triggered reloads are coalesced into
  trailing 1.5-second windows; changes during a reload schedule another window. Preview refreshes retain their
  separate 250 ms debounce. Quota reads are limited to once per minute when refreshing. There is no offline editing
  or push notification handling yet.
- Theme roles are typed as `ThemeRole`; every role and avatar is validated when loading a generated theme. An
  incomplete or invalid theme falls back to bundled OpenChamber dark.

Capture sanitized fixtures from the running isolated server without logging its password:

```sh
OPENCODE_SERVER_PASSWORD_FILE="$SANDBOX/password" \
  bun packages/ios-custom/script/capture-contracts.ts http://127.0.0.1:4177
```

The fixtures cover navigation, preferences, projects, active sessions, permissions, forms, archived metadata,
subscriptions, and running/image/user transcript previews. Local paths and account addresses are scrubbed.
Re-run `swift test` after recapturing. The seed belongs to the backend development workflow; the app never starts,
stops, resets, or seeds a backend.

For the conversation waves, see [`docs/conversation-contract.md`](docs/conversation-contract.md). Create the separate
conversation seed with `bun packages/ios-custom/script/seed-conversation.ts`, then capture its contracts with
`bun packages/ios-custom/script/capture-conversation.ts`. Both verify sandbox ownership and reject production ports.
The seed manifest is `<sandbox-home>/seed-conversation.json`; `--stop` interrupts only its sessions and `--reset`
recreates only those sessions. The capture writes `Fixtures/Conversation/`, including one real short SSE execution;
`--snapshot-only` refreshes snapshots while reusing that recording, without calling a model. The existing Sessões
seed and its pending requests are not consumed.

### First-screen verification

The first implementation was built and exercised on the dedicated iOS 27 simulator in both OpenChamber modes.
Pin/unpin, mute/unmute, status/repository filtering, repository reordering, and mark-all-read were checked against
the live sandbox. Repository removal/addition and external preference changes over SSE were also verified. The
permission/question seed is not consumed by these checks. Native menus, swipe actions,
confirmation dialogs, archived navigation, and the native conversation reader are retained rather than drawing
mock replacements. New session, voice, selection, settings, the master-session accessory, and the other tabs remain
visual-only as specified.

## Open decisions

- **MVP scope after the first screen:** which of the other [Goals](#goals) go into the first TestFlight build.
  Notifications are already out.
