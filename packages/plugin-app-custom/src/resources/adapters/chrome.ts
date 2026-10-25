import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import type { Input } from "../protocol.js"
import type { Resources } from "../rpc.js"
import { CDP, type ScreencastMetadata, type TargetInfo } from "./cdp.js"
import { size, text } from "./process.js"
import type { Adapter, Entry, Image, Probe, StreamSink } from "./types.js"

/**
 * Chrome adapter. It mirrors the headless (or headed) Chrome that `playwright-cli` opens for an agent.
 *
 * `playwright-cli` drives Chrome over `--remote-debugging-pipe`, which only its daemon can use. The plugin sets
 * `PLAYWRIGHT_MCP_CONFIG` for agent shells (`shellEnvironment`) to a config that adds `--remote-debugging-port=0`, so
 * Chrome also listens on a random loopback port and writes it to `<user-data-dir>/DevToolsActivePort`. The adapter finds
 * the daemon of a `-s=<session>` by its command line, its Chrome child, and that file; it never touches a Chrome it
 * did not find this way (such as a personal browser with its own debugging port).
 */

export const settings = {
  quality: 70,
  /** Lower quality and half size while the viewer scrolls, like t3code's preview stream. */
  motionQuality: 50,
  maxWidth: 1280,
  maxHeight: 2400,
  /** Chrome sends the next screencast frame only after an ack; pacing acks caps the frame rate (~15 fps). */
  ackPaceMs: 66,
  /** Chrome may drop the last frame of a burst; a still is captured once frames stop for this long. */
  settleMs: 200,
  motionFrames: 4,
  motionWindowMs: 300,
  /** Browser connections without stream or input for this long are closed. */
  idleMs: 60_000,
  /** CSS pixels a finger may move before a touch on a mouse-only page scrolls instead of clicking. */
  dragSlop: 8,
  /** Narrow viewports get stills rendered up to this many pixels wide (an iPhone screen is ~1,200 px). */
  sharpWidth: 1200,
  maxSharpScale: 3,
  /** Focus is probed this long after a tap, so page handlers can move it first. */
  focusDelayMs: 60,
}

export const launchArgs = ["--remote-debugging-port=0"]

/** Writes the Playwright config that agent shells point `PLAYWRIGHT_MCP_CONFIG` to; idempotent. */
export async function writeConfig(file: string) {
  await fs.mkdir(path.dirname(file), { recursive: true })
  await Bun.write(file, JSON.stringify({ browser: { launchOptions: { args: launchArgs } } }, null, 2) + "\n")
}

/**
 * Adds the CDP port config to an agent shell unless the shell already chose one. A `--config` flag or a
 * `.playwright/cli.config.json` in the working directory still wins; such browsers are listed without live view.
 */
export function shellEnvironment(env: Record<string, string | undefined>, file: string) {
  if (env.PLAYWRIGHT_MCP_CONFIG) return
  env.PLAYWRIGHT_MCP_CONFIG = file
}

export type Field =
  | "text"
  | "multiline"
  | "password"
  | "email"
  | "username"
  | "url"
  | "tel"
  | "number"
  | "search"
  | "one-time-code"

/** What the viewer needs to show the right keyboard. Never includes the field's value. */
export interface Focus {
  readonly editable: boolean
  readonly field?: Field
}

export interface Tab {
  readonly id: string
  readonly title: string
  readonly url: string
}

/** `meta` payload of the stream; the viewer replaces its state with each one. */
export interface ChromeState {
  readonly url: string
  readonly title: string
  readonly canGoBack: boolean
  readonly canGoForward: boolean
  readonly targetID: string
  readonly tabs: readonly Tab[]
  readonly focus: Focus
  /** Counts taps that landed on an editable field, so the viewer reopens its keyboard on the same field. */
  readonly editTaps: number
  /** CSS pixels of the mirrored viewport. */
  readonly viewport?: { readonly width: number; readonly height: number }
}

export interface Located {
  readonly pid: number
  readonly daemonPID: number
  readonly userDataDir: string
  readonly port?: number
  readonly headless: boolean
}

