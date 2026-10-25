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
ms), payload (one JPEG/PNG image or one H.264 access unit). A new viewer gets `control`, the cached `hello` and the
last keyframe at once. Viewers more than 2 MiB behind skip frames until the next keyframe.

Text messages client → hub: `ping { t }` and `input { events }` (≤ 64 events). Input coordinates are normalized to the
frame (0…1, top left): `touch { phase: began|moved|ended|cancelled, x, y, pointer? }`, `scroll { x, y, dx, dy }`
(fractions of the frame), `key { key, modifiers? }` (DOM key names), `text { text }` (never logged),
`button { button: home|back|recents|lock|volume-up|volume-down|rotate-left|rotate-right|app-switcher }`,
`navigate { action: url|back|forward|reload, url? }`. Without control the hub answers `error not_in_control`; an adapter
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
Never log `text` inputs. The foundation stubs implement `probe` and `snapshot` only:

| Kind               | Liveness                                          | Snapshot                                  | Live work                                                          |
| ------------------ | ------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------ |
| `ios-simulator`    | `xcrun simctl list devices -j` (Booted → running) | `simctl io <udid> screenshot --type=jpeg` | serve-sim (Expo Device Hub): IOSurface + HID                       |
| `android-emulator` | `avd/running/pid_*.ini` (console, gRPC port, AVD) | `adb -s <serial> exec-out screencap -p`   | serve-emu H.264 or gRPC `streamScreenshot` + `sendTouch`/`sendKey` |
| `chrome`           | CDP `/json/list` or `playwright-cli list --json`  | CDP `Page.captureScreenshot`              | `Page.startScreencast` + `Input.dispatch*`/`insertText`            |

Without `stream`, the hub streams `snapshot` as JPEG frames (about 3 per second, 828 px wide), so every kind is
viewable from the start.

## Control lock

"Assumir controle" (`control take`) gives Alexandre the resource. The plugin's `tool.hook("execute.before")` then
refuses `shell` commands that name it (UDID or simulator name, adb serial or AVD, `-s=<session>`, CDP port) or
target it implicitly (`simctl … booted`, `adb` without `-s`, `playwright-cli` without `-s` for the `default`
session) with "Alexandre está usando … ; aguarde". Every input renews the lock; after 2 minutes without input
(`limits.controlIdleMs`) or on `release`, the hub queues a `released` event and one plugin instance adds a
`session.synthetic` message (without resuming) to the owner session: "Alexandre interagiu com … Reavalie a tela".
Only watching never blocks the agent.

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
reach the resource, so a tap toggles the controls; in control, every touch goes to the resource, the controls hide
and a small edge handle (draggable along the edge, position remembered) brings them back. Floating controls that
must stay visible in control, such as Android's navigation pill, use `.resourceDraggable(key)` so Alexandre can move
them off whatever they cover. `ResourceTouchOverlay` maps touches to the aspect-fit frame (multi-touch, touch
indicator); `ResourceKeyboard` forwards the iPhone keyboard as `text`/`key` inputs, with a content type (Chrome uses
`.password` for password autofill). Kinds that stream H.264 set `model.rawFrames` and pass their own `surface`.
