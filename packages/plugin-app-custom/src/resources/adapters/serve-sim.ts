import { existsSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import type { Input, Profile } from "../protocol.js"

/**
 * Supervises `serve-sim` (Expo Device Hub, Apache-2.0) for the iOS Simulator adapter: one loopback helper process per
 * simulator, started on demand, shared by its streams and input and stopped once idle. The helper captures the
 * simulator's IOSurface as MJPEG and injects HID input through SimulatorKit, so neither needs the Simulator window.
 * It binds 127.0.0.1 only and is never exposed: the hub reads its stream and writes
 * its input socket. See `docs/resources-ios-simulator.md`.
 */

/**
 * Frame bound, quality and rate per stream profile. `standard`: about 70 KB per frame instead of 250 KB at the native
 * 1206 × 2622. `economy` (cellular, Low Data Mode): about a third of that, at half the rate.
 */
export const streamOptions = {
  standard: { maxDimension: 1280, quality: 0.6, fps: 30 },
  economy: { maxDimension: 720, quality: 0.45, fps: 15 },
} satisfies Record<Profile, { maxDimension: number; quality: number; fps: number }>
const idleMs = 120_000
const startMs = 30_000
const pasteMs = 15_000
const reconnectAttempts = 5

// Release layout from packages/cli/script/custom-release.ts: <release>/plugin/index.js beside <release>/serve-sim.
const releaseScript = path.join(import.meta.dirname, "..", "serve-sim/node_modules/@expo/serve-sim/dist/serve-sim.js")

/** `serve-sim.js`: `OPENCODE_SERVE_SIM`, the release copy, or the plugin's own dependency when run from source. */
export function locate(env: Record<string, string | undefined> = process.env) {
  if (env.OPENCODE_SERVE_SIM) return env.OPENCODE_SERVE_SIM
  if (existsSync(releaseScript)) return releaseScript
  return path.join(path.dirname(fileURLToPath(import.meta.resolve("@expo/serve-sim/state"))), "serve-sim.js")
}

export type Orientation = "portrait" | "portrait_upside_down" | "landscape_left" | "landscape_right"

export interface Config {
  readonly width: number
  readonly height: number
  readonly orientation: Orientation
}

export interface Helper {
  readonly udid: string
  readonly port: number
  readonly config: () => Config | undefined
  /** Calls `listener` with every configuration the helper sends (size and orientation). */
  readonly onConfig: (listener: (config: Config) => void) => () => void
  /** Whether the input socket is open; video keeps flowing while it reconnects. */
  readonly inputAvailable: () => boolean
  /** Changes every time the input socket is (re)admitted; serve-sim has lifted every finger by then. */
  readonly inputGeneration: () => number
  readonly onInput: (listener: (available: boolean) => void) => () => void
  readonly send: (tag: number, body?: unknown) => void
  readonly paste: (text: string) => Promise<void>
  /** Switches serve-sim's encoder to `profile` (shared by every viewer of this simulator); no-op when it already is. */
  readonly profile: (profile: Profile) => Promise<void>
  readonly frames: (signal: AbortSignal) => AsyncGenerator<Part>
}

interface Running {
  readonly helper: Promise<Helper>
  readonly stop: () => void
  refs: number
  idle?: ReturnType<typeof setTimeout>
}

const running = new Map<string, Running>()

/** Shares one helper per simulator; `release` stops it after `idleMs` without users. */
export async function acquire(udid: string) {
  const existing = running.get(udid)
  const entry =
    existing ??
    // A helper that exits (crash, simulator shutdown) leaves the map, so the next viewer starts a new one.
    start(udid, () => {
      if (running.get(udid) === entry) running.delete(udid)
    })
  if (!existing) running.set(udid, entry)
  entry.refs++
  if (entry.idle) clearTimeout(entry.idle)
  entry.idle = undefined
  const helper = await entry.helper.catch((error: unknown) => {
    if (running.get(udid) === entry) running.delete(udid)
    entry.stop()
    throw error
  })
  return {
    helper,
    release: () => {
      entry.refs--
      if (entry.refs > 0 || running.get(udid) !== entry) return
      entry.idle = setTimeout(() => {
        if (entry.refs > 0 || running.get(udid) !== entry) return
        running.delete(udid)
        entry.stop()
      }, idleMs)
    },
  }
}

/** Runs `use` with the helper held; for one-off input outside a stream. */
export async function withHelper<T>(udid: string, use: (helper: Helper) => Promise<T> | T) {
  const lease = await acquire(udid)
  return Promise.resolve(use(lease.helper)).finally(lease.release)
}

export function stopAll() {
  running.forEach((entry) => entry.stop())
  running.clear()
}

process.once("exit", stopAll)

/**
 * Where serve-sim keeps its per-simulator records: inside the hub's own state directory, so each hub finds the
 * helpers it left behind (`recover`). Outside a hub (tests, scripts), a temporary directory per user state root.
 */
export function stateDirectory(env: Record<string, string | undefined> = process.env) {
  if (env.OPENCODE_RESOURCES_HUB_STATE) return path.join(env.OPENCODE_RESOURCES_HUB_STATE, "serve-sim")
  const key = new Bun.CryptoHasher("sha256")
    .update(env.XDG_STATE_HOME ?? os.homedir())
    .digest("hex")
    .slice(0, 12)
  return path.join(os.tmpdir(), "opencode-serve-sim", key)
}

/**
 * Stops the helpers a previous hub of this state directory left running (it died without its exit handler). Only
 * processes whose command line is still that helper's (serve-sim, the record's simulator and port) are stopped, so a
 * reused PID is never touched. The hub calls it once it holds its lock, before serving.
 */
export async function recover(state = stateDirectory()) {
  const files = await Array.fromAsync(new Bun.Glob("server-*.json").scan({ cwd: state })).catch(() => [])
  await Promise.all(files.map((file) => stopRecorded(path.join(state, file))))
}

function start(udid: string, exited: () => void): Running {
  const state = stateDirectory()
  const controller = new AbortController()
  const helper = (async () => {
    await stopRecorded(path.join(state, `server-${udid}.json`))
    const child = Bun.spawn(
      [
        process.execPath,
        locate(),
        "--no-preview",
        "--quiet",
        // The clipboard capability inserts a dylib into every app of the simulator; pasting does not need it.
        "--disable",
        "clipboard",
        "--max-dimension",
        String(streamOptions.standard.maxDimension),
        "--mjpeg-quality",
        String(streamOptions.standard.quality),
        "--mjpeg-fps",
        String(streamOptions.standard.fps),
        "--port",
        String(await freePort()),
        udid,
      ],
      {
        env: {
          ...process.env,
          BUN_BE_BUN: "1",
          SERVE_SIM_STATE_DIR: state,
          // Our patch of serve-sim (patches/@expo%2Fserve-sim@*.patch): without it, every start asks Device Hub to
          // open a separate window for the simulator. Capture and input do not need one.
          SERVE_SIM_NO_HOST_WINDOW: "1",
        },
        stdin: "ignore",
        stdout: "pipe",
        stderr: "ignore",
      },
    )
    controller.signal.addEventListener("abort", () => child.kill("SIGTERM"), { once: true })
    void child.exited.then(exited)
    const port = await startupPort(child.stdout, AbortSignal.any([controller.signal, AbortSignal.timeout(startMs)]))
    if (port === undefined) {
      child.kill("SIGTERM")
      throw new Error(`serve-sim did not start for ${udid}`)
    }
    return connect(udid, port, controller.signal, () => controller.abort())
  })()
  return { helper, stop: () => controller.abort(), refs: 0 }
}

/** The `--quiet` startup line is JSON with the bound port. */
async function startupPort(stdout: ReadableStream<Uint8Array>, signal: AbortSignal) {
  const reader = stdout.getReader()
  const decoder = new TextDecoder()
  signal.addEventListener("abort", () => void reader.cancel(), { once: true })
  const read = async (buffer: string): Promise<number | undefined> => {
    const line = buffer.split("\n").find((item) => item.trimStart().startsWith("{") && item.trimEnd().endsWith("}"))
    const port = line ? portOf(line) : undefined
    if (port !== undefined) return port
    const chunk = await reader.read().catch(() => ({ done: true as const, value: undefined }))
    if (chunk.done) return undefined
    return read(buffer + decoder.decode(chunk.value, { stream: true }))
  }
  const port = await read("")
  // Keep draining so the helper never blocks on a full pipe.
  void (async () => {
    while (!(await reader.read().catch(() => ({ done: true }))).done);
  })()
  return port
}

function portOf(line: string) {
  const value: unknown = JSON.parse(line)
  if (typeof value !== "object" || value === null || !("port" in value) || typeof value.port !== "number") return
  return value.port
}

async function freePort() {
  const server = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } })
  const port = server.port
  server.stop(true)
  return port
}

