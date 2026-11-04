import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import type { Input } from "../protocol.js"
import { connect, decode, pb, type Connection } from "./android-grpc.js"
import { run, size, text } from "./process.js"
import type { Adapter, Entry, Image, Probe } from "./types.js"

/**
 * Android Emulator, through the emulator's own gRPC endpoint (see `docs/resources.md`, "Android Emulator").
 *
 * - Frames: `streamScreenshot` in RGBA8888, scaled by the emulator to fit `streamBox`, wrapped as a BMP and encoded to
 *   JPEG by `Bun.Image` off the JavaScript thread. The emulator only sends a frame when the screen changes, so an idle
 *   screen costs nothing. Only the newest frame is encoded; older ones are dropped.
 * - Touches: gRPC `sendTouch`, in panel pixels, one contact per pointer (multi-touch works).
 * - Buttons, keys and text: `adb shell input`, because the gRPC keyboard needs `hw.keyboard=yes`, which most AVDs
 *   here do not have. Text outside printable ASCII goes through the emulator clipboard and `KEYCODE_PASTE`; the
 *   previous clipboard text is put back afterwards.
 * - gRPC is off unless the emulator was started with it. The adapter turns it on through the console
 *   (`adb emu grpc <port>`), as Android Studio and Expo's serve-emu do; it listens on loopback and needs the
 *   console's bearer token, read from the emulator's `avd/running/pid_<pid>.ini`.
 */
export const adapter = createAdapter({
  run,
  text,
  connect,
  discovered: () => discovered(),
  emulators: () => emulators(),
  avdExists: (avd) => avdExists(avd),
})

/**
 * What the adapter does to the outside world: commands (always `adb` here), gRPC connections, and the emulators and
 * AVDs it reads from disk. Tests pass fakes to `createAdapter`; production uses the real ones (`adapter`).
 */
export interface AndroidSystem {
  run(command: readonly string[], options?: { readonly timeout?: number }): Promise<Uint8Array<ArrayBuffer>>
  text(command: readonly string[], options?: { readonly timeout?: number }): Promise<string>
  connect(endpoint: { readonly port: number; readonly token?: string }): Connection
  /** Emulators that wrote `avd/running/pid_<pid>.ini` and are alive: file reads only, no process. */
  discovered(): Promise<RunningEmulator[]>
  /** Every running emulator, with its device model (`discovered` plus `adb devices`). */
  emulators(): Promise<RunningEmulator[]>
  avdExists(avd: string): Promise<boolean>
}

