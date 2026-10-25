import { size, text } from "./process.js"
import type { Adapter, Entry, Probe } from "./types.js"

/**
 * Chrome driven by `playwright-cli`. Foundation stub: liveness from the CDP endpoint when one is known, otherwise
 * from `playwright-cli list`, and snapshots through CDP `Page.captureScreenshot`. Attaching to the session's browser,
 * `Page.startScreencast` and `Input.dispatch*`/`insertText` belong to the `resources-chrome` work.
 */
export const adapter: Adapter = {
  kind: "chrome",
  async probe(entries) {
    const chrome = entries.filter((entry) => entry.meta.kind === "chrome")
    const sessions = chrome.some((entry) => entry.meta.kind === "chrome" && !entry.meta.cdp) ? await openSessions() : []
    return new Map(
      await Promise.all(
        chrome.map(async (entry): Promise<[string, Probe]> => {
          if (entry.meta.kind !== "chrome") return [entry.id, { status: "gone" }]
          if (entry.meta.cdp) {
            const page = await target(entry).catch(() => undefined)
            if (!page) return [entry.id, { status: "gone" }]
            return [
              entry.id,
              { status: "running", meta: { ...entry.meta, targetID: page.id, url: page.url, title: page.title } },
            ]
          }
          return [
            entry.id,
            { status: entry.meta.session && sessions.includes(entry.meta.session) ? "running" : "gone" },
          ]
        }),
      ),
    )
  },
  async snapshot(entry) {
    const page = await target(entry)
    const result = await cdp(page.webSocketDebuggerUrl, "Page.captureScreenshot", { format: "jpeg", quality: 70 })
    const data = typeof result.data === "string" ? Buffer.from(result.data, "base64") : undefined
    if (!data) throw new Error("CDP returned no screenshot")
    return { mime: "image/jpeg", data, ...size(data) }
  },
}

type Target = {
  readonly id: string
  readonly url: string
  readonly title: string
  readonly webSocketDebuggerUrl: string
}

/** The followed page, or the first page target, of the entry's CDP endpoint. */
export async function target(entry: Entry): Promise<Target> {
  if (entry.meta.kind !== "chrome" || !entry.meta.cdp) throw new Error("No CDP endpoint for this browser")
  const response = await fetch(new URL("/json/list", entry.meta.cdp), { signal: AbortSignal.timeout(3_000) })
  const targets: unknown = await response.json()
  const pages = (Array.isArray(targets) ? targets : []).filter(
    (item): item is Target & { type: string } =>
      typeof item === "object" &&
      item !== null &&
      item.type === "page" &&
      typeof item.id === "string" &&
      typeof item.webSocketDebuggerUrl === "string",
  )
  const meta = entry.meta
  const followed = meta.targetID ? pages.find((page) => page.id === meta.targetID) : undefined
  const page = followed ?? pages[0]
  if (!page) throw new Error("No page target")
  return page
}

/** One CDP call over a short-lived WebSocket. */
export function cdp(url: string, method: string, params: Record<string, unknown>) {
  return new Promise<Record<string, unknown>>((resolve, reject) => {
    const socket = new WebSocket(url)
    const timer = setTimeout(() => {
      socket.close()
      reject(new Error(`${method} timed out`))
    }, 10_000)
    socket.onopen = () => socket.send(JSON.stringify({ id: 1, method, params }))
    socket.onerror = () => {
      clearTimeout(timer)
      reject(new Error(`${method} failed`))
    }
    socket.onmessage = (event) => {
      const message: unknown = JSON.parse(String(event.data))
      if (typeof message !== "object" || message === null || !("id" in message) || message.id !== 1) return
      clearTimeout(timer)
      socket.close()
      if ("error" in message) return reject(new Error(`${method}: ${JSON.stringify(message.error)}`))
      resolve(
        "result" in message && typeof message.result === "object" && message.result !== null
          ? (message.result as Record<string, unknown>)
          : {},
      )
    }
  })
}

/** Open `playwright-cli` browser session names. */
export async function openSessions() {
  const output: unknown = JSON.parse(
    await text(["playwright-cli", "list", "--json"], { timeout: 20_000 }).catch(() => "{}"),
  )
  const browsers = typeof output === "object" && output !== null && "browsers" in output ? output.browsers : []
  return (Array.isArray(browsers) ? browsers : []).flatMap((browser: unknown) =>
    typeof browser === "object" &&
    browser !== null &&
    "name" in browser &&
    typeof browser.name === "string" &&
    "status" in browser &&
    browser.status === "open"
      ? [browser.name]
      : [],
  )
}