async function stopRecorded(file: string) {
  const record: unknown = await Bun.file(file)
    .json()
    .catch(() => undefined)
  if (typeof record !== "object" || record === null) return
  if (!("pid" in record) || !("port" in record) || !("device" in record)) return
  if (typeof record.pid !== "number" || typeof record.port !== "number" || typeof record.device !== "string") return
  const helper = record.pid
  const command = commandLine(helper)
  if (
    !command?.includes("serve-sim.js") ||
    !command.includes(record.device) ||
    !command.includes(`--port ${record.port}`)
  )
    return
  // The launcher (`--no-preview`) waits on the helper; stop it too when it is still ours.
  const parent = Number(
    Bun.spawnSync(["/bin/ps", "-o", "ppid=", "-p", String(helper)])
      .stdout.toString()
      .trim(),
  )
  const launcher = parent > 1 && commandLine(parent)?.includes("serve-sim.js --no-preview") ? [parent] : []
  const pids = [helper, ...launcher]
  pids.forEach((pid) => process.kill(pid, "SIGTERM"))
  for (let attempt = 0; attempt < 30 && pids.some(alive); attempt++) await Bun.sleep(100)
}

function commandLine(pid: number) {
  const result = Bun.spawnSync(["/bin/ps", "-o", "command=", "-p", String(pid)])
  return result.exitCode === 0 ? result.stdout.toString().trim() : undefined
}