export function makeChromeAdapter(options: { readonly daemonDir?: string } = {}): Adapter & {
  readonly close: () => Promise<void>
} {
  const connections = new Map<string, Promise<Live>>()

  const live = (entry: Entry) => {
    const existing = connections.get(entry.id)
    if (existing) return existing
    const opening = open(entry).then(
      (value) => {
        value.cdp.closed.then(() => {
          if (connections.get(entry.id) === opening) connections.delete(entry.id)
        })
        return value
      },
      (error) => {
        connections.delete(entry.id)
        throw error
      },
    )
    connections.set(entry.id, opening)
    return opening
  }

  return {
    kind: "chrome",

    async probe(entries) {
      const processes = await listProcesses()
      const result = new Map<string, Probe>()
      await Promise.all(
        entries.map(async (entry) => {
          const meta = chromeMeta(entry)
          // An explicit registration by CDP endpoint (a browser not opened through `playwright-cli`).
          if (meta && !meta.session && meta.cdp) {
            const port = Number(URL.parse(meta.cdp)?.port)
            const pages = await listPages(port).catch(() => undefined)
            const target = pages && choose(pages, meta.targetID)
            result.set(
              entry.id,
              pages
                ? {
                    status: "running",
                    meta: {
                      ...meta,
                      ...(target ? { targetID: target.targetId, url: target.url, title: target.title } : {}),
                    },
                  }
                : { status: "gone" },
            )
            return
          }
          const session = sessionName(entry)
          const located = await locate(session, processes)
          if (!located) {
            result.set(entry.id, {
              status: (await sessionFileExists(session, options.daemonDir)) ? "stopped" : "gone",
            })
            return
          }
          if (located.port === undefined) {
            result.set(entry.id, { status: "running", meta: { kind: "chrome", session } })
            return
          }
          const pages = await listPages(located.port).catch(() => [])
          const target = choose(pages, chromeMeta(entry)?.targetID)
          result.set(entry.id, {
            status: "running",
            meta: {
              kind: "chrome",
              session,
              cdp: `http://127.0.0.1:${located.port}`,
              ...(target ? { targetID: target.targetId, url: target.url, title: target.title } : {}),
            },
          })
        }),
      )
      return result
    },

    async snapshot(entry) {
      const browser = await live(entry)
      return browser.use(() => browser.capture(90))
    },

    async stream(entry, sink, signal) {
      const browser = await live(entry)
      await browser.use(() => browser.stream(sink, signal))
    },

    async input(entry, event) {
      const browser = await live(entry)
      await browser.use(() => browser.input(event))
    },

    async close() {
      const all = [...connections.values()]
      connections.clear()
      await Promise.all(all.map((opening) => opening.then((browser) => browser.cdp.close()).catch(() => undefined)))
    },
  }

  async function open(entry: Entry) {
    const version: { webSocketDebuggerUrl: string } = await fetchJSON(await debuggingPort(entry), "/json/version")
    const cdp = await CDP.connect(version.webSocketDebuggerUrl)
    const browser = new Live(cdp, chromeMeta(entry)?.targetID)
    await browser.init().catch(async (error) => {
      await cdp.close()
      throw error
    })
    return browser
  }
}

async function debuggingPort(entry: Entry) {
  const meta = chromeMeta(entry)
  if (meta && !meta.session && meta.cdp) return Number(URL.parse(meta.cdp)?.port)
  const session = sessionName(entry)
  const located = await locate(session, await listProcesses())
  if (!located) throw new Error(`O navegador da sessão ${session} do playwright-cli não está aberto.`)
  if (located.port === undefined)
    throw new Error(
      `O navegador da sessão ${session} foi aberto sem porta de depuração; feche e abra de novo com playwright-cli open.`,
    )
  return located.port
}

export const sessionName = (entry: Pick<Entry, "id" | "meta">) =>
  chromeMeta(entry)?.session ?? entry.id.replace(/^chrome:/, "")

const chromeMeta = (entry: Pick<Entry, "meta">): Resources.ChromeMeta | undefined =>
  entry.meta.kind === "chrome" ? entry.meta : undefined

export interface ProcessRow {
  readonly pid: number
  readonly ppid: number
  readonly command: string
}

export async function listProcesses() {
  return parseProcesses(await text(["/bin/ps", "-axww", "-o", "pid=,ppid=,command="], { timeout: 5_000 }))
}

