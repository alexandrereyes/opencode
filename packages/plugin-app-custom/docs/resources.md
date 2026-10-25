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

Text messages hub → client: `features { ack, auth, profiles }` (first; older hubs never send it),
`hello { format: "jpeg"|"png"|"h264", width, height, scale?, codec? }`,
`control { holder: "user"|null, expiresAt?, mine }`, `meta { value }` (kind state such as `{ url, title }`),
`stats { hub, capture?, frames, bytes, replaced, dropped, inFlight? }` (every 2 s), `notice { message }` (an adapter's
diagnosis, shown discreetly), `pong { t, hub }`, `error { message }`, `end { reason }`. `error` messages include
`not_in_control`, `unsupported`, `input_failed` (an input could not be applied; the event is never echoed),
`input_overflow` and `invalid_ticket`; a failing stream ends with `error` carrying the adapter's message.

`meta.rotation` is reserved for the clockwise turn the viewer must still apply to show frames upright (the iOS
Simulator streams its portrait framebuffer); the viewer maps touches back through it. A device orientation that is
only informative, because frames already arrive upright (Android), goes in `meta.orientation`.

Binary messages are frames: `u8 version = 1`, `u8 flags` (bit 0 keyframe), `f64` big-endian capture time (epoch
ms, Mac clock; the hub's receipt time when the adapter gives none), payload (one JPEG/PNG image or one H.264 access
unit). A new viewer gets `features`, `control`, the cached `hello`, the latest `meta` and the last keyframe at once.

Text messages client → hub: `ping { t }`, `input { events }` (≤ 64 events) and, only when `features` lists them,
`ack { n }`, `profile { value: "standard"|"economy" }` and `auth { ticket }`. Input coordinates are normalized to the
frame (0…1, top left): `touch { phase: began|moved|ended|cancelled, x, y, pointer? }`, `scroll { x, y, dx, dy }`
(fractions of the frame), `key { key, modifiers? }` (DOM key names), `text { text }` (never logged),
`button { button: home|back|recents|lock|volume-up|volume-down|rotate-left|rotate-right|app-switcher }`,
`navigate { action: url|back|forward|reload|tab, url?, target? }` (`tab` follows the Chrome tab `target`). Without control the hub answers `error not_in_control`; an adapter
without `input` gives `error unsupported`.

### Delivery and flow control

Each viewer is served on its own, so a slow viewer never holds back a fast one sharing the same capture.

- **Acknowledgements.** A client that sends `ack { n }` (frames received on this connection) has at most
  `maxFramesInFlight` = 3 unacknowledged frames on the way. This bounds lateness through the 4096 proxy and TCP,
  which the hub's own socket buffer cannot see. Clients without `ack` are limited by the hub's socket buffer:
  512 KiB for images.
- **Newest frame wins.** An image frame that does not fit replaces the viewer's single held-back frame, sent as soon
  as the viewer acknowledges, drains (WebSocket `drain`, MJPEG `pull`) or after a 30 ms retry. The last frame of a
  burst therefore always arrives, which matters for adapters that only send changes. H.264 cannot skip: a delta that
  does not fit (2 MiB budget) is dropped and the viewer waits for the next keyframe.
- **Pacing for adapters.** `sink.ready()` says whether some viewer can take a frame now (within budget, fewer than
  `maxFramesInFlight` in flight, nothing held back); `sink.whenReady(signal)` resolves when one can. Adapters that
  capture on demand (Chrome acknowledging screencast frames) wait on it before asking for the next frame; Android
  waits on it before encoding, so it encodes only frames someone can receive.
- **Profiles.** `profile` asks for `standard` or `economy`; the stream follows the most demanding viewer and adapters
  read it per frame with `sink.profile()`. The iPhone asks for economy on cellular or Low Data Mode.
- **Telemetry.** `stats` gives each viewer its own counters and, for adapters that report capture times, the
  capture → hub age of the last interval (p50/p95). With the pong's `hub` clock the client estimates the clock offset
  (from the fastest round trip) and measures capture → arrival, decode and capture → on screen. `GET /admin/streams`
  lists the same counters per viewer.