function alive(pid: number) {
  return Bun.spawnSync(["/bin/kill", "-0", String(pid)]).exitCode === 0
}

const configTag = 0x82
const admittedTag = 0x83
const pasteReplyTag = 0x92

/**
 * Opens the helper's input socket and waits until it admits input. A socket that closes later is reopened with
 * backoff (serve-sim lifts the fingers of a closed socket, so `inputGeneration` changes); after `reconnectAttempts`
 * failures in a row `invalidate` stops the helper, and the next viewer starts a new one.
 */
export async function connect(
  udid: string,
  port: number,
  stopped: AbortSignal,
  invalidate: () => void,
  retry = { attempts: reconnectAttempts, delay: 250 },
): Promise<Helper> {
  const base = `127.0.0.1:${port}/helper/${udid}`
  const listeners = new Set<(config: Config) => void>()
  const inputListeners = new Set<(available: boolean) => void>()
  const pastes = new Map<number, (ok: boolean) => void>()
  const state = {
    socket: undefined as WebSocket | undefined,
    available: false,
    generation: 0,
    failures: 0,
    config: undefined as Config | undefined,
    nextPaste: 1,
    profile: "standard" as Profile,
    applying: Promise.resolve(),
  }
  const available = (value: boolean) => {
    if (state.available === value) return
    state.available = value
    inputListeners.forEach((listener) => listener(value))
  }
  const open = () =>
    new Promise<void>((resolve, reject) => {
      const socket = new WebSocket(`ws://${base}/ws`)
      socket.binaryType = "arraybuffer"
      state.socket = socket
      socket.onmessage = (event) => {
        if (!(event.data instanceof ArrayBuffer)) return
        const bytes = new Uint8Array(event.data)
        if (bytes[0] === admittedTag) {
          state.generation++
          state.failures = 0
          available(true)
          resolve()
        }
        if (bytes[0] === configTag) {
          const value = parseConfig(bytes.subarray(1))
          if (!value) return
          state.config = value
          listeners.forEach((listener) => listener(value))
        }
        if (bytes[0] === pasteReplyTag) {
          const reply = parseJSON(bytes.subarray(1))
          if (typeof reply !== "object" || reply === null || !("requestId" in reply)) return
          const id = Number(reply.requestId)
          pastes.get(id)?.("ok" in reply && reply.ok === true)
          pastes.delete(id)
        }
      }
      socket.onclose = () => {
        if (state.socket !== socket) return
        reject(new Error("serve-sim refused input"))
        available(false)
        pastes.forEach((done) => done(false))
        pastes.clear()
        if (stopped.aborted) return
        state.failures++
        if (state.failures > retry.attempts) return invalidate()
        const delay = Math.min(4_000, retry.delay * 2 ** (state.failures - 1))
        setTimeout(() => !stopped.aborted && void open().catch(() => undefined), delay)
      }
    })
  stopped.addEventListener("abort", () => state.socket?.close(), { once: true })
  await Promise.race([open(), Bun.sleep(startMs).then(() => Promise.reject(new Error("serve-sim input timed out")))])
  const send = (tag: number, body?: unknown) => {
    const socket = state.socket
    if (!state.available || socket?.readyState !== WebSocket.OPEN) throw new Error("Simulator input is unavailable")
    const json = body === undefined ? new Uint8Array(0) : new TextEncoder().encode(JSON.stringify(body))
    const message = new Uint8Array(1 + json.byteLength)
    message[0] = tag
    message.set(json, 1)
    socket.send(message)
  }
  return {
    udid,
    port,
    config: () => state.config,
    onConfig: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    inputAvailable: () => state.available,
    inputGeneration: () => state.generation,
    onInput: (listener) => {
      inputListeners.add(listener)
      return () => inputListeners.delete(listener)
    },
    send,
    paste: async (text) => {
      const requestId = state.nextPaste++
      const result = new Promise<boolean>((resolve) => pastes.set(requestId, resolve))
      send(0x12, { requestId, text })
      const ok = await Promise.race([result, Bun.sleep(pasteMs).then(() => false)])
      pastes.delete(requestId)
      if (!ok) throw new Error("Simulator paste failed")
    },
    profile: (profile) => {
      if (state.profile === profile) return state.applying
      state.profile = profile
      const options = streamOptions[profile]
      state.applying = state.applying
        .then(() =>
          fetch(`http://${base}/stream-settings`, {
            method: "PATCH",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              maxDimension: options.maxDimension,
              mjpegQuality: options.quality,
              mjpegFps: options.fps,
            }),
            signal: stopped,
          }),
        )
        .then(() => undefined)
        .catch(() => undefined)
      return state.applying
    },
    frames: (signal) => mjpeg(`http://${base}/stream.mjpeg`, AbortSignal.any([signal, stopped])),
  }
}

