# iOS Simulator resource

The `ios-simulator` adapter of the session resources hub (`packages/plugin-app-custom/src/resources/adapters/`)
lets the iPhone app watch and drive a simulator that an agent uses on the Mac. Discovery, tickets, control locks and
the viewer shell are the hub's (see `packages/plugin-app-custom/docs/resources.md`); this document covers what is
specific to simulators.

## serve-sim

Live frames and input come from **serve-sim** (`@expo/serve-sim`, Apache-2.0, from
[Expo Device Hub](https://github.com/expo/expo-device-hub/tree/main/packages/serve-sim), originally by Evan Bacon).
Its native addon captures the simulator's IOSurface through SimulatorKit and injects HID events through CoreSimulator,
so it needs no Simulator window and installs nothing in the app under test. Both run in the user's CoreSimulator
service, which keeps running while the Mac is locked; this change was verified with the Mac unlocked only.
The reference integration is t3code's (`pingdotgg/t3code` at `5b35402`, `docs/internals/devices.md` and
`apps/server/src/device/DeviceHubProxy.ts`), which also keeps the helper on loopback behind an authenticated proxy.

- **Version:** pinned to `0.10.3` in `packages/plugin-app-custom/package.json`. The repository installs only versions
  published at least three days earlier (`bunfig.toml`); `0.10.4` was two days old when this was added. Verified with
  Xcode 27.1 (27A9275), iOS 27.0 simulators, on Apple silicon (the package ships arm64 binaries only).
- **Packaging:** `custom:prepare` copies the package and its only runtime dependency, `ws`, to
  `<release>/serve-sim/node_modules/` (`bundleServeSim` in `packages/cli/script/custom-release.ts`, about 20 MB), so a
  `custom:update` brings it. The release binary runs it as Bun (`BUN_BE_BUN=1`); no Node or network is needed. In
  source and sandboxes the plugin uses its own `node_modules` copy; `OPENCODE_SERVE_SIM` overrides the script path.
  Its `LICENSE` and `NOTICE` travel with the copy. Other architectures skip the copy and fall back to snapshots.
- **Process:** one helper per simulator, started by the hub when the first viewer opens it (about 3.5 s until the
  helper admits input, 4 s until the first frame), shared by every viewer and by input, and stopped 2 minutes after
  the last one leaves, so reopening is instant (first frame in a few milliseconds). An idle helper costs about 1 % of
  one core and 165 MB; while a viewer watches a still screen, about 4 %. It runs
  `serve-sim --no-preview --quiet --disable clipboard --max-dimension 1280 --mjpeg-quality 0.6 --mjpeg-fps 30
--port <free> <udid>` and binds `127.0.0.1` only; the hub never forwards its routes. `--disable clipboard` keeps it
  from inserting its clipboard dylib into every app of the simulator, which pasting does not need. Its state lives in
  `$TMPDIR/opencode-serve-sim/<hub>/`. The hub stops its helpers when it exits (it exits with the server); a helper
  left behind by a killed hub is stopped when the next hub starts that simulator again.

## Stream

The adapter reads serve-sim's MJPEG response and forwards each JPEG part as a hub frame. serve-sim sends a part when
the screen changes (60 Hz IOSurface seed poll, at most 30 fps here, plus a 5 fps idle floor), at most 1280 px on the
long side: about 70 KB per frame instead of 250 KB at an iPhone 17's native 1206 × 2622. `hello` carries the frame
size and is sent again when it changes.

serve-sim streams the **unrotated** framebuffer (portrait for an iPhone) and reports the interface orientation on its
input socket. The adapter forwards it as stream `meta`: `{ "orientation": "landscape_left", "rotation": 90 }`, where
`rotation` is the clockwise turn that shows the frame upright (0, 90, 180 or 270). Input coordinates stay in the
unrotated frame, as the protocol requires; the viewer rotates the picture and un-rotates touches
(`OpenCodeKit/ResourceScreenGeometry.swift`).

## Input

| Protocol event                          | serve-sim input socket                                                                                                                                                                                                                                                                                                                       |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `touch` (one finger)                    | `0x03` begin/move/end at the frame point. A touch that starts in the bottom 7 % of the upright screen carries the bottom-edge flag (mapped to the raw edge when rotated), so dragging up from there goes home.                                                                                                                               |
| `touch` (second finger)                 | The first finger's touch ends and both become one `0x05` two-finger gesture (pinch, rotate); a finger left down afterwards is ignored until lifted.                                                                                                                                                                                          |
| `scroll`                                | `0x0b` with the same frame-fraction deltas and anchor.                                                                                                                                                                                                                                                                                       |
| `key`                                   | `0x06` HID usages (US layout, DOM names such as `Enter`, `Backspace`, arrows), modifiers pressed around the key.                                                                                                                                                                                                                             |
| `text`                                  | Up to 32 US-keyboard characters (what the iPhone keyboard sends per keystroke): `0x06` keys. Anything else: `0x12` paste: serve-sim writes the simulator pasteboard and presses ⌘V, so any Unicode (accents, emoji) arrives in one step, without the "Allow Paste" prompt. The adapter waits for the acknowledgment and never logs the text. |
| `button` `home`, `lock`, `app-switcher` | `0x04`. Home relaunches SpringBoard, because Xcode 26+ drops the HID home press.                                                                                                                                                                                                                                                             |
| `button` `rotate-left` / `rotate-right` | `0x07` with the next orientation. Apps that lock their orientation stay put.                                                                                                                                                                                                                                                                 |

Other buttons (`back`, `recents`, volume) do not exist on a simulator and are ignored.

## Viewer

`OpenCode/SessionResources/IOSSimulator/IOSSimulatorResourceView.swift` uses the shell (layout 2B) and adds the side
tools **Início**, **Girar** (rotate right), **Teclado** and **Captura de tela**. The shell's frame and touch overlay
honor `meta.rotation` for any kind. **Captura de tela** shares the full-size `simctl` screenshot (already upright).

## Measurements

On the Mac (Apple silicon, shared with other agents), iPhone 17 simulator, iOS 27.0.

From serve-sim's loopback (`bun`, 15 taps on a home-screen icon, from sending the touch to receiving the frame that
shows the highlight):

| Setting                     | Tap → frame p50 / p90 | Frame size | Frames while dragging |
| --------------------------- | --------------------- | ---------- | --------------------- |
| Native size, quality 0.7    | 21 / 32 ms            | 250 KB     | 19.5 fps              |
| 1280 px, quality 0.6 (used) | 12–24 / 14–30 ms      | 67–76 KB   | 16–19 fps             |

Through the hub, on the iPhone's path minus the network (`script/test-ios-simulator-resource.py`: control ticket,
WebSocket `/stream`, `touch` input on a page that changes color on `touchstart`, 20–30 taps per run, five runs):
**tap → frame p50 23–31 ms, p90 33–51 ms**, frames of about 34 KB on that page, 4.75 fps on a still screen (serve-sim's
5 fps idle floor). Viewing adds no measurable hub delay (capture-to-receipt age 0–1 ms on loopback); over WARP or
cellular, add the network round trip shown in the viewer's status pill. Pasting a 21-character Portuguese string
took about 650 ms; typed US characters go as keys, one socket message each.
