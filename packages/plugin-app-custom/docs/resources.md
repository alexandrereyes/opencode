# Session resources

Simulators, emulators and browsers that agents use on the Mac, listed per session in the iOS app and viewed or
controlled from it, also with the Mac locked. This document is the contract the plugin, the hub, the adapters and
the iOS app share. Change it only compatibly (new optional fields, new kinds, new routes) and update this file with
the change.

Architecture after t3code (`pingdotgg/t3code` rev `5b35402`, `docs/internals/devices.md`,
`apps/server/src/device/DeviceHubProxy.ts`, `apps/server/src/preview/ServerBrowserStream.ts`).

```text
iPhone ──WARP──▶ nginx 10.203.96.2:80 ──▶ 127.0.0.1:4096 proxy.mjs ─┬─▶ 127.0.0.1:4178 server (+ plugin)
                                                                    └─▶ 127.0.0.1:4179 resources hub   (/resources/*)
plugin (every Location) ──loopback, bearer secret──▶ hub /admin/*
```

## Pieces

| Piece      | Where                                                               | Role                                                                                          |
| ---------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Contract   | `src/resources/rpc.ts`, `src/resources/protocol.ts`                 | Resource shape, RPC, stream/input wire protocol                                               |
| Plugin     | `src/resources/index.ts`, `lock.ts`, `supervisor.ts`                | `custom.resources` RPC, control lock in `execute.before`, relays hub events, starts the hub   |
| Hub        | `src/resources/hub/`                                                | Separate Bun process: registry, locks, tickets, probes, shared streams, input                 |
| Adapters   | `src/resources/adapters/<kind>.ts`                                  | One per kind: liveness, snapshot, stream, input                                               |
| iOS mirror | `ios-custom/OpenCodeKit/Sources/OpenCodeKit/SessionResources.swift` | Codable contract, RPC calls, hub URLs                                                         |
| iOS viewer | `ios-custom/OpenCode/SessionResources/`                             | Shared shell (`ResourceViewer.swift`, model, touch surface, keyboard) and one folder per kind |

## Resource

`Resources.Resource` (`rpc.ts`):

| Field                                     | Meaning                                                                                                                                                                                   |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`                                      | `<kind>:<native id>`: `ios-simulator:<UDID>`, `android-emulator:<AVD or serial>`, `chrome:<playwright session or CDP endpoint>`                                                           |
| `kind`                                    | `ios-simulator`, `android-emulator`, `chrome` (clients must tolerate unknown kinds)                                                                                                       |
| `label`                                   | Display name derived from `meta` (`iPhone 17 · OpenCode Salto Turno`, `Pixel 9 · abacato v2`, `localhost:5173/login`) unless registration named it                                        |
| `purpose`                                 | Optional, from explicit registration                                                                                                                                                      |
| `owner`                                   | `{ sessionID, rootSessionID, agent? }`: the session whose tool call used it (a subagent's own session) and the family's root; lists group by root and show "via <subagente>"              |
| `state`                                   | `user` (Alexandre controls it) › `agent` (used in the last 90 s) › `live` (running, used in the last 10 min) › `idle` ("Livre") › `stopped` › `gone`                                      |
| `control`                                 | `{ holder: "user", since, expiresAt }` while Alexandre holds control                                                                                                                      |
| `meta`                                    | Per kind, tagged by `kind`: iOS `{ udid, name?, device?, runtime? }`; Android `{ serial?, avd?, consolePort?, grpcPort?, device? }`; Chrome `{ session?, cdp?, targetID?, url?, title? }` |
| `live`                                    | `{ stream, input }`: whether the adapter implements them (without `stream` the hub streams snapshots)                                                                                     |
| `discoveredAt`, `lastUsedAt`, `updatedAt` | Epoch ms                                                                                                                                                                                  |

Two registrations name the same resource when they share a UDID, an adb serial or AVD, or a Playwright session or
CDP endpoint; the hub merges them into one entry (metadata merged, latest owner wins).

## RPC `custom.resources`

All methods fail with `unavailable` `{ reason: "not_found" | "gone" | "unsupported" | "hub" | "failed" }`.

| Method     | Input                                            | Output                                                                                             |
| ---------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `list`     | `{ sessionID? }` (root)                          | `{ resources }`, newest use first                                                                  |
| `get`      | `{ id }`                                         | `Resource`                                                                                         |
| `snapshot` | `{ id, maxWidth? }`                              | `{ mime, data (base64), takenAt, width?, height? }`; cached 1.5 s; thumbnails use `maxWidth` ≈ 240 |
| `ticket`   | `{ id }`                                         | view `Ticket`                                                                                      |
| `control`  | `{ id, action: "take" \| "renew" \| "release" }` | `{ resource, ticket? }`; `take`/`renew` return a control ticket                                    |
| `dismiss`  | `{ id }`                                         | `{}`; removes it from the lists until an agent uses it again                                       |

Event `rpc.custom.resources.changed` `{ ids }`: reload `list` (the ids are a hint).

`Ticket` = `{ ticket, expiresAt, path, loopbackPort }`. Redeem it within 60 s; an open connection outlives it.
URL: the server origin + `path` + `/snapshot|/stream|/input` + `?ticket=…`. When the server itself is on loopback
(simulator tests against a sandbox) use `http://127.0.0.1:<loopbackPort>` instead, since no proxy is in front.