export function parseProcesses(output: string): ProcessRow[] {
  return output.split("\n").flatMap((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line)
    return match ? [{ pid: Number(match[1]), ppid: Number(match[2]), command: match[3] }] : []
  })
}

/** Finds the Chrome that the `playwright-cli` daemon of `session` launched, and its CDP port if it has one. */
export async function locate(session: string, processes: readonly ProcessRow[]): Promise<Located | undefined> {
  const daemons = processes.filter((row) => daemonSession(row.command) === session)
  const browsers = processes
    .filter((row) => daemons.some((daemon) => daemon.pid === row.ppid))
    .filter((row) => !row.command.includes(" --type=") && /--user-data-dir=/.test(row.command))
    // The newest daemon wins when two workspaces use the same session name.
    .toSorted((a, b) => b.pid - a.pid)
  const browser = browsers[0]
  if (!browser) return undefined
  const userDataDir = /--user-data-dir=(\S+)/.exec(browser.command)?.[1] ?? ""
  const port = await readActivePort(userDataDir)
  return {
    pid: browser.pid,
    daemonPID: browser.ppid,
    userDataDir,
    port,
    headless: /\s--headless(=|\s|$)/.test(browser.command),
  }
}

function daemonSession(command: string) {
  return /[/\\]cliDaemon\.js\s+(\S+)/.exec(command)?.[1]
}

async function readActivePort(userDataDir: string) {
  if (!userDataDir) return undefined
  const contents = await Bun.file(path.join(userDataDir, "DevToolsActivePort"))
    .text()
    .catch(() => "")
  const port = Number.parseInt(contents.split("\n")[0] ?? "", 10)
  return Number.isInteger(port) && port > 0 ? port : undefined
}

async function sessionFileExists(session: string, daemonDir = defaultDaemonDir()) {
  const hashes = await fs.readdir(daemonDir).catch(() => [])
  const found = await Promise.all(
    hashes.map((hash) => Bun.file(path.join(daemonDir, hash, `${session}.session`)).exists()),
  )
  return found.includes(true)
}

function defaultDaemonDir() {
  return path.join(os.homedir(), "Library", "Caches", "ms-playwright", "daemon")
}

async function fetchJSON<T>(port: number, pathname: string): Promise<T> {
  const response = await fetch(`http://127.0.0.1:${port}${pathname}`, { signal: AbortSignal.timeout(3_000) })
  if (!response.ok) throw new Error(`CDP ${pathname} answered ${response.status}`)
  return response.json() as Promise<T>
}

async function listPages(port: number) {
  const targets: { id: string; type: string; title: string; url: string }[] = await fetchJSON(port, "/json/list")
  return targets
    .filter((target) => target.type === "page" && !target.url.startsWith("chrome://"))
    .map((target) => ({ targetId: target.id, type: target.type, title: target.title, url: target.url }))
}

/** The followed tab if it still exists, else the newest page that is not blank, else any page. */
export function choose<T extends Pick<TargetInfo, "targetId" | "url">>(pages: readonly T[], preferred?: string) {
  return (
    pages.find((page) => page.targetId === preferred) ??
    pages.findLast((page) => page.url !== "about:blank") ??
    pages.at(-1)
  )
}

/** Normalizes what the viewer typed into the address bar. */
export function normalizeURL(input: string) {
  const value = input.trim()
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) && !/^[^/:]+:\d+/.test(value)) return value
  const local = /^(localhost|127\.|\[::1\]|0\.0\.0\.0|10\.|192\.168\.|[^/:]+\.local\b)/i.test(value)
  return `${local ? "http" : "https"}://${value}`
}

const modifierBits = { alt: 1, control: 2, meta: 4, shift: 8 } as const

export function modifiers(names: readonly (keyof typeof modifierBits)[] = []) {
  return names.reduce((bits, name) => bits | modifierBits[name], 0)
}