export function createAdapter(io: AndroidSystem) {
  const devices = new Map<string, Promise<Device>>()

  /**
   * Proves which AVD runs on the target's serial now, before anything is sent there: a console port (and so a serial)
   * goes to whichever AVD starts next, and neither the registry nor a cached connection says who holds it today. The
   * proof comes from the running emulators' ini files (no process) or, without one, the read-only console query
   * `adb emu avd name`. A resource that is an AVD acts only on that AVD and fails closed when the occupant cannot be
   * told; one known only by serial (just discovered, not probed yet) acts on whatever emulator answers there.
   */
  const verify = async (target: Target) => {
    const now = await occupant(io, target.serial)
    if (!now) throw new UnconfirmedEmulator(target.serial, target.avd)
    checkAvd(target, now)
    return now
  }

  /**
   * One gRPC connection per emulator, opened on demand, only after `verify`, and reused only while it still serves
   * the AVD that holds the serial now; gRPC is turned on (`adb emu grpc`) only on a verified emulator.
   */
  const attach = async (target: Target) => {
    const avd = await verify(target)
    const cached = await devices.get(target.serial)?.catch(() => undefined)
    if (cached && !cached.connection.closed && cached.avd === avd) return cached
    cached?.connection.close()
    const created = grpcEndpoint(io, target.serial).then((endpoint): Device => {
      // The port changed hands between the proof and the endpoint lookup.
      checkAvd({ serial: target.serial, avd }, endpoint.avd)
      return { connection: io.connect(endpoint), rotation: 0, avd }
    })
    devices.set(target.serial, created)
    created.catch(() => devices.delete(target.serial))
    return created
  }

  const adapter: Adapter = {
    kind: "android-emulator",
    async probe(entries) {
      const android = entries.filter((entry) => entry.meta.kind === "android-emulator")
      const running = await io.emulators()
      const names = [...new Set(android.flatMap((entry) => identity(entry) ?? []))]
      const existing = await Promise.all(names.map(async (avd) => [avd, await io.avdExists(avd)] as const))
      return resolve(android, running, new Set(existing.flatMap(([avd, found]) => (found ? [avd] : []))))
    },

    /** A serial alone gets the AVD that runs there now, so the hub never files it under whoever ran there before. */
    async identify(meta) {
      if (meta.kind !== "android-emulator" || meta.avd !== undefined || meta.serial === undefined) return meta
      const avd = await occupant(io, meta.serial)
      return avd ? { ...meta, avd } : meta
    },

    async snapshot(entry) {
      const target = requireTarget(entry)
      const serial = target.serial
      const device = await attach(target).catch((error: unknown) => {
        if (error instanceof EmulatorIdentityError) throw error
        return undefined
      })
      // Without gRPC, a PNG through adb from the emulator `attach` has just verified.
      if (!device) {
        const data = await io.run([adb(), "-s", serial, "exec-out", "screencap", "-p"])
        return { mime: "image/png", data, ...size(data) }
      }
      const [message, rotation] = await Promise.all([
        device.connection.unary("getScreenshot", imageFormat(0)),
        displayRotation(io, serial).catch(() => device.rotation),
      ])
      device.rotation = rotation
      const frame = parseImage(message)
      return encode(frame, rotation, 85)
    },

    async stream(entry, sink, signal) {
      const target = requireTarget(entry)
      const serial = target.serial
      const device = await attach(target)
      const state = {
        latest: undefined as Frame | undefined,
        /** Last frame sent and whether it went out at the still (sharp) quality. */
        shown: undefined as { readonly frame: Frame; readonly sharp: boolean } | undefined,
        busy: false,
        size: "",
        orientation: -1,
        sentAt: 0,
        timer: undefined as ReturnType<typeof setTimeout> | undefined,
      }
      const later = (ms: number, run: () => void) => {
        clearTimeout(state.timer)
        state.timer = setTimeout(run, ms)
      }
      const publish = async (frame: Frame, sharp: boolean) => {
        const profile = profiles[sink.profile?.() ?? "standard"]
        const rotation = device.rotation
        const image = await encode(frame, rotation, sharp ? profile.still : profile.motion, profile.side).catch(
          () => undefined,
        )
        if (!image || signal.aborted) return
        const size = `${image.width}x${image.height}`
        if (size !== state.size) {
          state.size = size
          sink.hello({ format: "jpeg", width: image.width, height: image.height })
        }
        if (rotation !== state.orientation) {
          state.orientation = rotation
          // Frames already arrive upright, so this is information only; `rotation` would make viewers turn them again.
          sink.meta({ orientation: orientations[rotation] ?? "portrait" })
        }
        state.shown = { frame, sharp }
        state.sentAt = performance.now()
        sink.frame(image.data, { capturedAt: frame.capturedAt })
      }
      const pump = async (): Promise<void> => {
        if (state.busy || !state.latest || signal.aborted) return
        const profile = profiles[sink.profile?.() ?? "standard"]
        const wait = state.sentAt + profile.intervalMs - performance.now()
        if (wait > 0) return later(wait, () => void pump())
        state.busy = true
        // Encode only when some viewer can take the frame; meanwhile newer frames replace this one.
        if (sink.ready && !sink.ready()) await sink.whenReady?.(signal)
        const frame = state.latest
        state.latest = undefined
        if (frame) await publish(frame, false)
        state.busy = false
        if (state.latest) return pump()
        // The screen settled: send the same picture once more at the sharp quality.
        later(settleMs, () => {
          const shown = state.shown
          if (state.busy || state.latest || !shown || shown.sharp || signal.aborted) return
          state.busy = true
          void publish(shown.frame, true).finally(() => {
            state.busy = false
            void pump()
          })
        })
      }
      const watch = setInterval(() => {
        // Each poll first checks the serial still runs this AVD; if not, the stream ends instead of polling the next one.
        void verify(target)
          .then(() => displayRotation(io, serial))
          .then((rotation) => {
            if (rotation === device.rotation) return
            device.rotation = rotation
            // A rotation alone does not change the panel, so the emulator sends no frame: redraw the last one.
            state.latest ??= state.shown?.frame
            void pump()
          })
          .catch((error: unknown) => {
            if (error instanceof EmulatorIdentityError) device.connection.close()
          })
      }, rotationPollMs)
      device.rotation = await displayRotation(io, serial).catch(() => device.rotation)
      await device.connection
        .stream(
          "streamScreenshot",
          imageFormat(streamBox),
          (message) => {
            const frame = parseImage(message)
            if (frame.width === 0 || frame.height === 0) return
            state.latest = frame
            void pump()
          },
          signal,
        )
        .finally(() => {
          clearInterval(watch)
          clearTimeout(state.timer)
        })
    },

    async input(entry, event) {
      const target = requireTarget(entry)
      const serial = target.serial
      const device = await attach(target)
      const panel = (device.panel ??= await panelSize(io, serial))
      await plan(event, { rotation: device.rotation, panel }).reduce(
        (chain, step) => chain.then(() => perform(io, serial, device, step)),
        Promise.resolve(),
      )
    },
  }
  return adapter
}

