import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import type { Entry } from "../../src/resources/adapters/types"
import type { Resources } from "../../src/resources/rpc"

/**
 * browse 0.1.5's relay as its HTTP API answers (`POST /tools/call`, `POST /tools/cancel`, `GET /extension/status`),
 * without a browser: every tab listed to every caller (chosen `id`, `opener`, `lastUsed` as given), a screenshot of
 * `view` CSS pixels, an `eval` that answers `page`, and every other tool answering `{}`. Every call is kept in
 * `calls`, as sent, with its key. `env` points the relay client at it (port and token file).
 */

export const token = "relay-token-0123456789abcdefghijklmnopqrstuvwxyzAB"

export type FakeTab = {
  tab: number
  url: string
  title: string
  lent?: boolean
  id?: string
  group?: string
  opener?: number
  lastUsed?: string
}
export type Call = { readonly name: string; readonly arguments: Record<string, unknown> }

export async function fakeRelay() {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "fake-browse-"))
  const tokenFile = path.join(directory, "relay-token")
  await Bun.write(tokenFile, `${token}\n`)
  const calls: Call[] = []
  const cancelled: string[] = []
  const keys: string[] = []
  const refused: string[] = []
  const state = {
    tabs: [] as FakeTab[],
    connected: true,
    /** CSS size of the screenshots and their image scale (browse scales an image down past 8000 px). */
    view: { width: 1280, height: 800, scale: 1 },
    /** The screenshot's bytes: change it to make the page change. */
    frame: "frame-1",
    page: { url: "", title: "", canGoBack: false, canGoForward: false, focus: { editable: false } } as Record<
      string,
      unknown
    >,
    /** Tools that wait until `release()` (or until their call is cancelled). */
    hold: new Set<string>(),
  }
  const waiters = new Set<() => void>()
  const text = (value: unknown) => ({ content: [{ type: "text", text: JSON.stringify(value) }] })
  const failure = (message: string) => ({ content: [{ type: "text", text: message }], isError: true })

  const answer = (name: string, args: Record<string, unknown>) => {
    if (name === "tabs" && (args.action ?? "list") === "list")
      return text({ tabs: state.tabs.map((tab) => ({ lent: false, busy: false, ...tab })) })
    if (args.tab !== undefined && !state.tabs.some((item) => item.tab === args.tab))
      return failure(`Tab ${args.tab} is gone.`)
    if (name === "screenshot") {
      const width = Math.round(state.view.width * state.view.scale)
      const height = Math.round(state.view.height * state.view.scale)
      return {
        content: [
          { type: "image", data: Buffer.from(state.frame).toString("base64"), mimeType: "image/jpeg" },
          {
            type: "text",
            text: JSON.stringify({
              width,
              height,
              format: "jpeg",
              ...(state.view.scale === 1 ? {} : { scale: state.view.scale }),
            }),
          },
        ],
      }
    }
    if (name === "eval") {
      const expression = String(args.expression)
      if (expression === "[innerWidth, innerHeight]") return text([state.view.width, state.view.height])
      if (expression.includes("canGoBack")) return text(state.page)
      return text(state.page.focus)
    }
    return text({})
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.headers.get("authorization") !== `Bearer ${token}`) {
        refused.push(url.pathname)
        return Response.json({ error: "Missing or invalid browse relay token", code: "unauthorized" }, { status: 401 })
      }
      if (url.pathname === "/extension/status") return Response.json({ connected: state.connected, targets: [] })
      const body = (await request.json()) as { name?: string; arguments?: Record<string, unknown>; call?: string }
      if (url.pathname === "/tools/cancel") {
        cancelled.push(body.call ?? "")
        waiters.forEach((wake) => wake())
        return Response.json({ stopped: true })
      }
      if (url.pathname !== "/tools/call") return Response.json({ error: "Not found" }, { status: 404 })
      const key = request.headers.get("opencode-browser-call") ?? ""
      const name = body.name ?? ""
      const args = body.arguments ?? {}
      keys.push(key)
      calls.push({ name, arguments: args })
      if (state.hold.has(name))
        await new Promise<void>((resolve) => {
          const wake = () => {
            if (state.hold.has(name) && !cancelled.includes(key)) return
            waiters.delete(wake)
            resolve()
          }
          waiters.add(wake)
        })
      return Response.json(answer(name, args))
    },
  })
  return {
    server,
    state,
    calls,
    cancelled,
    keys,
    refused,
    tokenFile,
    endpoint: `http://127.0.0.1:${server.port}`,
    env: { OPENCODE_BROWSER_PORT: String(server.port), OPENCODE_BROWSE_RELAY_TOKEN_FILE: tokenFile },
    /** Lets every held call answer. */
    release: () => {
      state.hold.clear()
      waiters.forEach((wake) => wake())
    },
    /** The calls of `name` so far. */
    named: (name: string) => calls.filter((call) => call.name === name),
    stop: async () => {
      server.stop(true)
      await fs.rm(directory, { recursive: true, force: true })
    },
  }
}

/** Points the relay client at `relay` (it reads the environment per call) until the returned restore. */
export function useRelay(relay: { readonly env: Record<string, string> }) {
  const saved = Object.fromEntries(Object.keys(relay.env).map((key) => [key, process.env[key]]))
  Object.assign(process.env, relay.env)
  return () => {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
  }
}

/** A session's browse resource holding `tabs` (none: an entry from before rev. 2026-11-22, which holds its target). */
export function browseEntry(
  meta: Partial<Resources.ChromeMeta> & { readonly browse: string },
  tabs?: readonly number[],
): Entry {
  return {
    id: `chrome:browse:${meta.browse}`,
    kind: "chrome",
    meta: { kind: "chrome", ...meta },
    status: "running",
    discoveredAt: 1,
    lastUsedAt: 1,
    updatedAt: 1,
    ...(tabs ? { tabs: tabs.map((tab) => ({ tab })) } : {}),
  }
}

/** A browse resource while a handoff waits on its tab (`handoffCapabilities`). */
export function handoffEntry(
  meta: Partial<Resources.ChromeMeta> & { readonly browse: string },
  tabs?: readonly number[],
): Entry {
  return {
    ...browseEntry(meta, tabs),
    handoff: { id: "brw_1", sessionID: "ses_1", message: "Entre", since: 1 },
    capabilities: { navigation: false, tabs: false, focus: true },
  }
}