const namedKeys: Record<string, { code: string; keyCode: number; text?: string }> = {
  Enter: { code: "Enter", keyCode: 13, text: "\r" },
  Tab: { code: "Tab", keyCode: 9 },
  Backspace: { code: "Backspace", keyCode: 8 },
  Delete: { code: "Delete", keyCode: 46 },
  Escape: { code: "Escape", keyCode: 27 },
  ArrowLeft: { code: "ArrowLeft", keyCode: 37 },
  ArrowUp: { code: "ArrowUp", keyCode: 38 },
  ArrowRight: { code: "ArrowRight", keyCode: 39 },
  ArrowDown: { code: "ArrowDown", keyCode: 40 },
  Home: { code: "Home", keyCode: 36 },
  End: { code: "End", keyCode: 35 },
  PageUp: { code: "PageUp", keyCode: 33 },
  PageDown: { code: "PageDown", keyCode: 34 },
  " ": { code: "Space", keyCode: 32, text: " " },
}

/** CDP key events for a DOM key name or a single character. */
export function keyEvents(key: string, bits: number) {
  const named = namedKeys[key]
  const character = !named && [...key].length === 1 ? key : undefined
  const upper = character?.toUpperCase() ?? ""
  const code = named?.code ?? (/^[a-z]$/i.test(upper) ? `Key${upper}` : /^\d$/.test(upper) ? `Digit${upper}` : "")
  const keyCode = named?.keyCode ?? (upper ? upper.charCodeAt(0) : 0)
  // With Control/Meta held a character is a shortcut, not text.
  const printable = (named?.text ?? character) && (bits & (modifierBits.control | modifierBits.meta)) === 0
  const typed = printable ? (named?.text ?? character) : undefined
  return [
    {
      type: typed ? ("keyDown" as const) : ("rawKeyDown" as const),
      key,
      code,
      windowsVirtualKeyCode: keyCode,
      modifiers: bits,
      ...(typed ? { text: typed, unmodifiedText: typed } : {}),
    },
    { type: "keyUp" as const, key, code, windowsVirtualKeyCode: keyCode, modifiers: bits },
  ]
}

/** Runs in the page: classifies the focused editable element (through shadow roots and same-origin frames). */
export const focusScript = `(() => {
  const classify = (element) => {
    if (element.isContentEditable) return { editable: true, field: "multiline" }
    if (element.tagName === "TEXTAREA") return element.disabled || element.readOnly ? { editable: false } : { editable: true, field: "multiline" }
    if (element.tagName !== "INPUT" || element.disabled || element.readOnly) return { editable: false }
    const type = (element.type || "text").toLowerCase()
    if (["button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit"].includes(type)) return { editable: false }
    const auto = (element.getAttribute("autocomplete") || "").toLowerCase()
    if (type === "password" || /(current|new)-password/.test(auto)) return { editable: true, field: "password" }
    if (/one-time-code/.test(auto)) return { editable: true, field: "one-time-code" }
    if (/username/.test(auto)) return { editable: true, field: "username" }
    if (type === "email" || /email/.test(auto)) return { editable: true, field: "email" }
    if (["url", "tel", "number", "search"].includes(type)) return { editable: true, field: type }
    return { editable: true, field: "text" }
  }
  let element = document.activeElement
  for (let depth = 0; element && depth < 16; depth++) {
    if (element.shadowRoot && element.shadowRoot.activeElement) { element = element.shadowRoot.activeElement; continue }
    if (element.tagName === "IFRAME" || element.tagName === "FRAME") {
      let inner = null
      try { inner = element.contentDocument && element.contentDocument.activeElement } catch {}
      if (!inner) return { editable: true, field: "text" }
      element = inner
      continue
    }
    break
  }
  return element ? classify(element) : { editable: false }
})()`

const fields = new Set<string>([
  "text",
  "multiline",
  "password",
  "email",
  "username",
  "url",
  "tel",
  "number",
  "search",
  "one-time-code",
])

export function decodeFocus(value: unknown): Focus {
  if (typeof value !== "object" || value === null || !("editable" in value) || value.editable !== true)
    return { editable: false }
  const field = "field" in value && typeof value.field === "string" && fields.has(value.field) ? value.field : "text"
  // `fields` holds exactly the `Field` literals.
  return { editable: true, field: field as Field }
}

/** One connection to the browser, following one tab. Shared by snapshot, stream and input of a resource. */
class Live {
  sessionId = ""
  targetId = ""
  touch = false
  metrics?: ScreencastMetadata
  sink?: StreamSink
  scrolledAt = 0
  focus: Focus = { editable: false }
  editTaps = 0
  tabs: Tab[] = []
  history = { canGoBack: false, canGoForward: false }
  private users = 0
  private idle?: ReturnType<typeof setTimeout>
  private gesture?: { start: { x: number; y: number }; last: { x: number; y: number }; scrolling: boolean }
  private follow?: (targetId?: string) => Promise<void>

