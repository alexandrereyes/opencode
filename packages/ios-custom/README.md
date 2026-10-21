# OpenCode iOS (custom)

Native iOS client, written in Swift, for the OpenCode backend. It talks to the same server as the TUI and the custom
web app (`packages/app-custom`), and adds no separate backend of its own.

The goal is to replace the custom web app on the phone, where it runs today as a PWA, with a native experience. It
will grow feature by feature until the phone no longer needs the web app. Other form factors (iPad, Mac) may follow
later.

This is a personal app. It is distributed only through a private TestFlight (internal testing) and will never be
submitted to the App Store.

> **Status:** first screen in progress. The first deliverable is the "Sessões" screen (see
> [First screen: Sessões](#first-screen-sessões)), together with the Xcode project and a minimal `OpenCodeKit`.

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
  a session (a provisional screen for now), Permitir/Negar, archive, pin, mute, "Marcar todas como lidas",
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
  OpenCodeTests/
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

### First-screen verification

The first implementation was built and exercised on the dedicated iOS 27 simulator in both OpenChamber modes.
Pin/unpin, mute/unmute, status/repository filtering, repository reordering, and mark-all-read were checked against
the live sandbox. Repository removal/addition and external preference changes over SSE were also verified. The
permission/question seed is not consumed by these checks. Native menus, swipe actions,
confirmation dialogs, archived navigation, and the provisional session screen are retained rather than drawing
mock replacements. New session, voice, selection, settings, the master-session accessory, and the other tabs remain
visual-only as specified.

## Open decisions

- **MVP scope after the first screen:** which of the other [Goals](#goals) go into the first TestFlight build.
  Notifications are already out.