function parseJSON(bytes: Uint8Array): unknown {
  const text = new TextDecoder().decode(bytes)
  if (!text.startsWith("{")) return undefined
  return JSON.parse(text)
}

const orientations = new Set<string>(["portrait", "portrait_upside_down", "landscape_left", "landscape_right"])

export function parseConfig(bytes: Uint8Array): Config | undefined {
  const value = parseJSON(bytes)
  if (typeof value !== "object" || value === null) return
  if (!("width" in value) || !("height" in value) || !("orientation" in value)) return
  if (typeof value.width !== "number" || typeof value.height !== "number" || value.width <= 0 || value.height <= 0)
    return
  if (typeof value.orientation !== "string" || !orientations.has(value.orientation)) return
  return { width: value.width, height: value.height, orientation: value.orientation as Orientation }
}

export interface Part {
  readonly jpeg: Uint8Array
  /**
   * Epoch ms when the part's first bytes arrived. serve-sim sends no capture time over MJPEG; on loopback this is
   * within a millisecond or two of its capture callback, so it stands in for `capturedAt`.
   */
  readonly receivedAt: number
}

/** JPEG payloads of a `multipart/x-mixed-replace` MJPEG response; each part carries `Content-Length`. */
export async function* mjpeg(url: string, signal: AbortSignal) {
  const response = await fetch(url, { signal })
  if (!response.ok || !response.body) throw new Error(`serve-sim stream failed: ${response.status}`)
  yield* parts(response.body, signal)
}