type Target = { readonly serial: string; readonly avd?: string }

/** The AVD running on `serial` now: its ini file if it has one (no process), else the console; `undefined` if unknown. */
async function occupant(io: AndroidSystem, serial: string) {
  const consolePort = Number(/^emulator-(\d+)$/.exec(serial)?.[1] ?? Number.NaN)
  if (!Number.isInteger(consolePort)) return undefined
  const file = (await io.discovered().catch(() => [])).find((item) => item.consolePort === consolePort)
  if (file?.avd) return file.avd
  return io
    .text([adb(), "-s", serial, "emu", "avd", "name"], { timeout: 5_000 })
    .then((output) => output.split("\n")[0]?.trim() || undefined)
    .catch(() => undefined)
}

/**
 * Identity of an Android resource. The AVD is the identity; the serial (`emulator-<console port>`) is only where it
 * runs now, and the next AVD to start takes the same port. IDs carry the AVD when one was known at registration
 * (`android-emulator:<AVD>`), so the ID outranks `meta.avd`: entries whose `meta.avd` was rewritten by the old
 * serial-or-AVD matching still say which emulator they are. Older IDs made from a serial (`android-emulator:emulator-5554`)
 * carry no AVD; those entries are identified by the AVD their first probe bound them to.
 */
export function identity(entry: Pick<Entry, "id" | "meta">) {
  return avdFromID(entry.id) ?? (entry.meta.kind === "android-emulator" ? entry.meta.avd : undefined)
}

/** The AVD an Android resource ID names, unless it was made from a serial or without either. */
export function avdFromID(id: string) {
  const native = id.startsWith("android-emulator:") ? id.slice("android-emulator:".length).replace(/~\d+$/, "") : ""
  if (!native || native === "unknown" || /^emulator-\d+$/.test(native)) return undefined
  return native
}

/**
 * Restores an entry whose `meta` describes another AVD than its ID (the port-reuse corruption): `meta.avd` back to
 * the ID's AVD, the other emulator's serial, ports and device model dropped, and `running` turned into `stopped` until
 * a probe finds its own AVD. Owner, name, purpose and history stay. Returns `undefined` when nothing needs repairing.
 */
export function repair(entry: Entry, at: number): Entry | undefined {
  const avd = avdFromID(entry.id)
  if (entry.meta.kind !== "android-emulator" || !avd || entry.meta.avd === undefined || entry.meta.avd === avd)
    return undefined
  return {
    ...entry,
    meta: { kind: "android-emulator", avd },
    status: entry.status === "running" ? "stopped" : entry.status,
    // Changed now: retention of stopped and gone entries counts from the repair, not from the corruption.
    updatedAt: Math.max(entry.updatedAt, at),
  }
}

/**
 * Probe results for Android entries (pure; `probe` gathers `running` and the AVDs that exist on disk).
 *
 * - An entry with an AVD is running only while that AVD runs, whatever serial it now has; a serial it held before
 *   says nothing about the AVD now on that port. Stopped entries drop their serial and ports, so neither discovery,
 *   the agent lock nor input can reach the next AVD on that port through them.
 * - An entry known only by serial binds to the emulator on that serial, and so learns its AVD, unless another entry
 *   already is that AVD.
 * - When several entries are the same AVD (left by the old matching), one represents it: the one whose ID is that
 *   AVD, else the earliest discovered. The others stay, history intact, but are reported stopped and unbound.
 *
 * Every result replaces the entry's metadata (`exact`), since stale fields must go, not merge.
 */