- **Control on the same socket.** `auth { ticket }` swaps a socket's ticket in place (a control ticket after taking
  control), so taking or giving back control does not tear the stream down. A stream also outlives its last viewer
  by 5 s, so a reconnecting viewer gets the cached frame at once and the adapter does not restart its capture.
- **MJPEG fallback.** Counted in bytes (512 KiB), with `Cache-Control: no-store, no-transform` and
  `X-Accel-Buffering: no`; the newest part is held back like a WebSocket frame and repeated once after 100 ms when
  nothing newer follows, because an HTTP client shows a part only when the next boundary arrives.

### Input queue (`hub/input-queue.ts`)

Inputs run one at a time per resource, in order, through a bounded queue (128 pending; lifting a finger is always
accepted, anything else beyond the limit gets `input_overflow`). Consecutive moves of the same finger collapse into
the newest position and adjacent text joins into one insert; `began`/`ended`/`cancelled`, keys, buttons and text
keep their order. Every input carries the control token that queued it and runs only if that token still holds the
resource. Giving control back (or expiry) drops pending inputs at once, waits for the input in flight, lifts fingers
still down (`touch cancelled` at their last position) and only then announces the hand-back to viewers and the
session. After Expo serve-emu's `control-input-queue.ts` (expo-device-hub rev `42918bc`).

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
  in a top-down BMP header and encoded to JPEG by `Bun.Image` off the JavaScript thread. Only the newest frame is
  encoded, and only once some viewer can take it (`sink.whenReady`); an idle screen sends nothing. Profiles
  (`profiles`): `standard` keeps 1200 px, quality 55 while the screen moves; `economy` shrinks to 800 px (360 × 800),
  quality 50 and at most about 15 fps. 300 ms after the last change the same picture goes out once more at the still
  quality (80 / 72), so a paused screen is sharp. The display rotation (`dumpsys display`, polled every 1.5 s while
  streaming) rotates the JPEG upright and re-announces `hello` when the size changes; `meta { orientation }`
  (`portrait`, `landscape_left`, `portrait_upside_down`, `landscape_right`, from `Surface.ROTATION_*`) is
  informative, never `rotation`, since the frames are already upright. `snapshot` uses `getScreenshot` at panel size
  (JPEG quality 85).
- **Input.** `touch` → gRPC `sendTouch` in panel pixels (pressure 1024 while down, 0 to lift; `pointer` is the
  contact id, so multi-touch works), mapped back through the rotation. `scroll` → a 6-step drag with pointer 9.
  `button` → `adb shell input keyevent` (`back` BACK, `home` HOME, `recents`/`app-switcher` APP_SWITCH, `lock` POWER,
  volume); `rotate-left`/`rotate-right` set `user_rotation` with auto-rotate off. `key` → `input keyevent` for DOM
  names (Enter, Backspace, Delete, Tab, Escape, arrows, Home/End, PageUp/PageDown) or `input keycombination` with
  modifiers. `text` → printable ASCII through `input text` (spaces as `%s`, shell-quoted); anything else (accents,
  emoji, `%`) through the emulator clipboard: gRPC `setClipboard`, `KEYCODE_PASTE`, a 250 ms settle, then the
  previous clipboard text back, also when the paste fails, but only if it could be read (an unreadable clipboard is
  left alone rather than emptied). The hub's queue joins adjacent text, so letters typed during a paste go in one
  insert. The gRPC keyboard is not used because it only works with `hw.keyboard=yes`, which these AVDs lack.
- **gRPC calls.** A unary call resolves only after the final `grpc-status: 0` (trailers, or the headers of a
  trailers-only answer); an HTTP error, a non-zero or a missing status rejects, and the hub tells the controlling
  viewer `input_failed` without the event.