## Hub routes

Public (ticket in the `ticket` query parameter; the 4096 proxy forwards only `/resources/*` and strips
`authorization`):

| Route                                     |                                                             |
| ----------------------------------------- | ----------------------------------------------------------- |
| `GET /resources/<id>/snapshot[?maxWidth]` | Current screen (`image/jpeg` or `image/png`)                |
| `GET /resources/<id>/stream` (WebSocket)  | Live stream and, with a control ticket, input               |
| `GET /resources/<id>/stream` (plain HTTP) | MJPEG (`multipart/x-mixed-replace`) when the stream is JPEG |
| `POST /resources/<id>/input`              | `{ events: Input[] }` with a control ticket                 |

Admin (`authorization: Bearer <secret>` from `hub.json`; loopback only, never proxied): `GET /admin/health`,
`GET|PUT /admin/resources` (PUT = upsert `{ kind, meta, name?, purpose?, owner?, used? }`),
`GET|DELETE /admin/resources/<id>`, `POST /admin/resources/<id>/control`, `GET /admin/resources/<id>/snapshot`,
`POST /admin/tickets`, `GET /admin/locks`, `POST /admin/events?wait=<ms>` (long poll; each event goes to exactly one
caller), `POST /admin/shutdown`.

### Stream protocol (`protocol.ts`)

Text messages hub → client: `hello { format: "jpeg"|"png"|"h264", width, height, scale?, codec? }`,
`control { holder: "user"|null, expiresAt?, mine }`, `meta { value }` (kind state such as `{ url, title }`),
`pong { t, hub }`, `error { message }`, `end { reason }`.

Binary messages are frames: `u8 version = 1`, `u8 flags` (bit 0 keyframe), `f64` big-endian capture time (epoch
ms), payload (one JPEG/PNG image or one H.264 access unit). A new viewer gets `control`, the cached `hello`, the
latest `meta` and the last keyframe at once. Viewers more than 2 MiB behind skip frames until the next keyframe.

Text messages client → hub: `ping { t }` and `input { events }` (≤ 64 events). Input coordinates are normalized to the
frame (0…1, top left): `touch { phase: began|moved|ended|cancelled, x, y, pointer? }`, `scroll { x, y, dx, dy }`
(fractions of the frame), `key { key, modifiers? }` (DOM key names), `text { text }` (never logged),
`button { button: home|back|recents|lock|volume-up|volume-down|rotate-left|rotate-right|app-switcher }`,
`navigate { action: url|back|forward|reload|tab, url?, target? }` (`tab` follows the Chrome tab `target`). Without control the hub answers `error not_in_control`; an adapter
without `input` gives `error unsupported`.

## Adapters

`adapters/types.ts`:

```ts
interface Adapter {
  readonly kind: Resources.Kind
  probe(entries: readonly Entry[]): Promise<ReadonlyMap<string, Probe>> // every 5 s; missing id = gone
  snapshot(entry: Entry): Promise<Image> // full size; the hub resizes and caches
  stream?(entry: Entry, sink: StreamSink, signal: AbortSignal): Promise<void> // one per resource, shared
  input?(entry: Entry, event: Input): Promise<void> // only while Alexandre holds control
}
```

To add or finish a kind, edit only `adapters/<kind>.ts` (register a new kind in `adapters/index.ts` and in the
`Kind`/`Meta` unions). `stream` calls `sink.hello(...)` before frames and `sink.frame(payload, { keyframe,
capturedAt })` per frame, returns when `signal` aborts, and should throw on failure (viewers get `error` and
reconnect). Inputs for one resource are applied in order. Spawn helpers live in `adapters/process.ts`.
Never log `text` inputs. Status per kind (the foundation stubs implement `probe` and `snapshot` only; finished kinds
have their own section below):

| Kind               | Liveness                                          | Snapshot                                        | Live work                                               |
| ------------------ | ------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------- |
| `ios-simulator`    | `xcrun simctl list devices -j` (Booted → running) | `simctl io <udid> screenshot --type=jpeg`       | Done: serve-sim, see `docs/resources-ios-simulator.md`  |
| `android-emulator` | `avd/running/pid_*.ini` plus `adb devices`        | gRPC `getScreenshot` (adb `screencap` fallback) | Done: see [Android Emulator](#android-emulator)         |
| `chrome`           | CDP `/json/list` or `playwright-cli list --json`  | CDP `Page.captureScreenshot`                    | `Page.startScreencast` + `Input.dispatch*`/`insertText` |

Without `stream`, the hub streams `snapshot` as JPEG frames (about 3 per second, 828 px wide), so every kind is
viewable from the start.

### Android Emulator

`adapters/android-emulator.ts` and `adapters/android-grpc.ts` (a minimal gRPC client over `node:http2` with
hand-encoded protobuf, no dependency). Reference: the SDK's `emulator/lib/emulator_controller.proto`; Expo's serve-emu
(`expo/expo-device-hub` `packages/serve-emu`, `emulator-grpc.ts`) and t3code's devices notes informed the choice.

- **Why gRPC + JPEG.** The hub and the iOS shell already speak JPEG; the emulator's own gRPC `streamScreenshot` hands
  over raw pixels already scaled by the emulator, only when the screen changes, at no extra guest CPU. The rejected
  paths: `adb screencap` (about 300 ms per PNG frame, 3 fps), scrcpy (H.264 encoded in the guest, a server jar to
  ship and an H.264 decoder in the app) and serve-emu (H.264 through FFmpeg/libx264, WebSocket/WebRTC, no MJPEG).
- **Discovery.** Running emulators come from `avd/running/pid_<pid>.ini` (written only while gRPC is on; the PID is
  in the file name) and from `adb devices` (`emulator-<console port>`, AVD name from `adb emu avd name`), so an
  emulator started without gRPC is still found. `device` comes from the AVD's `hw.device.name`.
- **gRPC endpoint.** The adapter reads `grpc.port` and `grpc.token` from the ini. When gRPC is off (the usual case:
  `-ports` disables the automatic start), it turns it on through the console, `adb -s <serial> emu grpc
<console+3000>`, as Android Studio and serve-emu do. The endpoint listens on 127.0.0.1 and requires the bearer token;
  the token never leaves the hub (it is not part of `meta`). It stays on until the emulator exits.
- **Frames.** `streamScreenshot` in RGBA8888 fitted to a 1200 × 1200 box (540 × 1200 for a 720 × 1600 panel), wrapped
  in a top-down BMP header and encoded to JPEG (quality 70) by `Bun.Image` off the JavaScript thread. Only the newest
  frame is encoded; an idle screen sends nothing. The display rotation (`dumpsys display`, polled every 1.5 s while
  streaming) rotates the JPEG upright, re-announces `hello` with the new size and sends `meta { rotation }` (degrees).
  `snapshot` uses `getScreenshot` at panel size (JPEG quality 85).
- **Input.** `touch` → gRPC `sendTouch` in panel pixels (pressure 1024 while down, 0 to lift; `pointer` is the
  contact id, so multi-touch works), mapped back through the rotation. `scroll` → a 6-step drag with pointer 9.
  `button` → `adb shell input keyevent` (`back` BACK, `home` HOME, `recents`/`app-switcher` APP_SWITCH, `lock` POWER,
  volume); `rotate-left`/`rotate-right` set `user_rotation` with auto-rotate off. `key` → `input keyevent` for DOM
  names (Enter, Backspace, Delete, Tab, Escape, arrows, Home/End, PageUp/PageDown) or `input keycombination` with
  modifiers. `text` → printable ASCII through `input text` (spaces as `%s`, shell-quoted); anything else (accents,
  emoji, `%`) through the emulator clipboard: gRPC `setClipboard`, `KEYCODE_PASTE`, then the previous clipboard text
  back. The gRPC keyboard is not used because it only works with `hw.keyboard=yes`, which these AVDs lack.
- **Limits.** Pasting shows Android's "pasted from your clipboard" toast and briefly replaces the emulator clipboard
  (and, in a windowed emulator with clipboard sharing, the Mac's). Gboard with a stylus-capable touch panel may show
  its floating toolbar instead of the soft keyboard; the iPhone keyboard covers typing. Rotation is the display's
  `user_rotation`, not a skin rotation.
- **Measured** (MacBook Pro M4 Max, Android 37 image, 720 × 1600 at 30 Hz, sandbox hub, loopback): 15–18 fps while scrolling;
  emulator capture → hub WebSocket receipt 5 ms median (p95 8 ms); drag sent → first new frame 22–28 ms median
  (60 ms median measured on the adapter alone with slower moves); Início/Recentes sent → first frame about 90 ms;
  hub CPU 10–14 % of one core while frames flow, under 1 % on a still screen; emulator CPU unchanged by streaming
  (about 22 % scrolling either way). The iPhone adds its network round trip (shown in the status pill) and a JPEG
  decode.

### Chrome (`adapters/chrome.ts`, `adapters/cdp.ts`)

**Attaching to the agent's browser.** `playwright-cli` launches Chrome with `--remote-debugging-pipe`, a pipe only its
daemon holds, so nothing else can attach to it. Instead of driving the browser through the daemon's private socket
protocol (`~/Library/Caches/ms-playwright/daemon/<hash>/*.session`, versioned with Playwright and without a frame
stream) or asking agents to change how they open it, the plugin registers a `shell` `create.before` hook that sets
`PLAYWRIGHT_MCP_CONFIG=<hub state>/playwright-cli.json` (only when the shell has none). That config adds
`--remote-debugging-port=0`: Chrome keeps the pipe for Playwright and also listens on a random **loopback** port,
which it writes to `<user-data-dir>/DevToolsActivePort`. Headless and headed work alike. The adapter finds the browser
of `meta.session` from the process table: the `cliDaemon.js <session>` process, its Chrome child (`--user-data-dir`),
and that file. It never attaches to a Chrome it did not find this way (a personal Chrome with its own debugging port
is never a candidate). `--config`, a `.playwright/cli.config.json` in the working directory, or a browser opened before
the hook existed win over the environment: such browsers stay listed but live view reports that they were opened
without a debugging port. Agent shell calls wait for the Location's plugins, so the hook is in place before the
command runs; the raw `POST /api/shell` route does not wait, so its very first call in a cold Location can miss it.
Like the personal Chrome on 9222, the port accepts any local process; it closes with the browser.

**Stream.** One browser WebSocket per resource (flattened target sessions), shared by snapshot, stream and input and
closed after 60 s unused. `Page.startScreencast` (JPEG 70, at most 1280×2400) follows one tab; each frame is acked
after at least 66 ms (about 15 fps), so Chrome never runs ahead of the hub. During a finger scroll the screencast
restarts at half size and quality 50 and returns to full when frames settle (after t3code's `ServerBrowser`). Because
screencasts ignore emulated device scale, a phone-sized page streams only ~400 px wide: 200 ms after frames stop, a
still rendered up to 1200 px wide (`Page.captureScreenshot` with a scaled clip, screencast paused) replaces it, and the
repeated frame of the restarted screencast is dropped. Idle pages start from such a still.

**Meta** (`ChromeState`, replaced whole on every change): `{ url, title, canGoBack, canGoForward, targetID, tabs:
[{ id, title, url }], focus: { editable, field? }, editTaps, viewport?: { width, height } }`. `focus.field` is one of
`text multiline password email username url tel number search one-time-code`, classified in the page (through shadow
roots and same-origin frames) after taps, Tab/Enter/Escape and loads; values are never read. `editTaps` counts taps
that land on an editable field, so a viewer reopens its keyboard on the field that already had focus.

**Input.** Pages with touch emulation (`--device`/`--mobile`) get `Input.dispatchTouchEvent`. Mouse-only pages
(Playwright's default desktop context) turn a finger that stays put into a click at the release point and one that
moves more than 8 CSS px into wheel scrolling, like a phone browser, instead of a text-selecting drag. `scroll` is a
wheel event; `key` maps DOM key names to `Input.dispatchKeyEvent`; `text` is `Input.insertText` and is never logged;
`navigate` uses `Page.navigate` (addresses without a scheme get `http://` for local hosts, `https://` otherwise),
history entries, `Page.reload`, and `tab` re-targets the stream (`Target.activateTarget` brings it to front).

Checks: `bun test test/resources-chrome.test.ts` drives a real headless Chrome under a fake `cliDaemon.js` parent
(skipped without Chrome); `script/chrome-resource-check.ts --session <s> --out <dir>` measures a real `playwright-cli`
session; `script/chrome-login-fixture.ts` is the local login page those and the iOS UI test use.

## Control lock

"Assumir controle" (`control take`) gives Alexandre the resource. The plugin's `tool.hook("execute.before")` then
refuses `shell` commands that name it (UDID or simulator name, adb serial or AVD, `-s=<session>`, CDP port) or
target it implicitly (`simctl … booted`, `adb` without `-s`, `playwright-cli` without `-s` for the `default`
session) with "Alexandre está usando … ; aguarde". Every input renews the lock; after 2 minutes without input
(`limits.controlIdleMs`) or on `release`, the hub queues a `released` event and one plugin instance adds a
`session.synthetic` message (without resuming) to the owner session: "Alexandre interagiu com … Reavalie a tela".
Only watching never blocks the agent.

## Discovery

Automatic, in the plugin (`discovery.ts`, `index.ts`): `tool.hook("execute.after")` reads every completed `shell`
call (`OPENCODE_SESSION_ID` is also in the shell environment) and registers what it names, owned by that session and
its family's root:

| Kind    | Recognized                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| iOS     | Simulator UDIDs with `simctl`/`xcodebuild`/`agent-device`/`axe`/`idb`/`serve-sim`/`maestro`; device names after `simctl <boot\|spawn\|launch\|install\|io\|openurl\|…>`, `--device`, `-destination 'platform=iOS Simulator,name=…'`; the UDID printed by `simctl create`. Names resolve through `simctl list` (the only booted simulator with that name, else the only one; ambiguous names register nothing). `booted`, `delete`, `erase` and `shutdown` register nothing |
| Android | `emulator-NNNN` serials with `adb`/`emulator`/`android-emulator`/`agent-device`/`maestro`; `-avd NAME` or `@NAME` after `emulator`/`android-emulator`. Physical serials are ignored                                                                                                                                                                                                                                                                                        |
| Chrome  | `playwright-cli` commands with their session (`-s=`, `--session`, `PLAYWRIGHT_CLI_SESSION`; `default` otherwise, kept per workspace) and a CDP port (`--remote-debugging-port`, `--cdp=http://127.0.0.1:N`); `list`, `close`, `close-all`, `kill-all`, `install`, `delete-data` register nothing                                                                                                                                                                           |

Chrome needs nothing else: the `shell` `create.before` hook (see Chrome above) makes every `playwright-cli` browser
open with a loopback CDP port, and the adapter finds it from the session's daemon, so `meta.cdp` arrives with the
first probe. An emulator discovered by serial gains its AVD, ports and device from the Android probe, so a later
`-avd NAME` command matches the same entry. Each registration marks the resource as used by the agent (state `agent`). The result gains
`metadata.resources: [{ id, kind, label }]` and, once per session and resource, a line
`Recurso no app: [<kind> · <label>](opencode-resource:<encoded id>)`; the iOS app opens such links in the viewer.
Subagents' resources keep their own session as `owner.sessionID` and the family root as `owner.rootSessionID`, so
lists show them under the subagent ("via <agente>"). Reconciliation is the hub's `probe` every 5 s: dead resources
become `stopped` or `gone` (ended entries are dropped after 24 h, stopped ones after 7 days). The optional
`resource_label` tool only names a resource already used (`ref` = UDID, simulator name, serial, AVD or Playwright
session) or records its purpose.

## Hub process

The plugin starts the hub on demand (`supervisor.ts`) as `process.execPath` with `BUN_BE_BUN=1`: the release runs
`opencode plugin/index.js --opencode-resources-hub` (the bundle's `custom-plugin.ts` entry), source and `dist` run
`hub/bin.(ts|js)`. Environment: `OPENCODE_RESOURCES_HUB_STATE` (default
`$XDG_STATE_HOME/opencode/resources-hub`), `OPENCODE_RESOURCES_HUB_PORT` (production launcher: 4179; otherwise any
free port), `OPENCODE_RESOURCES_HUB_PARENT` (the server PID; the hub exits when it dies). The state directory holds
`hub.lock` (one hub per directory), `hub.json` (`{ protocol, pid, port, secret }`, 0600), `resources.json` (registry, 0600) and `hub.log`. A crash only stops the hub; the next RPC starts a new one, which reloads the registry. Plugin
instances replace a hub reporting another `protocol`.

## iOS

`ResourceViewerScreen` picks the kind view (`IOSSimulator/`, `AndroidEmulator/`, `Chrome/`), each built on
`ResourceViewerShell` (layout B): the screen fills the view with floating glass controls — close, status pill
(`iPhone 17 · ao vivo · 38 ms`, round trip from ping), who controls it, a side column of kind tools and the bottom
**Assumir controle** / **Devolver controle**. In control the screen gets a primary-colored border and a
**Você no controle** pill (menu: show controls, give back).

Showing and hiding the controls never steals a touch meant for the resource: while only watching, touches do not
reach the resource, so a tap on the screen toggles the controls. In control, every touch on the screen goes to the
resource except on the floating controls, which register their frames with `.excludedFromTouches(model, key)` (the
shell registers its own top bar, side tools, bottom bar, pill and handle; kinds register extra floating controls).
Taking control hides the controls; a small edge handle (draggable along the edge, position remembered) and the
**Você no controle** pill bring them back, and kinds may keep them shown (Chrome's address bar). Floating controls
that may cover the app, such as Android's navigation pill, also use `.resourceDraggable(key)` so Alexandre can move
them. Kinds without side tools pass `EmptyView` as `tools` and the column disappears;
`ResourceControlBar(model:accessory:)` puts a kind's control between the button and the hint (Android's pill).
Floating controls use `.resourceGlass(shape, tint:)` instead of Liquid Glass: a blurred material tinted with the
theme background, a hairline border and a soft shadow keep text legible over light pages in the dark theme and dark
ones in the light theme (Liquid Glass shapes also merge with neighbors, and a merged non-interactive shape swallowed
the close button's taps). `ResourceTouchOverlay` maps touches to the aspect-fit frame (multi-touch, touch
indicator). A stream `meta.rotation` (clockwise 0/90/180/270, the iOS Simulator in landscape) turns the picture
upright in `ResourceFrameView` and maps touches back to the unrotated frame (`OpenCodeKit/ResourceScreenGeometry`);
`ResourceKeyboard` forwards the iPhone keyboard as `text`/`key` inputs, with a content type (Chrome uses
`.password` for password autofill: kinds set `model.keyboardStyle`, a `ResourceKeyboardStyle` of content type,
keyboard type, secure entry and Return key). Frames decode one at a time and the newest waiting frame always follows,
so the last frame of a burst is never lost. Kinds that stream H.264 set `model.rawFrames` and pass their own
`surface`.