export function resolve(
  entries: readonly Entry[],
  running: readonly RunningEmulator[],
  existing: ReadonlySet<string>,
): Map<string, Probe> {
  const representative = representatives(entries)
  return new Map(
    entries.flatMap((entry): [string, Probe][] => {
      if (entry.meta.kind !== "android-emulator") return []
      const meta = entry.meta
      const avd = identity(entry)
      if (!avd) {
        const found = running.find(
          (item) =>
            meta.serial !== undefined && item.serial === meta.serial && !(item.avd && representative.has(item.avd)),
        )
        if (found) return [[entry.id, { status: "running", meta: bound(meta, found), exact: true }]]
        return [[entry.id, { status: "gone" }]]
      }
      const own = meta.avd === avd
      const found = representative.get(avd) === entry.id ? running.find((item) => item.avd === avd) : undefined
      if (found)
        return [[entry.id, { status: "running", meta: bound({ kind: "android-emulator", avd }, found), exact: true }]]
      return [
        [
          entry.id,
          {
            status: existing.has(avd) ? "stopped" : "gone",
            meta: { kind: "android-emulator", avd, ...(own && meta.device ? { device: meta.device } : {}) },
            exact: true,
          },
        ],
      ]
    }),
  )
}

/** For each AVD, the entry that represents it: the one whose ID is that AVD, else the earliest discovered. */
export function representatives(entries: readonly Entry[]) {
  const groups = Map.groupBy(
    entries.flatMap((entry) => {
      const avd = identity(entry)
      return avd ? [{ avd, entry }] : []
    }),
    (item) => item.avd,
  )
  return new Map(
    [...groups].map(([avd, items]) => {
      const chosen =
        items.find((item) => avdFromID(item.entry.id) === avd && !/~\d+$/.test(item.entry.id)) ??
        items.toSorted(
          (a, b) => a.entry.discoveredAt - b.entry.discoveredAt || a.entry.id.localeCompare(b.entry.id),
        )[0]!
      return [avd, chosen.entry.id] as const
    }),
  )
}

function bound(meta: Extract<Entry["meta"], { kind: "android-emulator" }>, found: RunningEmulator) {
  return {
    ...meta,
    serial: found.serial,
    consolePort: found.consolePort,
    ...(found.avd ? { avd: found.avd } : {}),
    ...(found.grpcPort ? { grpcPort: found.grpcPort } : {}),
    ...(found.device ? { device: found.device } : {}),
  }
}

/** Frames are scaled by the emulator to fit this box, so portrait and landscape panels keep the same detail. */
export const streamBox = 1200

/**
 * Stream profiles (see `ResourceProtocol.Profile`): the longest side in pixels, JPEG quality while the screen moves
 * and once it settles, and the shortest interval between frames. Economy (360 × 800 for a 720 × 1600 panel, about
 * 15 fps) is for cellular and Low Data Mode. Either way, `settleMs` after the last change the same picture goes out
 * again at the still quality, so a paused screen is sharp.
 */
export const profiles = {
  standard: { side: 1200, motion: 55, still: 80, intervalMs: 0 },
  economy: { side: 800, motion: 50, still: 72, intervalMs: 66 },
} as const
const settleMs = 300
const rotationPollMs = 1_500
/** Android `Surface.ROTATION_*` as the viewers' informative `meta.orientation`. */
const orientations = ["portrait", "landscape_left", "portrait_upside_down", "landscape_right"]
/** How long a paste may take inside the app before the previous clipboard text goes back. */
const pasteSettleMs = 250
/** Raw pressure for a touching contact; zero lifts it. */
const pressure = 1024
/** The pointer used to emulate scroll gestures, kept apart from the iPhone's finger indices. */
const scrollPointer = 9

type Frame = { readonly rgba: Uint8Array; readonly width: number; readonly height: number; readonly capturedAt: number }

type Device = {
  connection: Connection
  /** The AVD verified on this serial when the connection opened. */
  avd: string
  rotation: number
  panel?: { readonly width: number; readonly height: number }
}

/** Refuses a device whose AVD is known and differs from the one the resource is (its port was reused). */
export function checkAvd(target: Target, running: string | undefined) {
  if (target.avd && running && running !== target.avd) throw new AnotherEmulator(target.serial, target.avd, running)
}

/** The serial does not (provably) run the resource's AVD: nothing was sent to it. */
export class EmulatorIdentityError extends Error {}

export class AnotherEmulator extends EmulatorIdentityError {
  constructor(serial: string, expected: string, running: string) {
    super(`${serial} now runs the AVD ${running}, not ${expected}`)
    this.name = "AnotherEmulator"
  }
}