- **Limits.** Pasting shows Android's "pasted from your clipboard" toast and briefly replaces the emulator clipboard
  (and, in a windowed emulator with clipboard sharing, the Mac's). Gboard with a stylus-capable touch panel may show
  its floating toolbar instead of the soft keyboard; the iPhone keyboard covers typing. Rotation is the display's
  `user_rotation`, not a skin rotation.
- **Measured** (MacBook Pro M4 Max, Android 37 image, 720 × 1600 at 30 Hz, sandbox hub, loopback, 25 Oct): emulator
  capture → hub WebSocket receipt 5 ms median (p95 7–9 ms); drag sent → first changed frame about 60 ms, of which the
  hub pipeline is 4–10 ms and the rest Android's own response; Início/Recentes → first frame 80–100 ms; 21–39 KB per
  standard frame (45 KB at the former quality 70), 18.6 KB in economy. Behind a relay limited to 2 Mbit/s that buffers
  like the proxy, an acknowledging viewer saw frames 513 ms old at p50 and 552 ms at p95 (before: 1.5–2.0 s and
  3.1–3.9 s, pings up to 4 s, and the final frame never arrived), 290 ms in economy, while a direct viewer of the
  same capture stayed at 5 ms. Hub CPU 3–6 % of one core while frames flow.

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
is never a candidate).

**Identity.** `playwright-cli` keeps sessions per namespace: the nearest of up to ten ancestors of its working
directory that holds `.playwright`, else one global namespace for every other directory (`namespaceOf`). `meta.workspace`
is the agent shell's directory; a daemon's namespace comes from its working directory (`lsof -d cwd`). So `default`
from `/a/projeto` and `/b/projeto` is the same browser (and the same lock) unless one of them is a Playwright
workspace; IDs are `chrome:<session>` globally and `chrome:<session>@<full workspace path>` inside one. Registrations
under the older `chrome:default@<folder>` IDs keep them (`upsert` merges by `sameResource`). Two candidate browsers
are reported as ambiguous instead of guessing. The endpoint found this way is cached and revalidated per probe with
`/json/version` (a relaunched Chrome has a new browser id even on a reused port): the process scan (~110 ms, plus
`lsof`) runs only to recover, and a probe of known browsers costs a few milliseconds. `--config`, a `.playwright/cli.config.json` in the working directory, or a browser opened before
the hook existed win over the environment: such browsers stay listed but live view reports that they were opened
without a debugging port. Agent shell calls wait for the Location's plugins, so the hook is in place before the
command runs. `POST /api/shell` waits for them too: the one custom line in `packages/server/src/handlers/shell.ts`
(`Plugin.awaitActivation`, as `core/session/shell.ts` does), covered by `packages/server/test/shell.test.ts`; without
it the first shell of a cold Location ran before plugins registered their `shell` hooks.
Like the personal Chrome on 9222, the port accepts any local process; it closes with the browser.

**Stream.** One browser WebSocket per resource (flattened target sessions), shared by snapshot, stream and input and
closed after 60 s unused. `Page.startScreencast` (JPEG 70, at most 1280×2400) follows one tab. Chromium keeps up to
three frames unacknowledged, so each frame is acknowledged 200 ms after it arrives: about 15 fps on a page that repaints
continuously (it was 44 fps with acks paced from the previous ack). Each ack also waits for `sink.whenReady`, so a viewer
that is behind (three unacknowledged frames) slows Chrome down instead of collecting frames nobody can receive. The
`economy` profile restarts the screencast at 800 × 1600, quality 55, acks after 300 ms (about 10 fps) and sharp
stills at 1.5×. Chrome's sharp stills replace the hub-agnostic "send the same picture again once the screen stops"
that Android does: there is no separate resend for Chrome. During a finger scroll, on the wheel or through
touch emulation, the screencast restarts at half the *effective* viewport and quality 50 (a 393 px phone page goes to
~196 px) and returns to full size once the finger stops; the end of the movement gets a still at once.