export async function* parts(body: ReadableStream<Uint8Array>, signal?: AbortSignal): AsyncGenerator<Part> {
  const reader = body.getReader()
  signal?.addEventListener("abort", () => void reader.cancel().catch(() => undefined), { once: true })
  let buffer: Uint8Array = new Uint8Array(0)
  let started = 0
  while (true) {
    const chunk = await reader.read().catch(() => ({ done: true as const, value: undefined }))
    if (chunk.done) return
    if (started === 0) started = Date.now()
    buffer = concat(buffer, chunk.value)
    while (true) {
      const header = headerEnd(buffer)
      if (header < 0) break
      const length = Number(/content-length:\s*(\d+)/i.exec(latin1(buffer.subarray(0, header)))?.[1])
      if (!Number.isFinite(length)) {
        buffer = buffer.subarray(header + 4)
        continue
      }
      if (buffer.byteLength < header + 4 + length) break
      yield { jpeg: buffer.slice(header + 4, header + 4 + length), receivedAt: started }
      buffer = buffer.subarray(header + 4 + length)
      // More than the separator left means the next part arrived with this chunk; otherwise wait for its bytes.
      started = buffer.byteLength > 2 ? Date.now() : 0
    }
  }
}

function concat(left: Uint8Array, right: Uint8Array) {
  if (left.byteLength === 0) return right
  const merged = new Uint8Array(left.byteLength + right.byteLength)
  merged.set(left)
  merged.set(right, left.byteLength)
  return merged
}

function headerEnd(buffer: Uint8Array) {
  const limit = Math.min(buffer.byteLength - 3, 1024)
  for (let index = 0; index < limit; index++)
    if (buffer[index] === 13 && buffer[index + 1] === 10 && buffer[index + 2] === 13 && buffer[index + 3] === 10)
      return index
  return -1
}

function latin1(bytes: Uint8Array) {
  return new TextDecoder("latin1").decode(bytes)
}

// ── Input mapping ──────────────────────────────────────────────────────────

/**
 * Clockwise degrees a viewer rotates a frame to show it upright. serve-sim streams the raw portrait framebuffer and
 * reports the interface orientation separately; the protocol keeps input coordinates in that raw frame.
 */
export function rotation(config: Pick<Config, "width" | "height" | "orientation"> | undefined) {
  if (!config) return 0
  if (config.orientation === "portrait_upside_down") return 180
  if (config.width > config.height) return 0
  if (config.orientation === "landscape_left") return 90
  if (config.orientation === "landscape_right") return 270
  return 0
}

const rotateRight: Record<Orientation, Orientation> = {
  portrait: "landscape_right",
  landscape_right: "portrait_upside_down",
  portrait_upside_down: "landscape_left",
  landscape_left: "portrait",
}
const rotateLeft: Record<Orientation, Orientation> = {
  portrait: "landscape_left",
  landscape_left: "portrait_upside_down",
  portrait_upside_down: "landscape_right",
  landscape_right: "portrait",
}

const edge = { left: 1, top: 2, bottom: 3, right: 4 }
/** A touch starting in the bottom 7% of the upright screen is the home indicator swipe. */
const homeBand = 0.93