export class UnconfirmedEmulator extends EmulatorIdentityError {
  constructor(serial: string, expected: string | undefined) {
    super(
      expected ? `Could not confirm that ${serial} still runs the AVD ${expected}` : `No emulator answers on ${serial}`,
    )
    this.name = "UnconfirmedEmulator"
  }
}

export type Step =
  | { readonly type: "touch"; readonly touches: readonly { x: number; y: number; id: number; pressure: number }[] }
  | { readonly type: "shell"; readonly command: string }
  | { readonly type: "paste"; readonly text: string }
  | { readonly type: "rotate"; readonly rotation: number }

/** Turns one viewer event into emulator steps. Pure, so the mapping is testable without an emulator. */
export function plan(
  event: Input,
  geometry: { readonly rotation: number; readonly panel: { readonly width: number; readonly height: number } },
): Step[] {
  const point = (x: number, y: number) => {
    const [px, py] = toPanel(x, y, geometry.rotation)
    return {
      x: Math.round(px * (geometry.panel.width - 1)),
      y: Math.round(py * (geometry.panel.height - 1)),
    }
  }
  if (event.type === "touch") {
    const contact = event.phase === "began" || event.phase === "moved" ? pressure : 0
    return [{ type: "touch", touches: [{ ...point(event.x, event.y), id: event.pointer ?? 0, pressure: contact }] }]
  }
  if (event.type === "scroll") {
    const clamp = (value: number) => Math.min(1, Math.max(0, value))
    const steps = 6
    const path = Array.from({ length: steps + 1 }, (_, index) =>
      point(clamp(event.x - (event.dx * index) / steps), clamp(event.y - (event.dy * index) / steps)),
    )
    return path.map((at, index) => ({
      type: "touch" as const,
      touches: [{ ...at, id: scrollPointer, pressure: index === steps ? 0 : pressure }],
    }))
  }
  if (event.type === "button") {
    if (event.button === "rotate-left") return [{ type: "rotate", rotation: (geometry.rotation + 1) % 4 }]
    if (event.button === "rotate-right") return [{ type: "rotate", rotation: (geometry.rotation + 3) % 4 }]
    const code = buttons[event.button]
    return code ? [{ type: "shell", command: `input keyevent ${code}` }] : []
  }
  if (event.type === "key") {
    const code = keys[event.key]
    const modifiers = (event.modifiers ?? []).map((modifier) => modifierKeys[modifier])
    if (code && modifiers.length === 0) return [{ type: "shell", command: `input keyevent ${code}` }]
    if (code) return [{ type: "shell", command: `input keycombination ${[...modifiers, code].join(" ")}` }]
    if ([...event.key].length !== 1) return []
    const letter = /^[a-z0-9]$/i.test(event.key) ? `KEYCODE_${event.key.toUpperCase()}` : undefined
    if (letter && modifiers.length > 0)
      return [{ type: "shell", command: `input keycombination ${[...modifiers, letter].join(" ")}` }]
    return typeText(event.key)
  }
  if (event.type === "text") return typeText(event.text)
  return []
}

/** Maps a point of the upright (rotated) frame back to the emulator panel, both normalized to [0, 1]. */
export function toPanel(x: number, y: number, rotation: number): readonly [number, number] {
  if (rotation === 1) return [1 - y, x]
  if (rotation === 2) return [1 - x, 1 - y]
  if (rotation === 3) return [y, 1 - x]
  return [x, y]
}

/**
 * Printable ASCII goes through `input text` (spaces as `%s`, which `input` turns back into spaces, so text with a
 * literal `%` uses the clipboard); line breaks become Enter. Everything else, such as accents and emoji, is pasted.
 */
function typeText(value: string): Step[] {
  return value.split("\n").flatMap((line, index): Step[] => {
    const enter: Step[] = index > 0 ? [{ type: "shell", command: "input keyevent KEYCODE_ENTER" }] : []
    if (line.length === 0) return enter
    if (/^[\x20-\x7e]+$/.test(line) && !line.includes("%"))
      return [...enter, { type: "shell", command: `input text ${quote(line.replaceAll(" ", "%s"))}` }]
    return [...enter, { type: "paste", text: line }]
  })
}