  constructor(
    readonly cdp: CDP,
    private readonly preferred?: string,
  ) {}

  async init() {
    void this.cdp.closed.then(() => clearTimeout(this.idle))
    await this.cdp.send("Target.setDiscoverTargets", { discover: true })
    const targets = await this.cdp.send("Target.getTargets", {})
    this.tabs = pagesOf(targets.targetInfos)
    const target = choose(targets.targetInfos.filter(isPage), this.preferred)
    if (!target) throw new Error("O navegador não tem nenhuma aba aberta.")
    await this.attach(target.targetId)
    this.cdp.on("Target.targetCreated", (event) => this.updateTab(event.targetInfo))
    this.cdp.on("Target.targetInfoChanged", (event) => this.updateTab(event.targetInfo))
    this.cdp.on("Target.targetDestroyed", (event) => {
      this.tabs = this.tabs.filter((tab) => tab.id !== event.targetId)
      if (event.targetId !== this.targetId) return this.publish()
      // Without a stream the next use reconnects and picks another tab.
      if (!this.follow) return void this.cdp.close()
      void this.follow().catch(() => this.cdp.close())
      this.publish()
    })
    this.cdp.on("Page.frameNavigated", (event, sessionId) => {
      if (sessionId === this.sessionId && !event.frame.parentId) void this.refreshHistory()
    })
    this.cdp.on("Page.navigatedWithinDocument", (_event, sessionId) => {
      if (sessionId === this.sessionId) void this.refreshHistory()
    })
    this.cdp.on("Page.loadEventFired", (_event, sessionId) => {
      if (sessionId !== this.sessionId) return
      void this.refreshTab()
      void this.probeFocus()
    })
  }

  private async attach(targetId: string) {
    if (this.sessionId)
      await this.cdp.send("Target.detachFromTarget", { sessionId: this.sessionId }).catch(() => undefined)
    const attached = await this.cdp.send("Target.attachToTarget", { targetId, flatten: true })
    this.sessionId = attached.sessionId
    this.targetId = targetId
    this.metrics = undefined
    await this.cdp.send("Page.enable", {}, this.sessionId)
    const touch = await this.cdp
      .send("Runtime.evaluate", { expression: "navigator.maxTouchPoints > 0", returnByValue: true }, this.sessionId)
      .catch(() => ({ result: { value: false } }))
    this.touch = touch.result.value === true
    await this.refreshHistory()
  }

  /** Keeps the connection while `work` runs and closes it after `settings.idleMs` without any. */
  async use<A>(work: () => Promise<A>) {
    this.users++
    clearTimeout(this.idle)
    try {
      return await work()
    } finally {
      this.users--
      if (this.users === 0) this.idle = setTimeout(() => void this.cdp.close(), settings.idleMs).unref()
    }
  }

  /**
   * A still of the viewport. Screencasts ignore the emulated device scale, so a phone-sized page streams at about
   * 400 px wide; stills of narrow viewports render at up to `settings.sharpWidth` pixels so text stays legible.
   */
  async capture(quality: number): Promise<Image> {
    const metrics = await this.cdp.send("Page.getLayoutMetrics", {}, this.sessionId)
    const viewport = metrics.cssVisualViewport
    const scale = Math.min(settings.maxSharpScale, settings.sharpWidth / viewport.clientWidth)
    const shot = await this.cdp.send(
      "Page.captureScreenshot",
      {
        format: "jpeg",
        quality,
        optimizeForSpeed: true,
        ...(scale > 1.2
          ? {
              clip: {
                x: viewport.pageX,
                y: viewport.pageY,
                width: viewport.clientWidth,
                height: viewport.clientHeight,
                scale: Math.round(scale * 100) / 100,
              },
            }
          : {}),
      },
      this.sessionId,
    )
    const data = Buffer.from(shot.data, "base64")
    return { mime: "image/jpeg", data, ...size(data) }
  }

