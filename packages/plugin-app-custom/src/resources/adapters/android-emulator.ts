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
export const adapter: Adapter = {
  kind: "android-emulator",
  async probe(entries) {
    const running = await emulators()
    return new Map(
      await Promise.all(
        entries.flatMap((entry) => {
          if (entry.meta.kind !== "android-emulator") return []
          const meta = entry.meta
          const found = running.find(
            (item) => (meta.serial && item.serial === meta.serial) || (meta.avd && item.avd === meta.avd),
          )
          if (found)
            return [
              Promise.resolve<[string, Probe]>([
                entry.id,
                {
                  status: "running",
                  meta: {
                    ...meta,
                    serial: found.serial,
                    consolePort: found.consolePort,
                    ...(found.avd ? { avd: found.avd } : {}),
                    ...(found.grpcPort ? { grpcPort: found.grpcPort } : {}),
                    ...(found.device ? { device: found.device } : {}),
                  },
                },
              ]),
            ]
          return [
            avdExists(meta.avd).then((exists): [string, Probe] => [entry.id, { status: exists ? "stopped" : "gone" }]),
          ]
        }),
      ),
    )
  },

  async snapshot(entry) {
    const serial = requireSerial(entry)
    const device = await attach(serial).catch(() => undefined)
    if (!device) {
      const data = await run([adb(), "-s", serial, "exec-out", "screencap", "-p"])
      return { mime: "image/png", data, ...size(data) }
    }
    const [message, rotation] = await Promise.all([
      device.connection.unary("getScreenshot", imageFormat(0)),
      displayRotation(serial).catch(() => device.rotation),
    ])
    device.rotation = rotation
    const frame = parseImage(message)
    return encode(frame, rotation, 85)
  },

  async stream(entry, sink, signal) {
    const serial = requireSerial(entry)
    const device = await attach(serial)
    const state = {
      latest: undefined as Frame | undefined,
      shown: undefined as Frame | undefined,
      busy: false,
      announced: "",
    }
    const pump = async (): Promise<void> => {
      const frame = state.latest
      if (state.busy || !frame || signal.aborted) return
      state.busy = true
      state.latest = undefined
      const rotation = device.rotation
      const image = await encode(frame, rotation, streamQuality).catch(() => undefined)
      state.busy = false
      if (!image || signal.aborted) return pump()
      const key = `${image.width}x${image.height}`
      if (key !== state.announced) {
        state.announced = key
        sink.hello({ format: "jpeg", width: image.width, height: image.height })
        sink.meta({ rotation: rotation * 90 })
      }
      state.shown = frame
      sink.frame(image.data, { capturedAt: frame.capturedAt })
      return pump()
    }
    const watch = setInterval(() => {
      void displayRotation(serial)
        .then((rotation) => {
          if (rotation === device.rotation) return
          device.rotation = rotation
          // A rotation alone does not change the panel, so the emulator sends no frame: redraw the last one.
          state.latest ??= state.shown
          void pump()
        })
        .catch(() => {})
    }, rotationPollMs)
    device.rotation = await displayRotation(serial).catch(() => device.rotation)
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
      .finally(() => clearInterval(watch))
  },

  async input(entry, event) {
    const serial = requireSerial(entry)
    const device = await attach(serial)
    const panel = (device.panel ??= await panelSize(serial))
    await plan(event, { rotation: device.rotation, panel }).reduce(
      (chain, step) => chain.then(() => perform(serial, device, step)),
      Promise.resolve(),
    )
  },
}

/** Frames are scaled by the emulator to fit this box, so portrait and landscape panels keep the same detail. */
export const streamBox = 1200
const streamQuality = 70
const rotationPollMs = 1_500
/** Raw pressure for a touching contact; zero lifts it. */
const pressure = 1024
/** The pointer used to emulate scroll gestures, kept apart from the iPhone's finger indices. */
const scrollPointer = 9

type Frame = { readonly rgba: Uint8Array; readonly width: number; readonly height: number; readonly capturedAt: number }

type Device = {
  connection: Connection
  rotation: number
  panel?: { readonly width: number; readonly height: number }
}