function quote(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`
}

const buttons: Partial<Record<Extract<Input, { type: "button" }>["button"], string>> = {
  back: "KEYCODE_BACK",
  home: "KEYCODE_HOME",
  recents: "KEYCODE_APP_SWITCH",
  "app-switcher": "KEYCODE_APP_SWITCH",
  lock: "KEYCODE_POWER",
  "volume-up": "KEYCODE_VOLUME_UP",
  "volume-down": "KEYCODE_VOLUME_DOWN",
}

const keys: Record<string, string> = {
  Enter: "KEYCODE_ENTER",
  Backspace: "KEYCODE_DEL",
  Delete: "KEYCODE_FORWARD_DEL",
  Tab: "KEYCODE_TAB",
  Escape: "KEYCODE_ESCAPE",
  ArrowUp: "KEYCODE_DPAD_UP",
  ArrowDown: "KEYCODE_DPAD_DOWN",
  ArrowLeft: "KEYCODE_DPAD_LEFT",
  ArrowRight: "KEYCODE_DPAD_RIGHT",
  Home: "KEYCODE_MOVE_HOME",
  End: "KEYCODE_MOVE_END",
  PageUp: "KEYCODE_PAGE_UP",
  PageDown: "KEYCODE_PAGE_DOWN",
  " ": "KEYCODE_SPACE",
}

const modifierKeys = {
  shift: "KEYCODE_SHIFT_LEFT",
  control: "KEYCODE_CTRL_LEFT",
  alt: "KEYCODE_ALT_LEFT",
  meta: "KEYCODE_META_LEFT",
} as const

async function perform(io: AndroidSystem, serial: string, device: Device, step: Step) {
  if (step.type === "touch") {
    const touches = step.touches.map((touch) =>
      pb.bytes(
        1,
        pb.message(
          pb.int32(1, touch.x),
          pb.int32(2, touch.y),
          pb.int32(3, touch.id),
          pb.int32(4, touch.pressure),
          pb.int32(5, touch.pressure > 0 ? 8 : 0),
        ),
      ),
    )
    await device.connection.unary("sendTouch", pb.message(...touches))
    return
  }
  if (step.type === "shell") {
    await io.run([adb(), "-s", serial, "shell", step.command])
    return
  }
  if (step.type === "rotate") {
    await io.run([
      adb(),
      "-s",
      serial,
      "shell",
      `settings put system accelerometer_rotation 0 && settings put system user_rotation ${step.rotation}`,
    ])
    return
  }
  // The previous clipboard goes back whatever happens to the paste, but only if it could be read: restoring an
  // unknown clipboard as empty would erase it.
  const previous = await device.connection.unary("getClipboard", new Uint8Array(0)).then(
    (message) => ({ text: decode(message).bytes(1) ?? new Uint8Array(0) }),
    () => undefined,
  )
  await device.connection
    .unary("setClipboard", pb.string(1, step.text))
    .then(() => io.run([adb(), "-s", serial, "shell", "input keyevent KEYCODE_PASTE"]))
    // The paste is asynchronous in the app; give it a moment before putting the old clipboard back.
    .then(() => Bun.sleep(pasteSettleMs))
    .finally(() =>
      previous ? device.connection.unary("setClipboard", pb.bytes(1, previous.text)).catch(() => {}) : undefined,
    )
}

/** `ImageFormat` for RGBA8888 frames that fit a `box`×`box` square; 0 keeps the panel size. */
function imageFormat(box: number) {
  return pb.message(pb.varint(1, 1), pb.varint(3, box), pb.varint(4, box))
}

function parseImage(message: Uint8Array): Frame {
  const image = decode(message)
  const format = decode(image.bytes(1) ?? new Uint8Array(0))
  const timestamp = image.number(6)
  return {
    rgba: image.bytes(4) ?? new Uint8Array(0),
    width: format.number(3) || image.number(2),
    height: format.number(4) || image.number(3),
    capturedAt: timestamp > 0 ? timestamp / 1000 : Date.now(),
  }
}

/**
 * Encodes a panel frame as an upright JPEG, rotating it the way the display is rotated and, with `side`, shrinking it
 * to fit a `side` × `side` box.
 */
async function encode(
  frame: Frame,
  rotation: number,
  quality: number,
  side?: number,
): Promise<Image & { width: number; height: number }> {
  const pipeline = new Bun.Image(bmp(frame.rgba, frame.width, frame.height))
  const turned = rotation === 0 ? pipeline : pipeline.rotate((360 - rotation * 90) % 360)
  const swapped = rotation % 2 === 1
  const width = swapped ? frame.height : frame.width
  const height = swapped ? frame.width : frame.height
  const scale = side ? Math.min(1, side / Math.max(width, height)) : 1
  const target = { width: Math.round(width * scale), height: Math.round(height * scale) }
  const sized = scale < 1 ? turned.resize(target.width, target.height, { filter: "bilinear" }) : turned
  // Copied into a plain ArrayBuffer, which the hub's frame and HTTP bodies require.
  const data = new Uint8Array(await sized.jpeg({ quality }).bytes())
  return { mime: "image/jpeg", data, ...target }
}

/**
 * Wraps RGBA8888 pixels in a top-down 32-bit BMP (BITMAPV5HEADER with channel masks), the one raw layout `Bun.Image`
 * decodes, so the pixels are not reordered in JavaScript.
 */
export function bmp(rgba: Uint8Array, width: number, height: number) {
  const headerSize = 14 + 124
  const out = new Uint8Array(headerSize + rgba.byteLength)
  const view = new DataView(out.buffer)
  out[0] = 0x42
  out[1] = 0x4d
  view.setUint32(2, out.byteLength, true)
  view.setUint32(10, headerSize, true)
  view.setUint32(14, 124, true)
  view.setInt32(18, width, true)
  view.setInt32(22, -height, true)
  view.setUint16(26, 1, true)
  view.setUint16(28, 32, true)
  view.setUint32(30, 3, true)
  view.setUint32(34, rgba.byteLength, true)
  view.setUint32(54, 0x000000ff, true)
  view.setUint32(58, 0x0000ff00, true)
  view.setUint32(62, 0x00ff0000, true)
  view.setUint32(66, 0xff000000, true)
  view.setUint32(70, 0x73524742, true)
  out.set(rgba, headerSize)
  return out
}

/** Current display rotation as a quarter-turn count (Android `Surface.ROTATION_*`). */
async function displayRotation(io: AndroidSystem, serial: string) {
  const output = await io.text(
    [adb(), "-s", serial, "shell", "dumpsys display 2>/dev/null | grep -m1 -o 'mCurrentOrientation=[0-3]'"],
    { timeout: 5_000 },
  )
  return Number(/=(\d)/.exec(output)?.[1] ?? 0)
}

/** The touch panel's pixel size: the physical display size, which an `wm size` override does not change. */
async function panelSize(io: AndroidSystem, serial: string) {
  const output = await io.text([adb(), "-s", serial, "shell", "wm size"], { timeout: 5_000 })
  const match = /Physical size:\s*(\d+)x(\d+)/.exec(output)
  if (!match) throw new Error("Could not read the emulator display size")
  return { width: Number(match[1]), height: Number(match[2]) }
}

/** The serial to act on and the AVD that must be running there. */
function requireTarget(entry: Entry): Target {
  if (entry.meta.kind !== "android-emulator" || !entry.meta.serial) throw new Error("Emulator is not attached to adb")
  const avd = identity(entry)
  return { serial: entry.meta.serial, ...(avd ? { avd } : {}) }
}

/** The gRPC port and token of a running emulator, turning gRPC on through the console when it is off. */
async function grpcEndpoint(io: AndroidSystem, serial: string) {
  const consolePort = Number(/^emulator-(\d+)$/.exec(serial)?.[1] ?? Number.NaN)
  if (!Number.isInteger(consolePort)) throw new Error(`Not an emulator serial: ${serial}`)
  const find = async () => (await io.discovered()).find((item) => item.consolePort === consolePort && item.grpcPort)
  const existing = await find()
  if (existing?.grpcPort) return { port: existing.grpcPort, token: existing.grpcToken, avd: existing.avd }
  await io.text([adb(), "-s", serial, "emu", "grpc", String(consolePort + 3000)], { timeout: 10_000 })
  const started = await find()
  if (!started?.grpcPort) throw new Error("The emulator did not start its gRPC endpoint")
  return { port: started.grpcPort, token: started.grpcToken, avd: started.avd }
}

export type RunningEmulator = {
  readonly pid: number
  readonly serial: string
  readonly consolePort: number
  readonly grpcPort?: number
  /** Bearer token for gRPC; never part of the resource metadata. */
  readonly grpcToken?: string
  readonly avd?: string
  readonly device?: string
}

export function adb() {
  const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT ?? path.join(os.homedir(), "Library/Android/sdk")
  return Bun.which("adb") ?? path.join(sdk, "platform-tools/adb")
}

/**
 * Running emulators: those that wrote `avd/running/pid_<pid>.ini` (only while gRPC is on) plus the emulators adb
 * lists, so an emulator started without gRPC is still found.
 */
export async function emulators(): Promise<RunningEmulator[]> {
  const [files, attached] = await Promise.all([discovered(), adbEmulators()])
  const extra = attached.filter((serial) => !files.some((item) => item.serial === serial))
  const listed = await Promise.all(
    extra.map(async (serial): Promise<RunningEmulator> => {
      const consolePort = Number(serial.slice("emulator-".length))
      const avd = await text([adb(), "-s", serial, "emu", "avd", "name"], { timeout: 5_000 })
        .then((output) => output.split("\n")[0]?.trim() || undefined)
        .catch(() => undefined)
      return { pid: 0, serial, consolePort, ...(avd ? { avd } : {}) }
    }),
  )
  return Promise.all(
    [...files, ...listed].map(async (item) => ({ ...item, device: item.avd ? await deviceName(item.avd) : undefined })),
  )
}

async function discovered() {
  const directories = [
    path.join(os.homedir(), ".android/avd/running"),
    path.join(os.homedir(), "Library/Caches/TemporaryItems/avd/running"),
    path.join(os.tmpdir(), "avd/running"),
  ]
  const files = (
    await Promise.all(
      directories.map((directory) =>
        fs
          .readdir(directory)
          .then((names) =>
            names.filter((name) => /^pid_\d+\.ini$/.test(name)).map((name) => path.join(directory, name)),
          )
          .catch(() => []),
      ),
    )
  ).flat()
  const parsed = await Promise.all(
    files.map((file) =>
      fs.readFile(file, "utf8").then(
        (content) => parseRunning(content, Number(/pid_(\d+)\.ini$/.exec(file)?.[1] ?? 0)),
        () => undefined,
      ),
    ),
  )
  return parsed.filter((item): item is RunningEmulator => item !== undefined && isAlive(item.pid))
}

async function adbEmulators() {
  const output = await text([adb(), "devices"], { timeout: 5_000 }).catch(() => "")
  return output
    .split("\n")
    .map((line) => line.trim().split(/\s+/))
    .filter((parts) => /^emulator-\d+$/.test(parts[0] ?? "") && parts[1] === "device")
    .map((parts) => parts[0]!)
}

/** Parses an emulator's `pid_<pid>.ini`; the PID comes from the file name, since the file does not repeat it. */
export function parseRunning(content: string, pid = 0): RunningEmulator | undefined {
  const values = new Map(
    content.split("\n").flatMap((line) => {
      const index = line.indexOf("=")
      return index > 0 ? [[line.slice(0, index).trim(), line.slice(index + 1).trim()] as const] : []
    }),
  )
  const consolePort = Number(values.get("port.serial") ?? Number.NaN)
  if (!Number.isInteger(consolePort)) return undefined
  const grpcPort = Number(values.get("grpc.port") ?? Number.NaN)
  const token = values.get("grpc.token")
  return {
    pid,
    serial: `emulator-${consolePort}`,
    consolePort,
    ...(Number.isInteger(grpcPort) ? { grpcPort } : {}),
    ...(token ? { grpcToken: token } : {}),
    ...(values.get("avd.name") ? { avd: values.get("avd.name") } : {}),
  }
}

function isAlive(pid: number) {
  if (pid <= 0) return true
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

/** AVD folders: `ANDROID_AVD_HOME`, the SDK default and the XDG location newer command-line tools use. */
function avdHomes() {
  return [
    ...(process.env.ANDROID_AVD_HOME ? [process.env.ANDROID_AVD_HOME] : []),
    path.join(os.homedir(), ".android/avd"),
    path.join(process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config"), ".android/avd"),
  ]
}

async function avdExists(avd: string | undefined) {
  if (!avd) return false
  const found = await Promise.all(
    avdHomes().map((home) =>
      fs.stat(path.join(home, `${avd}.avd`)).then(
        () => true,
        () => false,
      ),
    ),
  )
  return found.includes(true)
}

async function deviceName(avd: string) {
  const configs = await Promise.all(
    avdHomes().map((home) => fs.readFile(path.join(home, `${avd}.avd`, "config.ini"), "utf8").catch(() => "")),
  )
  const config = configs.find((content) => content.length > 0) ?? ""
  const name = /^hw\.device\.name\s*=\s*(.+)$/m.exec(config)?.[1]?.trim()
  return name ? name.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()) : undefined
}
