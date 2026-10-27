import fs from "node:fs/promises"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import { CDPError, type Commands, type Events, type TargetInfo, type Transport } from "./cdp.js"

/**
 * DevTools access to a browser that a `playwright-cli` session *attached* to (`attach --cdp=chrome`: Alexandre's own,
 * visible Chrome), without opening a second DevTools connection to it.
 *
 * Chrome's "Allow remote debugging for this browser instance" (chrome://inspect) asks Alexandre to approve every new
 * DevTools client and serves no HTTP discovery (`/json/*` answer 404), so the adapter must not connect to it directly:
 * it would raise an approval dialog in his browser each time the hub connects. Every `playwright-cli` daemon also
 * exposes its browser as a Playwright server on a local socket (`~/Library/Caches/ms-playwright/b/<guid>`), so the hub
 * connects there with the daemon's own `playwright-core` and opens CDP sessions over the connection Alexandre already
 * approved for the agent.
 *
 * Only the session's current tab is ever exposed (`playwright-cli tab-list` marks it), never his other tabs. Commands
 * that would change his browser beyond that tab are refused: activating targets (which steals focus) and window
 * bounds. When the agent switches tabs, the relay reports the old one gone, so the viewer follows the new one.
 */

export interface RelayEndpoint {
  /** The daemon's Playwright browser server (a local socket path). */
  readonly server: string
  /** The `playwright-core` the daemon runs, so the client speaks its exact protocol. */
  readonly lib: string
  /** The daemon's command socket (`playwright-cli` client protocol), used for read-only `tab-list`. */
  readonly socket: string
}

export const relaySettings = {
  /** How often the agent's current tab is checked while the relay is connected. */
  followMs: 1_500,
}

/** Finds the relay of an attached `playwright-cli` session in the namespace `namespace` (`""` = global). */
export async function findRelay(
  session: string,
  namespace: string,
  directories: { readonly daemon?: string; readonly servers?: string } = {},
): Promise<RelayEndpoint | undefined> {
  const cache = path.join(os.homedir(), "Library", "Caches", "ms-playwright")
  const servers = await readJSON<ServerDescriptor>(directories.servers ?? path.join(cache, "b"))
  const sessions = await readJSON<SessionFile>(directories.daemon ?? path.join(cache, "daemon"), `${session}.session`)
  const server = servers.find(
    (item) => item.title === session && (item.workspaceDir ?? "") === namespace && item.endpoint,
  )
  const file = sessions.find((item) => (item.workspaceDir ?? "") === namespace && item.socketPath)
  if (!server?.endpoint || !server.playwrightLib || !file?.socketPath) return undefined
  if (!(await reachable(server.endpoint)) || !(await reachable(file.socketPath))) return undefined
  return { server: server.endpoint, lib: server.playwrightLib, socket: file.socketPath }
}

/** Whether both sockets of a relay still accept connections (the daemon and its browser are alive). */
export async function relayAlive(relay: RelayEndpoint) {
  return (await reachable(relay.server)) && (await reachable(relay.socket))
}

/** The session's current tab, as `playwright-cli tab-list` reports it: its index and URL. */
export async function currentTab(socket: string) {
  const output = await daemonCommand(socket, ["tab-list"])
  const line = output.split("\n").find((item) => /^- \d+: \(current\)/.test(item))
  const match = line && /^- (\d+): \(current\) \[.*\]\((.*)\)$/.exec(line)
  return match ? { index: Number(match[1]), url: match[2]! } : undefined
}

export class Relay implements Transport {
  readonly closed: Promise<void>
  private readonly listeners = new Map<string, Set<(params: unknown, sessionId?: string) => void>>()
  private readonly sessions = new Map<string, { page: Page; cdp: CDPSession; targetId: string }>()
  private readonly targets = new Map<Page, string>()
  private next = 1
  private following?: ReturnType<typeof setInterval>
  private current?: Page
  private checking = false

  private constructor(
    private readonly browser: Browser,
    private readonly endpoint: RelayEndpoint,
  ) {
    this.closed = new Promise((resolve) => browser.on("disconnected", () => resolve()))
    void this.closed.then(() => clearInterval(this.following))
  }