/** Upright (display) point for a raw frame point, the inverse of serve-sim's `rawPointForDisplayPoint`. */
export function displayPoint(degrees: number, x: number, y: number) {
  if (degrees === 90) return { x: 1 - y, y: x }
  if (degrees === 270) return { x: y, y: 1 - x }
  if (degrees === 180) return { x: 1 - x, y: 1 - y }
  return { x, y }
}

/** serve-sim's raw edge for the upright bottom edge. */
function rawBottomEdge(degrees: number) {
  if (degrees === 90) return edge.right
  if (degrees === 270) return edge.left
  if (degrees === 180) return edge.top
  return edge.bottom
}

const namedKeys: Record<string, number> = {
  Enter: 0x28,
  Escape: 0x29,
  Backspace: 0x2a,
  Tab: 0x2b,
  " ": 0x2c,
  Delete: 0x4c,
  ArrowRight: 0x4f,
  ArrowLeft: 0x50,
  ArrowDown: 0x51,
  ArrowUp: 0x52,
  Home: 0x4a,
  End: 0x4d,
  PageUp: 0x4b,
  PageDown: 0x4e,
}
const modifierKeys = { control: 0xe0, shift: 0xe1, alt: 0xe2, meta: 0xe3 }
const punctuation: Record<string, [number, boolean]> = {
  "-": [0x2d, false],
  _: [0x2d, true],
  "=": [0x2e, false],
  "+": [0x2e, true],
  "[": [0x2f, false],
  "{": [0x2f, true],
  "]": [0x30, false],
  "}": [0x30, true],
  "\\": [0x31, false],
  "|": [0x31, true],
  ";": [0x33, false],
  ":": [0x33, true],
  "'": [0x34, false],
  '"': [0x34, true],
  "`": [0x35, false],
  "~": [0x35, true],
  ",": [0x36, false],
  "<": [0x36, true],
  ".": [0x37, false],
  ">": [0x37, true],
  "/": [0x38, false],
  "?": [0x38, true],
}

/** USB HID keyboard usage (page 7) for a DOM key name or a US-keyboard character. */
export function keyUsage(key: string): { usage: number; shift: boolean } | undefined {
  if (key in namedKeys) return { usage: namedKeys[key], shift: false }
  if (key.length !== 1) return
  const code = key.charCodeAt(0)
  if (code >= 0x61 && code <= 0x7a) return { usage: 0x04 + code - 0x61, shift: false }
  if (code >= 0x41 && code <= 0x5a) return { usage: 0x04 + code - 0x41, shift: true }
  if (code >= 0x31 && code <= 0x39) return { usage: 0x1e + code - 0x31, shift: false }
  if (key === "0") return { usage: 0x27, shift: false }
  const shiftedDigit = "!@#$%^&*()".indexOf(key)
  if (shiftedDigit >= 0) return { usage: 0x1e + shiftedDigit, shift: true }
  const mark = punctuation[key]
  return mark ? { usage: mark[0], shift: mark[1] } : undefined
}

export type Message = readonly [tag: number, body?: unknown]

/**
 * Short US-keyboard text is typed as HID keys, so each typed character costs one socket message. Anything else
 * (accents, emoji, a pasted or autofilled block) goes through serve-sim's paste, one ⌘V for the whole text.
 */
export function typeable(text: string) {
  return text.length > 0 && text.length <= 32 && [...text].every((character) => keyUsage(character) !== undefined)
}

function press(name: string, modifiers: readonly (keyof typeof modifierKeys)[]): readonly Message[] {
  const key = keyUsage(name)
  if (!key) return []
  const held = [
    ...modifiers.map((modifier) => modifierKeys[modifier]),
    ...(key.shift && !modifiers.includes("shift") ? [modifierKeys.shift] : []),
  ]
  return [
    ...held.map((usage): Message => [0x06, { type: "down", usage }]),
    [0x06, { type: "down", usage: key.usage }],
    [0x06, { type: "up", usage: key.usage }],
    ...held.toReversed().map((usage): Message => [0x06, { type: "up", usage }]),
  ]
}