  async stream(sink: StreamSink, signal: AbortSignal) {
    this.sink = sink
    let frameSize = { width: 0, height: 0 }
    let started = false
    let lastAck = 0
    let motion = false
    let restarting = Promise.resolve()
    let mayHaveDropped = false
    let inFlight = 0
    let settle: ReturnType<typeof setTimeout> | undefined
    let previous = ""
    const recent: number[] = []

    const start = (scale: number) => {
      restarting = restarting.then(async () => {
        await this.cdp.send("Page.stopScreencast", {}, this.sessionId).catch(() => undefined)
        await this.cdp
          .send(
            "Page.startScreencast",
            {
              format: "jpeg",
              quality: scale < 1 ? settings.motionQuality : settings.quality,
              maxWidth: Math.round(settings.maxWidth * scale),
              maxHeight: Math.round(settings.maxHeight * scale),
              everyNthFrame: 1,
            },
            this.sessionId,
          )
          .catch(() => undefined)
      })
      return restarting
    }

    const emit = (data: Uint8Array, capturedAt: number) => {
      const next = size(data)
      if (next && (next.width !== frameSize.width || next.height !== frameSize.height)) {
        frameSize = next
        sink.hello({
          format: "jpeg",
          width: next.width,
          height: next.height,
          ...(this.metrics ? { scale: this.metrics.deviceWidth / next.width } : {}),
        })
        this.publish()
      }
      sink.frame(data, { keyframe: true, capturedAt })
    }

    // Stills pause the screencast: a scaled capture repaints, which would otherwise come back as a blurry frame.
    const still = () => {
      restarting = restarting.then(async () => {
        await this.cdp.send("Page.stopScreencast", {}, this.sessionId).catch(() => undefined)
        const image = await this.capture(settings.quality).catch(() => undefined)
        if (image) emit(image.data, Date.now())
      })
      return start(motion ? 0.5 : 1)
    }
    const sharpens = () => (this.metrics?.deviceWidth ?? settings.sharpWidth) * 1.2 < settings.sharpWidth

    const offFrame = this.cdp.on("Page.screencastFrame", (frame, sessionId) => {
      if (sessionId !== this.sessionId) return
      started = true
      const arrived = Date.now()
      const ack = () =>
        void this.cdp
          .send("Page.screencastFrameAck", { sessionId: frame.sessionId }, this.sessionId)
          .catch(() => undefined)
      // A restarted screencast repeats its last frame; that would replace a sharper still with the same content.
      if (frame.data === previous) return ack()
      previous = frame.data
      const resized =
        this.metrics?.deviceWidth !== frame.metadata.deviceWidth ||
        this.metrics?.deviceHeight !== frame.metadata.deviceHeight
      this.metrics = frame.metadata
      if (resized) this.publish()
      if (inFlight > 0) mayHaveDropped = true
      inFlight++
      recent.push(arrived)
      while (recent.length > 0 && recent[0]! < arrived - settings.motionWindowMs) recent.shift()
      if (!motion && recent.length >= settings.motionFrames && arrived - this.scrolledAt < settings.motionWindowMs) {
        motion = true
        void start(0.5)
      }
      clearTimeout(settle)
      settle = setTimeout(() => {
        if (!motion && !mayHaveDropped && !sharpens()) return
        mayHaveDropped = false
        motion = false
        recent.length = 0
        void still()
      }, settings.settleMs)
      emit(Buffer.from(frame.data, "base64"), frame.metadata.timestamp ? frame.metadata.timestamp * 1000 : arrived)
      const wait = Math.max(0, lastAck + settings.ackPaceMs - arrived)
      setTimeout(() => {
        lastAck = Date.now()
        inFlight--
        ack()
      }, wait)
    })

    const done = new Promise<void>((resolve) => {
      if (signal.aborted) return resolve()
      signal.addEventListener("abort", () => resolve(), { once: true })
      void this.cdp.closed.then(() => resolve())
    })

    // Moves the stream to another tab: the one the viewer picked, or any other when the followed tab closes.
    this.follow = async (targetId) => {
      const pages = await this.cdp.send("Target.getTargets", {}).catch(() => ({ targetInfos: [] }))
      const next = choose(pages.targetInfos.filter(isPage), targetId)
      if (!next) return void (await this.cdp.close())
      await this.cdp.send("Page.stopScreencast", {}, this.sessionId).catch(() => undefined)
      await this.attach(next.targetId)
      previous = ""
      frameSize = { width: 0, height: 0 }
      await still()
      this.publish()
    }

    try {
      this.publish()
      await start(1)
      // An idle page does not repaint for a new screencast; start from a still unless a frame beat it.
      if (!started || sharpens()) await still()
      await done
    } finally {
      offFrame()
      clearTimeout(settle)
      this.follow = undefined
      this.sink = undefined
      await this.cdp.send("Page.stopScreencast", {}, this.sessionId).catch(() => undefined)
    }
    if (!signal.aborted) throw new Error("A conexão com o navegador foi encerrada.")
  }