  static async connect(endpoint: RelayEndpoint) {
    const playwright: { chromium: { connect(endpoint: string, options: { timeout: number }): Promise<Browser> } } =
      await import(endpoint.lib)
    const relay = new Relay(await playwright.chromium.connect(endpoint.server, { timeout: 5_000 }), endpoint)
    await relay.follow().catch(async (error) => {
      await relay.close()
      throw error
    })
    relay.following = setInterval(() => {
      if (relay.checking) return
      relay.checking = true
      void relay
        .follow()
        .catch(() => undefined)
        .finally(() => (relay.checking = false))
    }, relaySettings.followMs)
    return relay
  }

  async send<M extends keyof Commands>(
    method: M,
    params: Commands[M]["params"],
    sessionId?: string,
  ): Promise<Commands[M]["result"]> {
    // Each branch returns the result shape `Commands` declares for its method.
    return (await this.dispatch(method, params, sessionId)) as Commands[M]["result"]
  }

  on<E extends keyof Events>(event: E, listener: (params: Events[E], sessionId?: string) => void) {
    const set = this.listeners.get(event) ?? new Set()
    this.listeners.set(event, set)
    // Events carry the shape declared in `Events` for their method.
    const wrapped = (params: unknown, sessionId?: string) => listener(params as Events[E], sessionId)
    set.add(wrapped)
    return () => void set.delete(wrapped)
  }

  async close() {
    clearInterval(this.following)
    await Promise.all([...this.sessions.values()].map((item) => item.cdp.detach().catch(() => undefined)))
    // A client connected to a browser server only disconnects; the agent's browser and session stay as they are.
    await this.browser.close().catch(() => undefined)
    return this.closed
  }

  private async dispatch(method: keyof Commands, params: unknown, sessionId?: string): Promise<unknown> {
    if (method === "Target.setDiscoverTargets") return {}
    if (method === "Target.getTargets") {
      const page = this.current
      return { targetInfos: page ? [await this.info(page)] : [] }
    }
    if (method === "Target.attachToTarget") {
      const targetId = (params as Commands["Target.attachToTarget"]["params"]).targetId
      const page = [...this.targets].find(([, id]) => id === targetId)?.[0]
      if (!page || page !== this.current) throw new CDPError("Esta aba não é a do agente.")
      const cdp = await page.context().newCDPSession(page)
      const id = `relay-${this.next++}`
      this.sessions.set(id, { page, cdp, targetId })
      for (const name of forwarded) cdp.on(name, (event) => this.emit(name, event, id))
      return { sessionId: id }
    }
    if (method === "Target.detachFromTarget") {
      const id = (params as Commands["Target.detachFromTarget"]["params"]).sessionId
      await this.sessions
        .get(id)
        ?.cdp.detach()
        .catch(() => undefined)
      this.sessions.delete(id)
      return {}
    }
    if (method === "Target.getTargetInfo") {
      const page = [...this.targets].find(
        ([, id]) => id === (params as Commands["Target.getTargetInfo"]["params"]).targetId,
      )?.[0]
      if (!page) throw new CDPError("Aba desconhecida.")
      return { targetInfo: await this.info(page) }
    }
    // Activating a target brings it to front and window bounds resize his window: never in Alexandre's browser.
    if (method.startsWith("Target.") || method.startsWith("Browser."))
      throw new CDPError(`${method} não é usado no Chrome pessoal.`)
    const session = sessionId ? this.sessions.get(sessionId) : undefined
    if (!session) throw new CDPError(`${method} precisa de uma aba.`)
    return session.cdp.send(method, params)
  }

  /** Re-reads the agent's current tab; a different one reports the old tab gone, so the viewer follows. */
  private async follow() {
    const tab = await currentTab(this.endpoint.socket)
    const pages = this.browser.contexts()[0]?.pages() ?? []
    const page =
      tab && (pages[tab.index]?.url() === tab.url ? pages[tab.index] : pages.find((item) => item.url() === tab.url))
    if (!page || page === this.current) return
    const previous = this.current
    this.current = page
    page.once("close", () => {
      const targetId = this.targets.get(page)
      if (targetId) this.emit("Target.targetDestroyed", { targetId })
    })
    if (!previous) return
    const targetId = this.targets.get(previous)
    if (targetId) this.emit("Target.targetDestroyed", { targetId })
  }