const devices = new Map<string, Promise<Device>>()

/** One gRPC connection per emulator, opened on demand and reopened when the emulator restarts. */
function attach(serial: string) {
  const existing = devices.get(serial)
  const fresh = () => {
    const created = grpcEndpoint(serial).then((endpoint): Device => ({ connection: connect(endpoint), rotation: 0 }))
    devices.set(serial, created)
    created.catch(() => devices.delete(serial))
    return created
  }
  if (!existing) return fresh()
  return existing.then((device) => (device.connection.closed ? fresh() : device))
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

async function perform(serial: string, device: Device, step: Step) {
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
    await run([adb(), "-s", serial, "shell", step.command])
    return
  }
  if (step.type === "rotate") {
    await run([
      adb(),
      "-s",
      serial,
      "shell",
      `settings put system accelerometer_rotation 0 && settings put system user_rotation ${step.rotation}`,
    ])
    return
  }
  const previous = await device.connection
    .unary("getClipboard", new Uint8Array(0))
    .then((message) => decode(message).bytes(1))
    .catch(() => undefined)
  await device.connection.unary("setClipboard", pb.string(1, step.text))
  await run([adb(), "-s", serial, "shell", "input keyevent KEYCODE_PASTE"])
  // The paste is asynchronous in the app; give it a moment before putting the old clipboard back.
  await Bun.sleep(250)
  await device.connection.unary("setClipboard", previous ? pb.bytes(1, previous) : new Uint8Array(0)).catch(() => {})
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

/** Encodes a panel frame as an upright JPEG, rotating it the way the display is rotated. */
async function encode(
  frame: Frame,
  rotation: number,
  quality: number,
): Promise<Image & { width: number; height: number }> {
  const pipeline = new Bun.Image(bmp(frame.rgba, frame.width, frame.height))
  const turned = rotation === 0 ? pipeline : pipeline.rotate((360 - rotation * 90) % 360)
  // Copied into a plain ArrayBuffer, which the hub's frame and HTTP bodies require.
  const data = new Uint8Array(await turned.jpeg({ quality }).bytes())
  const swapped = rotation % 2 === 1
  return {
    mime: "image/jpeg",
    data,
    width: swapped ? frame.height : frame.width,
    height: swapped ? frame.width : frame.height,
  }
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
async function displayRotation(serial: string) {
  const output = await text(
    [adb(), "-s", serial, "shell", "dumpsys display 2>/dev/null | grep -m1 -o 'mCurrentOrientation=[0-3]'"],
    { timeout: 5_000 },
  )
  return Number(/=(\d)/.exec(output)?.[1] ?? 0)
}

/** The touch panel's pixel size: the physical display size, which an `wm size` override does not change. */
async function panelSize(serial: string) {
  const output = await text([adb(), "-s", serial, "shell", "wm size"], { timeout: 5_000 })
  const match = /Physical size:\s*(\d+)x(\d+)/.exec(output)
  if (!match) throw new Error("Could not read the emulator display size")
  return { width: Number(match[1]), height: Number(match[2]) }
}

function requireSerial(entry: Entry) {
  if (entry.meta.kind !== "android-emulator" || !entry.meta.serial) throw new Error("Emulator is not attached to adb")
  return entry.meta.serial
}

/** The gRPC port and token of a running emulator, turning gRPC on through the console when it is off. */
async function grpcEndpoint(serial: string) {
  const consolePort = Number(/^emulator-(\d+)$/.exec(serial)?.[1] ?? Number.NaN)
  if (!Number.isInteger(consolePort)) throw new Error(`Not an emulator serial: ${serial}`)
  const find = async () => (await discovered()).find((item) => item.consolePort === consolePort && item.grpcPort)
  const existing = await find()
  if (existing?.grpcPort) return { port: existing.grpcPort, token: existing.grpcToken }
  await text([adb(), "-s", serial, "emu", "grpc", String(consolePort + 3000)], { timeout: 10_000 })
  const started = await find()
  if (!started?.grpcPort) throw new Error("The emulator did not start its gRPC endpoint")
  return { port: started.grpcPort, token: started.grpcToken }
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