/**
 * Translates protocol input into serve-sim socket messages. Stateful per simulator: it remembers the active touch,
 * its home-indicator edge and a second finger, which serve-sim takes as one two-finger gesture.
 */
export function makeTranslator() {
  const fingers = new Map<number, { x: number; y: number }>()
  // Fingers still down after a two-finger gesture ended; ignored until lifted.
  const leftover = new Set<number>()
  let touchEdge = 0
  let pinching = false

  /** Ends whatever is still pressed and forgets it. */
  const lift = (): readonly Message[] => {
    const [first, second] = [...fingers.values()]
    const messages: Message[] =
      pinching && first && second
        ? [[0x05, { type: "end", x1: first.x, y1: first.y, x2: second.x, y2: second.y }]]
        : first
          ? [[0x03, { type: "end", x: first.x, y: first.y, edge: touchEdge }]]
          : []
    fingers.clear()
    leftover.clear()
    pinching = false
    touchEdge = 0
    return messages
  }

  const touch = (event: Extract<Input, { type: "touch" }>, degrees: number): readonly Message[] => {
    const pointer = event.pointer ?? 0
    // The viewer reuses a finger's number only after lifting it, so a new touch on a number still held means its
    // end never arrived (the gesture was interrupted): end the old gesture and start over.
    if (event.phase === "began" && (fingers.has(pointer) || leftover.has(pointer)))
      return [...lift(), ...touch(event, degrees)]
    const ending = event.phase === "ended" || event.phase === "cancelled"
    if (leftover.has(pointer)) {
      if (ending) leftover.delete(pointer)
      return []
    }
    if (event.phase === "began" && fingers.size >= 2) return []
    if (event.phase === "began" || fingers.has(pointer)) fingers.set(pointer, { x: event.x, y: event.y })
    if (!fingers.has(pointer)) return []
    if (pinching || fingers.size === 2) {
      const [first, second] = [...fingers.values()]
      // The first finger's single touch ends before the two-finger gesture begins.
      const lift: Message[] = pinching ? [] : [[0x03, { type: "end", x: first.x, y: first.y, edge: touchEdge }]]
      const type = !pinching ? "begin" : ending ? "end" : "move"
      pinching = !ending
      if (ending) {
        fingers.delete(pointer)
        fingers.forEach((_, other) => leftover.add(other))
        fingers.clear()
        touchEdge = 0
      }
      return [...lift, [0x05, { type, x1: first.x, y1: first.y, x2: second.x, y2: second.y }]]
    }
    if (event.phase === "began")
      touchEdge = displayPoint(degrees, event.x, event.y).y >= homeBand ? rawBottomEdge(degrees) : 0
    const type = event.phase === "began" ? "begin" : ending ? "end" : "move"
    const message: Message = [0x03, { type, x: event.x, y: event.y, edge: touchEdge }]
    if (ending) {
      fingers.delete(pointer)
      touchEdge = 0
    }
    return [message]
  }

  const translate = (event: Input, config: Config | undefined): readonly Message[] => {
    const degrees = rotation(config)
    if (event.type === "touch") return touch(event, degrees)
    if (event.type === "scroll") return [[0x0b, { dx: event.dx, dy: event.dy, x: event.x, y: event.y }]]
    if (event.type === "button") {
      if (event.button === "home") return [[0x04, { button: "home" }]]
      if (event.button === "lock") return [[0x04, { button: "lock" }]]
      if (event.button === "app-switcher") return [[0x04, { button: "app_switcher" }]]
      if (event.button === "rotate-left" || event.button === "rotate-right") {
        const current = config?.orientation ?? "portrait"
        const next = event.button === "rotate-left" ? rotateLeft[current] : rotateRight[current]
        return [[0x07, { orientation: next }]]
      }
      return []
    }
    if (event.type === "key") return press(event.key, event.modifiers ?? [])
    if (event.type === "text") return [...event.text].flatMap((character) => press(character, []))
    return []
  }
  return { translate, lift }
}