  async input(event: Input) {
    switch (event.type) {
      case "touch":
        return this.touchEvent(event)
      case "scroll": {
        const viewport = await this.viewport()
        this.scrolledAt = Date.now()
        await this.cdp.send(
          "Input.dispatchMouseEvent",
          {
            type: "mouseWheel",
            x: event.x * viewport.width,
            y: event.y * viewport.height,
            deltaX: event.dx * viewport.width,
            deltaY: event.dy * viewport.height,
          },
          this.sessionId,
        )
        return
      }
      case "key": {
        for (const params of keyEvents(event.key, modifiers(event.modifiers)))
          await this.cdp.send("Input.dispatchKeyEvent", params, this.sessionId)
        if (event.key === "Tab" || event.key === "Enter" || event.key === "Escape") this.probeFocusSoon()
        return
      }
      case "text":
        // Never log `event.text`: it may be a password.
        if (event.text.length > 0) await this.cdp.send("Input.insertText", { text: event.text }, this.sessionId)
        return
      case "navigate":
        return this.navigate(event)
      case "button":
        if (event.button === "back") return this.navigate({ type: "navigate", action: "back" })
        return
    }
  }

  private async touchEvent(event: Extract<Input, { type: "touch" }>) {
    const viewport = await this.viewport()
    const x = event.x * viewport.width
    const y = event.y * viewport.height
    if (this.touch) {
      const type = {
        began: "touchStart" as const,
        moved: "touchMove" as const,
        ended: "touchEnd" as const,
        cancelled: "touchCancel" as const,
      }[event.phase]
      const points = type === "touchEnd" || type === "touchCancel" ? [] : [{ x, y, id: event.pointer ?? 0 }]
      await this.cdp.send("Input.dispatchTouchEvent", { type, touchPoints: points }, this.sessionId)
    }
    if (!this.touch) await this.mouseFromTouch(event.phase, x, y, event.pointer ?? 0)
    if (event.phase === "ended" && (event.pointer ?? 0) === 0) this.probeFocusSoon(true)
  }