  private async info(page: Page): Promise<TargetInfo> {
    const known = this.targets.get(page)
    const targetId =
      known ??
      (await (async () => {
        const cdp = await page.context().newCDPSession(page)
        const own = (await cdp.send("Target.getTargetInfo", {})) as { targetInfo: TargetInfo }
        await cdp.detach().catch(() => undefined)
        return own.targetInfo.targetId
      })())
    this.targets.set(page, targetId)
    return { targetId, type: "page", title: await page.title().catch(() => ""), url: page.url() }
  }

  private emit(event: string, params: unknown, sessionId?: string) {
    for (const listener of this.listeners.get(event) ?? []) listener(params, sessionId)
  }
}

/** Page events the adapter listens to on its tab sessions. */
const forwarded = ["Page.screencastFrame", "Page.frameNavigated", "Page.navigatedWithinDocument", "Page.loadEventFired"]

/** The structural slice of Playwright's client API that the relay uses (loaded from the daemon's own library). */
interface Browser {
  contexts(): BrowserContext[]
  on(event: "disconnected", listener: () => void): void
  close(): Promise<void>
}
interface BrowserContext {
  pages(): Page[]
  newCDPSession(page: Page): Promise<CDPSession>
}
interface Page {
  url(): string
  title(): Promise<string>
  context(): BrowserContext
  once(event: "close", listener: () => void): void
}
interface CDPSession {
  send(method: string, params?: unknown): Promise<unknown>
  on(event: string, listener: (params: unknown) => void): void
  detach(): Promise<void>
}

interface ServerDescriptor {
  readonly title?: string
  readonly endpoint?: string
  readonly workspaceDir?: string
  readonly playwrightLib?: string
}

interface SessionFile {
  readonly socketPath?: string
  readonly workspaceDir?: string
}

/** JSON files of a directory (or, with `name`, the files called `name` one level below it). */
async function readJSON<T>(directory: string, name?: string): Promise<T[]> {
  const entries = await fs.readdir(directory).catch(() => [])
  const files = name
    ? entries.map((entry) => path.join(directory, entry, name))
    : entries.map((entry) => path.join(directory, entry))
  const parsed = await Promise.all(
    files.map((file) =>
      Bun.file(file)
        .json()
        .catch(() => undefined),
    ),
  )
  // Playwright writes these descriptors; unreadable ones are skipped.
  return parsed.filter((item): item is T => typeof item === "object" && item !== null)
}

function reachable(socket: string) {
  return new Promise<boolean>((resolve) => {
    const connection = net.createConnection(socket, () => {
      connection.destroy()
      resolve(true)
    })
    connection.on("error", () => resolve(false))
    connection.setTimeout(1_000, () => {
      connection.destroy()
      resolve(false)
    })
  })
}

/** One read-only command through the daemon's own client protocol (newline-delimited JSON). */
function daemonCommand(socket: string, args: readonly string[]) {
  return new Promise<string>((resolve, reject) => {
    const connection = net.createConnection(socket, () =>
      connection.write(
        JSON.stringify({ id: 1, method: "run", params: { args: { _: args }, cwd: os.tmpdir(), json: true } }) + "\n",
      ),
    )
    let buffer = ""
    // `tab-list` waits for the tab's pending requests (up to about 5.5 s on a busy page).
    connection.setTimeout(8_000, () => {
      connection.destroy()
      reject(new CDPError("playwright-cli não respondeu."))
    })
    connection.on("error", reject)
    connection.on("data", (chunk) => {
      buffer += chunk
      if (!buffer.includes("\n")) return
      connection.destroy()
      const reply: { result?: { text?: string }; error?: string } = JSON.parse(buffer.slice(0, buffer.indexOf("\n")))
      if (reply.error || !reply.result?.text) return reject(new CDPError(reply.error ?? "Resposta vazia."))
      const body: { result?: string } = JSON.parse(reply.result.text)
      resolve(body.result ?? "")
    })
  })
}