Screencasts ignore the emulated device scale, so a phone page streams at its CSS width (~400 px). Never capture with
`clip`: any clipped or scaled `Page.captureScreenshot` resets the device metrics Playwright emulates, leaving the
agent's page at `devicePixelRatio` 1 (or the window's size). Sharp stills therefore come from Playwright itself
(`page.screenshot({ scale: "device" })` through the session's `run-code`, which restores its emulation), downscaled to
at most 2× CSS and 1200 px with `Bun.Image`, and only while Alexandre holds control (input since `released`): the agent
is locked out then and never waits behind them. They follow an interaction or a burst at most once a second; a lone
repaint while idle (a blinking caret) is not streamed blurry over the sharp still but refreshed by a still at most
every 2.5 s (24 per minute instead of 120). The first frame of the restarted screencast repeats the still and is
dropped. While only watching, the stream is the screencast alone.

After `playwright-cli resize`, headless Chrome screencasts its window instead of the emulated viewport (a 393 × 659
iPhone viewport in the default 500 × 572 window lost its bottom 87 px). The adapter then grows the window to hold the
viewport (`Browser.setWindowBounds`, emulation untouched); windows are at least 500 px wide, so such a page keeps a
margin on the right, and sharp stills (viewport only) are skipped so frames and taps share one geometry.

**Meta** (`ChromeState`, replaced whole on every change): `{ url, title, canGoBack, canGoForward, targetID, tabs:
[{ id, title, url }], focus: { editable, field? }, editTaps, viewport?: { width, height } }`. `focus.field` is one of
`text multiline password email username url tel number search one-time-code`, classified in the page (through shadow
roots and same-origin frames) after taps, Tab/Enter/Escape and loads; values are never read. `editTaps` counts taps
that land on an editable field, so a viewer reopens its keyboard on the field that already had focus.

History (`canGoBack`/`canGoForward`) is read on every main-frame navigation and again at `load`, because a traversal
can report `frameNavigated` before its history index commits.

**Control end.** The hub calls the optional `Adapter.released(entry)` when control is returned or expires; Chrome stops
its Playwright stills there.

**Viewport not negotiated.** Fitting the page to the iPhone (for example a 1280 × 800 page that a 377 pt width shows
only 236 pt tall) was evaluated and left out: a DevTools `Emulation.setDeviceMetricsOverride` of ours replaces
Playwright's, and clearing it (or closing our session) leaves the window's size, not the agent's viewport; resizing
through the agent's own `playwright-cli resize` keeps Playwright consistent but switches headless Chrome to the window
geometry above for the rest of the session. Either way the agent would get back a different browser than it left.

**Input.** Pages with touch emulation (`--device`/`--mobile`) get `Input.dispatchTouchEvent`. Mouse-only pages
(Playwright's default desktop context) turn a finger that stays put into a click at the release point and one that
moves more than 8 CSS px into wheel scrolling, like a phone browser, instead of a text-selecting drag. `scroll` is a
wheel event; `key` maps DOM key names to `Input.dispatchKeyEvent`; `text` is `Input.insertText` and is never logged;
`navigate` uses `Page.navigate` (addresses without a scheme get `http://` for local hosts, `https://` otherwise),
history entries, `Page.reload`, and `tab` re-targets the stream (`Target.activateTarget` brings it to front).

Checks: `bun test test/resources-chrome.test.ts` drives a real headless Chrome under a fake `cliDaemon.js` parent
(skipped without Chrome) and real `playwright-cli` sessions (desktop and iPhone 15; skipped without the CLI) for the
frame-rate cap, touch motion, sharp still and emulation survival, idle refreshes and `released`; `script/chrome-resource-check.ts --session <s> --out <dir>` measures a real `playwright-cli`
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
(`iPhone 17 · ao vivo · 38 ms`, frame age or round trip, see below), who controls it, a side column of kind tools and the bottom
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

`ResourceViewerModel` owns the connection. Each socket has a generation; late messages and decodes from an older one
are dropped. The stream counts as live (`connected`) only after a frame or pong on the current socket; a ping goes
out every 2 s and 7 s without any answer drops the socket and reconnects, with a backoff that starts over after a
connection that worked. Input availability is separate from video: an `input_failed`/`input_overflow` error or a
failed send shows a short notice and marks input unavailable until it clears. With hubs that list them in
`features`, the model acknowledges every frame, asks for `economy` on cellular or Low Data Mode (`NWPathMonitor`) and
takes control with `auth` on the open socket instead of reconnecting; giving control back keeps the socket. Closing
the viewer (`finish()`) gives control back without reopening anything; the app going to the background suspends the
stream and coming back reconnects at once. The status pill shows how old the picture was when it reached the screen
(capture → on screen, clock-corrected) while frames flow, otherwise the round trip; a long press lists the
measurements (frame age, capture → device, capture → hub, decode, round trip, frames and KB per second, quality, held
back and dropped frames). Adapter `notice`s and stream errors appear briefly above the bottom controls.
