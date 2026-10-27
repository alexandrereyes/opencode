import { existsSync } from "node:fs"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import type { Input } from "../protocol.js"
import type { Resources } from "../rpc.js"
import { CDP, type ScreencastMetadata, type TargetInfo, type Transport } from "./cdp.js"
import { findRelay, Relay, relayAlive, type RelayEndpoint } from "./chrome-relay.js"
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
  /** Lower quality and half the viewport while the viewer scrolls, like t3code's preview stream. */
  motionQuality: 50,
  maxWidth: 1280,
  maxHeight: 2400,
  /** Each screencast frame is acknowledged this long after it arrives; with Chromium's three unacknowledged frames
   * that caps the stream near 15 fps. */
  ackDelayMs: 200,
  /** A still follows once frames stop for this long. */
  settleMs: 200,
  motionFrames: 4,
  motionWindowMs: 400,
  /** Frames within this long of the viewer's input or a navigation belong to an interaction. */
  interactionMs: 1_500,
  /** Minimum time between sharp stills after an interaction or a burst of frames… */
  stillGapMs: 1_000,
  /** …and after a lone repaint while idle (a blinking caret refreshes at most this often). */
  idleStillGapMs: 2_500,
  /** The `economy` profile: smaller frames, lower quality and about 10 fps. */
  economy: { quality: 55, maxWidth: 800, maxHeight: 1600, ackDelayMs: 300, maxSharpScale: 1.5 },
  /** Browser connections without stream or input for this long are closed. */
  idleMs: 60_000,
  /** CSS pixels a finger may move before a touch on a mouse-only page scrolls instead of clicking. */
  dragSlop: 8,
  /** Sharp stills of emulated high-density pages are at most this many pixels wide (an iPhone draws a frame in
   * ~1,100 px) and `maxSharpScale` times their CSS size: 2× is about half the bytes of 3× and still sharp. */
  sharpWidth: 1200,
  maxSharpScale: 2,
  /** Pages emulating at least this device scale (`--device`, `--mobile`) get sharp stills. */
  sharpDensity: 1.2,
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
  const endpoints = new Map<string, Endpoint>()

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
      // The process table is read only when a browser has no validated endpoint yet (or lost it).
      let processes: Promise<ProcessRow[]> | undefined
      const scan = () => (processes ??= listProcesses())
      const result = new Map<string, Probe>()
      await Promise.all(
        entries.map(async (entry) => {
          const meta = chromeMeta(entry)
          const found = await endpoint(entry, scan).catch(() => undefined)
          if (!found) {
            const session = sessionName(entry)
            // An explicit registration by CDP endpoint disappears with its browser.
            if (meta && !meta.session && meta.cdp) return void result.set(entry.id, { status: "gone" })
            return void result.set(entry.id, {
              status: (await sessionFileExists(session, options.daemonDir)) ? "stopped" : "gone",
            })
          }
          // An attached browser (Alexandre's own Chrome) is alive while its daemon and Playwright server answer; its
          // tab is read only while someone watches, so a probe never talks to his browser.
          if (found.port === undefined)
            return void result.set(entry.id, {
              status: "running",
              meta: { kind: "chrome", session: sessionName(entry) },
            })
          const pages = await listPages(found.port).catch(() => [])
          const target = choose(pages, meta?.targetID)
          result.set(entry.id, {
            status: "running",
            meta: {
              kind: "chrome",
              ...(meta?.session || !meta?.cdp ? { session: sessionName(entry) } : {}),
              cdp: `http://127.0.0.1:${found.port}`,
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
      await browser.use(() => browser.stream(sink, signal, (economy) => sharpStill(entry, browser.density, economy)))
    },

    async input(entry, event) {
      const browser = await live(entry)
      browser.controlled = true
      await browser.use(() => browser.input(event))
    },

    async released(entry) {
      const browser = await connections.get(entry.id)?.catch(() => undefined)
      if (browser) browser.controlled = false
    },

    async close() {
      const all = [...connections.values()]
      connections.clear()
      await Promise.all(all.map((opening) => opening.then((browser) => browser.cdp.close()).catch(() => undefined)))
    },
  }

  async function open(entry: Entry) {
    const found = await endpoint(entry, listProcesses)
    if (found.relay) {
      const relay = await Relay.connect(found.relay)
      const browser = new Live(relay, undefined, true)
      await browser.init().catch(async (error) => {
        await relay.close()
        throw error
      })
      return browser
    }
    if (found.port === undefined)
      throw new Error(
        `O navegador da sessão ${sessionName(entry)} foi aberto sem porta de depuração; feche e abra de novo com playwright-cli open.`,
      )
    const cdp = await CDP.connect(found.browser)
    const browser = new Live(cdp, chromeMeta(entry)?.targetID)
    await browser.init().catch(async (error) => {
      await cdp.close()
      throw error
    })
    return browser
  }

  /**
   * A high-density still taken by Playwright itself (`page.screenshot({ scale: "device" })` through the session's
   * `run-code`), which restores its emulation afterwards, scaled down to at most `maxSharpScale`× CSS pixels.
   */
  async function sharpStill(entry: Entry, density: number, economy: boolean) {
    const quality = economy ? settings.economy.quality : settings.quality
    const found = await endpoint(entry, listProcesses)
    if (!found.daemon) return undefined
    const output = await text(
      [
        found.daemon.node,
        found.daemon.cli,
        `-s=${sessionName(entry)}`,
        "--raw",
        "run-code",
        `async page => (await page.screenshot({ type: "jpeg", quality: ${quality}, scale: "device" })).toString("base64")`,
      ],
      { cwd: found.daemon.cwd, timeout: 10_000 },
    )
    const shot = Buffer.from(String(JSON.parse(output)), "base64")
    const width = size(shot)?.width
    if (!width) return undefined
    const css = width / density
    const scale = economy ? settings.economy.maxSharpScale : settings.maxSharpScale
    const target = Math.round(Math.min(settings.sharpWidth, css * scale))
    if (target >= width) return new Uint8Array(shot)
    // Copied into a plain ArrayBuffer, which the hub's frames require.
    return new Uint8Array(await new Bun.Image(shot).resize(target).jpeg({ quality }).bytes())
  }

  /**
   * The browser endpoint of an entry. A cached endpoint is reused while `/json/version` still names the same browser
   * (a relaunched Chrome gets a new browser id, even on a reused port), or while an attached session's sockets answer;
   * otherwise the process table is scanned again.
   */
  async function endpoint(entry: Entry, scan: () => Promise<readonly ProcessRow[]>): Promise<Endpoint> {
    const cached = endpoints.get(entry.id)
    if (cached?.relay && (await relayAlive(cached.relay))) return cached
    if (cached?.port !== undefined && (await browserURL(cached.port)) === cached.browser) return cached
    endpoints.delete(entry.id)
    const found = await resolve(entry, scan)
    if (found.port !== undefined || found.relay) endpoints.set(entry.id, found)
    return found
  }
}

async function resolve(entry: Entry, scan: () => Promise<readonly ProcessRow[]>) {
  const meta = chromeMeta(entry)
  if (meta && !meta.session && meta.cdp) {
    const port = Number(URL.parse(meta.cdp)?.port)
    const browser = await browserURL(port)
    if (!browser) throw new Error(`Nenhum navegador responde em ${meta.cdp}.`)
    return { port, browser }
  }
  const session = sessionName(entry)
  const processes = await scan()
  const found = await locate(session, processes, meta?.workspace)
  // `attach` sessions (`--cdp=chrome`: Alexandre's own Chrome) launch no browser of their own: reach it through the
  // daemon's Playwright server instead (`chrome-relay.ts`).
  if (found.length === 0) {
    const relay = await findRelay(session, meta?.workspace === undefined ? "" : namespaceOf(meta.workspace))
    if (relay) return { browser: "", relay }
    throw new Error(`O navegador da sessão ${session} do playwright-cli não está aberto.`)
  }
  if (found.length > 1)
    throw new Error(`Há ${found.length} navegadores da sessão ${session} e não dá para saber qual é o do agente.`)
  const located = found[0]!
  return {
    port: located.port,
    browser: located.port === undefined ? "" : ((await browserURL(located.port)) ?? ""),
    daemon: await daemonOf(processes.find((row) => row.pid === located.daemonPID)),
  }
}

interface Endpoint {
  readonly port?: number
  /** An attached session's browser, reached through its daemon (`chrome-relay.ts`). */
  readonly relay?: RelayEndpoint
  /** The browser's `webSocketDebuggerUrl`, unique per launch. */
  readonly browser: string
  /** How to run `playwright-cli` against this browser's session: the daemon's Node, CLI and working directory. */
  readonly daemon?: { readonly node: string; readonly cli: string; readonly cwd: string }
}

async function daemonOf(row: ProcessRow | undefined) {
  const match = row && /^(\S+)\s+(\S*[/\\]lib[/\\]entry[/\\]cliDaemon\.js)\s/.exec(row.command)
  if (!row || !match) return undefined
  const cwd = (await workingDirectories([row.pid])).get(row.pid)
  if (!cwd) return undefined
  return { node: match[1]!, cli: path.join(path.dirname(match[2]!), "..", "tools", "cli-client", "cli.js"), cwd }
}

async function browserURL(port: number) {
  const version = await fetchJSON<{ webSocketDebuggerUrl?: string }>(port, "/json/version", 1_500).catch(
    () => undefined,
  )
  return version?.webSocketDebuggerUrl
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

/**
 * The Chromes that `playwright-cli` daemons of `session` launched in the namespace of `workspace` (where the agent's
 * shell ran), with their CDP ports. `playwright-cli` keeps sessions per namespace: the nearest ancestor directory with
 * `.playwright`, else one global namespace. A daemon's namespace comes from its working directory, read with `lsof`
 * only when it matters. Without `workspace` (older registrations) every namespace qualifies. More than one result is
 * ambiguous: callers must not guess.
 */
export async function locate(
  session: string,
  processes: readonly ProcessRow[],
  workspace?: string,
  directories: (pids: readonly number[]) => Promise<ReadonlyMap<number, string>> = workingDirectories,
): Promise<Located[]> {
  const daemons = processes.filter((row) => daemonSession(row.command) === session)
  if (daemons.length === 0) return []
  const wanted = workspace === undefined ? undefined : namespaceOf(workspace)
  const cwd = wanted === undefined ? undefined : await directories(daemons.map((daemon) => daemon.pid))
  const owners = daemons.filter((daemon) => {
    if (wanted === undefined) return true
    const directory = cwd?.get(daemon.pid)
    return directory !== undefined && namespaceOf(directory) === wanted
  })
  const browsers = processes.filter(
    (row) =>
      owners.some((daemon) => daemon.pid === row.ppid) &&
      !row.command.includes(" --type=") &&
      /--user-data-dir=/.test(row.command),
  )
  return Promise.all(
    browsers.map(async (browser) => {
      const userDataDir = /--user-data-dir=(\S+)/.exec(browser.command)?.[1] ?? ""
      return {
        pid: browser.pid,
        daemonPID: browser.ppid,
        userDataDir,
        port: await readActivePort(userDataDir),
        headless: /\s--headless(=|\s|$)/.test(browser.command),
      }
    }),
  )
}

/**
 * `playwright-cli`'s session namespace for a directory, as its client computes it: the nearest of up to ten ancestors
 * holding `.playwright`, or `""` for the global namespace shared by every other directory.
 */
export function namespaceOf(directory: string) {
  for (let current = directory, depth = 0; depth < 10; depth++) {
    if (existsSync(path.join(current, ".playwright"))) return current
    const parent = path.dirname(current)
    if (parent === current) break
    current = parent
  }
  return ""
}

/** Whether two shell directories reach the same `playwright-cli` sessions (unknown directories match any). */
export function sameNamespace(a: string | undefined, b: string | undefined) {
  return a === undefined || b === undefined || namespaceOf(a) === namespaceOf(b)
}

async function workingDirectories(pids: readonly number[]) {
  const output = await text(["/usr/sbin/lsof", "-a", "-d", "cwd", "-Fn", "-p", pids.join(",")], {
    timeout: 5_000,
  }).catch(() => "")
  const result = new Map<number, string>()
  let pid = 0
  for (const line of output.split("\n")) {
    if (line.startsWith("p")) pid = Number(line.slice(1))
    if (line.startsWith("n")) result.set(pid, line.slice(1))
  }
  return result
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

async function fetchJSON<T>(port: number, pathname: string, timeout = 3_000): Promise<T> {
  const response = await fetch(`http://127.0.0.1:${port}${pathname}`, { signal: AbortSignal.timeout(timeout) })
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
  /** The viewer's last input or the last navigation: frames shortly after it belong to an interaction. */
  interactedAt = 0
  /** Alexandre holds control (he sent input and has not given it back). */
  controlled = false
  /** The page's `devicePixelRatio`, which Playwright emulates for `--device`/`--mobile`. */
  density = 1
  /** Frames show the window rather than exactly the viewport (see `fitWindow`); sharp stills would not line up. */
  windowed = false
  focus: Focus = { editable: false }
  editTaps = 0
  tabs: Tab[] = []
  history = { canGoBack: false, canGoForward: false }
  private users = 0
  private idle?: ReturnType<typeof setTimeout>
  private gesture?: { start: { x: number; y: number }; last: { x: number; y: number }; scrolling: boolean }
  private follow?: (targetId?: string) => Promise<void>

  constructor(
    readonly cdp: Transport,
    private readonly preferred?: string,
    /** Alexandre's own browser through the relay: no Playwright stills, and a notice when the tab is hidden. */
    readonly attached = false,
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
      if (sessionId !== this.sessionId || event.frame.parentId) return
      // A new document (also when the agent navigates) deserves a prompt sharp still.
      this.interactedAt = Date.now()
      void this.refreshHistory()
    })
    this.cdp.on("Page.navigatedWithinDocument", (_event, sessionId) => {
      if (sessionId === this.sessionId) void this.refreshHistory()
    })
    this.cdp.on("Page.loadEventFired", (_event, sessionId) => {
      if (sessionId !== this.sessionId) return
      // `frameNavigated` can arrive before a history traversal commits its index; read it again once loaded.
      void this.refreshHistory().then(() => this.probeFocus())
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
    const device = await this.cdp
      .send(
        "Runtime.evaluate",
        { expression: "[navigator.maxTouchPoints > 0, devicePixelRatio]", returnByValue: true },
        this.sessionId,
      )
      .catch(() => ({ result: { value: [false, 1] } }))
    const value = Array.isArray(device.result.value) ? device.result.value : []
    this.touch = value[0] === true
    this.density = typeof value[1] === "number" ? value[1] : 1
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
   * A still of the viewport in CSS pixels. Never with `clip`: any clipped (or scaled) capture resets the device
   * metrics Playwright emulates, so the agent's page would drop to `devicePixelRatio` 1 (or the window's size).
   */
  async capture(quality: number): Promise<Image> {
    const shot = await this.cdp.send(
      "Page.captureScreenshot",
      { format: "jpeg", quality, optimizeForSpeed: true },
      this.sessionId,
    )
    const data = Buffer.from(shot.data, "base64")
    return { mime: "image/jpeg", data, ...size(data) }
  }

  /** `sharp` renders a high-density still through Playwright (see the adapter's `sharpStill`). */
  async stream(sink: StreamSink, signal: AbortSignal, sharp: (economy: boolean) => Promise<Uint8Array | undefined>) {
    this.sink = sink
    let frameSize = { width: 0, height: 0 }
    let started = false
    let motion = false
    let restarting = Promise.resolve()
    let settle: ReturnType<typeof setTimeout> | undefined
    let scheduled: ReturnType<typeof setTimeout> | undefined
    let previous = ""
    let seeded = false
    let sharpShown = false
    let stillAt = 0
    let burst = 0
    const recent: number[] = []

    // The viewers' profile: economy (cellular, Low Data Mode) trades size, quality and rate for bytes.
    const economy = () => sink.profile?.() === "economy"
    let profiled = economy()
    // Half the effective viewport while moving: a 393 px phone page would not shrink under a fixed 640 px cap.
    const start = (scale: number) => {
      profiled = economy()
      const full = profiled ? settings.economy : settings
      const width = Math.min(full.maxWidth, this.metrics?.deviceWidth ?? full.maxWidth)
      const height = Math.min(full.maxHeight, this.metrics?.deviceHeight ?? full.maxHeight)
      restarting = restarting.then(async () => {
        await this.cdp.send("Page.stopScreencast", {}, this.sessionId).catch(() => undefined)
        await this.cdp
          .send(
            "Page.startScreencast",
            {
              format: "jpeg",
              quality: scale < 1 ? settings.motionQuality : full.quality,
              maxWidth: scale < 1 ? Math.round(width * scale) : full.maxWidth,
              maxHeight: scale < 1 ? Math.round(height * scale) : full.maxHeight,
              everyNthFrame: 1,
            },
            this.sessionId,
          )
          .catch(() => undefined)
      })
      return restarting
    }

    const emit = (data: Uint8Array, capturedAt: number, sharp: boolean) => {
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
      sharpShown = sharp
      sink.frame(data, { keyframe: true, capturedAt })
    }

    // Stills pause the screencast: a scaled capture repaints, which would otherwise come back as a blurry frame.
    const still = () => {
      clearTimeout(scheduled)
      // The screencast pauses during the still; that silence is not the end of a burst.
      clearTimeout(settle)
      stillAt = Date.now()
      restarting = restarting.then(async () => {
        await this.cdp.send("Page.stopScreencast", {}, this.sessionId).catch(() => undefined)
        const sharpened = sharpens() ? await sharp(economy()).catch(() => undefined) : undefined
        const data = sharpened ?? (await this.capture(settings.quality).catch(() => undefined))?.data
        if (data) emit(data, Date.now(), sharpened !== undefined)
        seeded = true
      })
      return start(1)
    }
    const stillAfter = (gap: number) => {
      clearTimeout(scheduled)
      scheduled = setTimeout(() => void still(), Math.max(0, stillAt + gap - Date.now()))
    }
    // Screencasts ignore the emulated device scale, so a phone page streams ~400 px wide. Sharp stills run through
    // the agent's playwright-cli session, so they are taken only while Alexandre controls the browser (the agent is
    // locked out then and never waits behind them).
    const sharpens = () => !this.attached && this.controlled && !this.windowed && this.density >= settings.sharpDensity

    const offFrame = this.cdp.on("Page.screencastFrame", (frame, sessionId) => {
      if (sessionId !== this.sessionId) return
      started = true
      const arrived = Date.now()
      const ack = () =>
        void this.cdp
          .send("Page.screencastFrameAck", { sessionId: frame.sessionId }, this.sessionId)
          .catch(() => undefined)
      const resized =
        this.metrics?.deviceWidth !== frame.metadata.deviceWidth ||
        this.metrics?.deviceHeight !== frame.metadata.deviceHeight
      this.metrics = frame.metadata
      if (resized) {
        this.publish()
        void this.fitWindow()
      }
      // A restarted screencast repeats its last frame; that would replace a sharper still with the same content.
      if (frame.data === previous) return ack()
      // The first frame after a still repeats what the still just showed (sharper); it only seeds `previous`.
      if (seeded) {
        seeded = false
        previous = frame.data
        return ack()
      }
      // Chromium keeps up to three frames unacknowledged, so acknowledging each one `ackDelayMs` after it arrived
      // caps the stream near 3 / ackDelayMs (about 15 fps), whatever the page repaints. The ack also waits until some
      // viewer can take another frame (`whenReady`: the iPhone acknowledges each frame, three at most in flight), so
      // a slow link slows Chrome down instead of piling up frames nobody receives.
      const delay = profiled ? settings.economy.ackDelayMs : settings.ackDelayMs
      void Promise.all([Bun.sleep(delay), sink.whenReady?.(signal)]).then(ack)
      if (economy() !== profiled && !motion) void start(1)
      previous = frame.data
      burst++
      recent.push(arrived)
      while (recent.length > 0 && recent[0]! < arrived - settings.motionWindowMs) recent.shift()
      if (!motion && recent.length >= settings.motionFrames && arrived - this.scrolledAt < settings.motionWindowMs) {
        motion = true
        void start(0.5)
      }
      const interacting = arrived - this.interactedAt < settings.interactionMs
      // A lone repaint while nobody interacts (a blinking caret, a clock) would swap the sharp still for a blurry
      // frame; it is refreshed by a rate-limited still instead.
      if (!(sharpens() && sharpShown && !motion && !interacting && burst === 1))
        emit(
          Buffer.from(frame.data, "base64"),
          frame.metadata.timestamp ? frame.metadata.timestamp * 1000 : arrived,
          false,
        )
      const settled = () => {
        // Paced acks and the screencast restart leave gaps between motion frames; a finger still moving is no end.
        if (motion && Date.now() - this.scrolledAt < settings.motionWindowMs) {
          settle = setTimeout(settled, settings.settleMs)
          return
        }
        const frames = burst
        burst = 0
        recent.length = 0
        // The end of a scroll or animation gets its full-size still at once.
        if (motion) {
          motion = false
          return void still()
        }
        if (!sharpens()) return
        if (interacting || frames > 1 || !sharpShown) return stillAfter(settings.stillGapMs)
        stillAfter(settings.idleStillGapMs)
      }
      clearTimeout(settle)
      settle = setTimeout(settled, settings.settleMs)
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
      if (!started) await still()
      // Chrome paints no frames for a tab in the background or a minimized window; say why the picture is frozen.
      if (this.attached) {
        const visibility = await this.cdp
          .send("Runtime.evaluate", { expression: "document.visibilityState", returnByValue: true }, this.sessionId)
          .catch(() => undefined)
        if (visibility?.result.value === "hidden")
          sink.notice?.("A aba do agente está em segundo plano no seu Chrome; a imagem volta quando ela ficar visível.")
      }
      await done
    } finally {
      offFrame()
      clearTimeout(settle)
      clearTimeout(scheduled)
      this.follow = undefined
      this.sink = undefined
      await this.cdp.send("Page.stopScreencast", {}, this.sessionId).catch(() => undefined)
    }
    if (!signal.aborted) throw new Error("A conexão com o navegador foi encerrada.")
  }

  async input(event: Input) {
    this.interactedAt = Date.now()
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

  /**
   * Once Playwright resizes a page (`playwright-cli resize`), headless Chrome screencasts and captures its window
   * instead of the emulated viewport: an iPhone viewport (393 × 659) in the default window (500 × 572 inside) loses
   * its bottom 87 px. When the window cuts the viewport it grows to hold it (the emulation itself is never touched);
   * windows are at least 500 px wide, so a phone page then keeps a margin on the right.
   */
  private async fitWindow() {
    const frame = this.metrics
    if (!frame) return
    const metrics = await this.cdp.send("Page.getLayoutMetrics", {}, this.sessionId).catch(() => undefined)
    const viewport = metrics?.cssVisualViewport
    if (!viewport) return
    this.windowed =
      Math.abs(viewport.clientWidth - frame.deviceWidth) > 1 || Math.abs(viewport.clientHeight - frame.deviceHeight) > 1
    const grow = {
      width: Math.max(0, Math.ceil(viewport.clientWidth - frame.deviceWidth)),
      height: Math.max(0, Math.ceil(viewport.clientHeight - frame.deviceHeight)),
    }
    if (grow.width === 0 && grow.height === 0) return
    const window = await this.cdp.send("Browser.getWindowForTarget", { targetId: this.targetId }).catch(() => undefined)
    if (!window?.bounds.width || !window.bounds.height) return
    await this.cdp
      .send("Browser.setWindowBounds", {
        windowId: window.windowId,
        bounds: { width: window.bounds.width + grow.width, height: window.bounds.height + grow.height },
      })
      .catch(() => undefined)
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
      // A moving finger scrolls a touch page natively: that is motion too.
      if (type === "touchMove") this.scrolledAt = Date.now()
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