  /**
   * Pages without touch emulation (Playwright's default desktop context) get mouse input. A finger that stays put is a
   * click at the release point; one that moves past `settings.dragSlop` scrolls with the wheel instead of dragging a
   * text selection, like a phone browser. Only the first finger is used.
   */
  private async mouseFromTouch(
    phase: "began" | "moved" | "ended" | "cancelled",
    x: number,
    y: number,
    pointer: number,
  ) {
    if (pointer !== 0) return
    if (phase === "began") {
      this.gesture = { start: { x, y }, last: { x, y }, scrolling: false }
      this.scrolledAt = 0
      return
    }
    const gesture = this.gesture
    if (!gesture) return
    if (phase === "moved") {
      if (!gesture.scrolling && Math.hypot(x - gesture.start.x, y - gesture.start.y) < settings.dragSlop) return
      gesture.scrolling = true
      this.scrolledAt = Date.now()
      const deltaX = gesture.last.x - x
      const deltaY = gesture.last.y - y
      gesture.last = { x, y }
      await this.cdp.send(
        "Input.dispatchMouseEvent",
        { type: "mouseWheel", x: gesture.start.x, y: gesture.start.y, deltaX, deltaY },
        this.sessionId,
      )
      return
    }
    this.gesture = undefined
    if (phase === "cancelled" || gesture.scrolling) return
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y, buttons: 0 }, this.sessionId)
    await this.cdp.send(
      "Input.dispatchMouseEvent",
      { type: "mousePressed", x, y, button: "left", buttons: 1, clickCount: 1 },
      this.sessionId,
    )
    await this.cdp.send(
      "Input.dispatchMouseEvent",
      { type: "mouseReleased", x, y, button: "left", buttons: 0, clickCount: 1 },
      this.sessionId,
    )
  }

  private async navigate(event: Extract<Input, { type: "navigate" }>) {
    if (event.action === "reload") return void (await this.cdp.send("Page.reload", {}, this.sessionId))
    if (event.action === "tab") {
      if (!event.target || event.target === this.targetId || !this.tabs.some((tab) => tab.id === event.target)) return
      await this.cdp.send("Target.activateTarget", { targetId: event.target }).catch(() => undefined)
      if (this.follow) return this.follow(event.target)
      await this.attach(event.target)
      return this.publish()
    }
    if (event.action === "url") {
      if (!event.url?.trim()) return
      await this.cdp.send("Page.navigate", { url: normalizeURL(event.url) }, this.sessionId)
      return
    }
    const history = await this.cdp.send("Page.getNavigationHistory", {}, this.sessionId)
    const entry = history.entries[history.currentIndex + (event.action === "back" ? -1 : 1)]
    if (entry) await this.cdp.send("Page.navigateToHistoryEntry", { entryId: entry.id }, this.sessionId)
  }

  private async viewport() {
    if (this.metrics) return { width: this.metrics.deviceWidth, height: this.metrics.deviceHeight }
    const metrics = await this.cdp.send("Page.getLayoutMetrics", {}, this.sessionId)
    return { width: metrics.cssVisualViewport.clientWidth, height: metrics.cssVisualViewport.clientHeight }
  }

  private probeFocusSoon(tap = false) {
    setTimeout(() => void this.probeFocus(tap), settings.focusDelayMs)
  }

  private async probeFocus(tap = false) {
    const result = await this.cdp
      .send("Runtime.evaluate", { expression: focusScript, returnByValue: true, silent: true }, this.sessionId)
      .catch(() => undefined)
    const focus = decodeFocus(result?.result.value)
    const tapped = tap && focus.editable
    if (!tapped && focus.editable === this.focus.editable && focus.field === this.focus.field) return
    this.focus = focus
    if (tapped) this.editTaps++
    this.publish()
  }

  private async refreshHistory() {
    const history = await this.cdp.send("Page.getNavigationHistory", {}, this.sessionId).catch(() => undefined)
    if (!history) return
    this.history = {
      canGoBack: history.currentIndex > 0,
      canGoForward: history.currentIndex < history.entries.length - 1,
    }
    this.focus = { editable: false }
    await this.refreshTab()
  }

  /** History titles lag behind the document; the target info has the current title and URL. */
  private async refreshTab() {
    const info = await this.cdp.send("Target.getTargetInfo", { targetId: this.targetId }).catch(() => undefined)
    if (info) return this.updateTab(info.targetInfo)
    this.publish()
  }

  private updateTab(info: TargetInfo) {
    if (!isPage(info)) return
    const tab = { id: info.targetId, title: info.title, url: info.url }
    const index = this.tabs.findIndex((existing) => existing.id === tab.id)
    this.tabs = index === -1 ? [...this.tabs, tab] : this.tabs.with(index, tab)
    this.publish()
  }

  state(): ChromeState {
    const tab = this.tabs.find((existing) => existing.id === this.targetId)
    return {
      url: tab?.url ?? "",
      title: tab?.title ?? "",
      ...this.history,
      targetID: this.targetId,
      tabs: this.tabs,
      focus: this.focus,
      editTaps: this.editTaps,
      ...(this.metrics ? { viewport: { width: this.metrics.deviceWidth, height: this.metrics.deviceHeight } } : {}),
    }
  }

  private publish() {
    this.sink?.meta({ ...this.state() })
  }
}

const isPage = (info: TargetInfo) => info.type === "page" && !info.url.startsWith("chrome://")

const pagesOf = (infos: readonly TargetInfo[]) =>
  infos.filter(isPage).map((info) => ({ id: info.targetId, title: info.title, url: info.url }))

/** The hub's Chrome adapter (`adapters/index.ts`). */
export const adapter = makeChromeAdapter()
