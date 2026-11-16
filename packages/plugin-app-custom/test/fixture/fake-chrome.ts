import type { Entry, StreamSink } from "../../src/resources/adapters/types"
import type { makeChromeAdapter } from "../../src/resources/adapters/chrome"
import type { ChromeState } from "../../src/resources/adapters/chrome-page"
import type { Resources } from "../../src/resources/rpc"

/**
 * A Chrome for the Chrome adapter's tests that needs no Chrome, with enough CDP for one tab whose window shows
 * `view.device` DIP and `view.inner` CSS pixels (Alexandre's Chrome at 125 % by default). Every CDP command is kept in
 * `sent`.
 */

export const jpeg =
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAA//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AN//Z"
export type Sent = { readonly method: string; readonly params: Record<string, unknown>; readonly sessionId?: string }

export const pages = [{ id: "TAB1", type: "page", title: "Entrar · Abacato", url: "http://127.0.0.1:5191/" }]

/** A Chrome whose one window shows `device` DIP and `inner` CSS px. */
export function fakeBrowser() {
  const sent: Sent[] = []
  /**
   * `delivered` counts the trusted presses the page received (what the adapter reads from its isolated world);
   * `blocked` drops them, as Chrome does while a dialog of its own covers the tab.
   */
  const view = {
    device: [1400, 771] as [number, number],
    inner: [1120, 616.8] as [number, number],
    delivered: 0,
    blocked: false,
    /** Embedded documents (CSS px): presses there reach them, never the main frame's count. */
    iframes: [] as { x: number; y: number; width: number; height: number }[],
  }
  const inIframe = (x: number, y: number) =>
    view.iframes.some((box) => x >= box.x && x < box.x + box.width && y >= box.y && y < box.y + box.height)
  const sockets = new Set<Bun.ServerWebSocket<undefined>>()
  const info = (id: string) => {
    const page = pages.find((item) => item.id === id)!
    return { targetId: page.id, type: page.type, title: page.title, url: page.url }
  }
  const results: Record<string, (params: Record<string, unknown>) => unknown> = {
    "Target.setDiscoverTargets": () => ({}),
    "Target.getTargets": () => ({ targetInfos: pages.map((page) => info(page.id)) }),
    "Target.attachToTarget": (params) => ({ sessionId: `S-${params.targetId}` }),
    "Target.detachFromTarget": () => ({}),
    "Target.getTargetInfo": (params) => ({ targetInfo: info(String(params.targetId)) }),
    "Target.activateTarget": () => ({}),
    "Page.navigate": () => ({ frameId: "F" }),
    "Page.reload": () => ({}),
    "Page.enable": () => ({}),
    "Page.stopScreencast": () => ({}),
    "Page.screencastFrameAck": () => ({}),
    "Page.captureScreenshot": () => ({ data: jpeg }),
    "Page.getNavigationHistory": () => ({
      currentIndex: 0,
      entries: [{ id: 1, url: pages[0]!.url, title: pages[0]!.title }],
    }),
    "Page.getLayoutMetrics": () => ({
      cssVisualViewport: { clientWidth: view.inner[0], clientHeight: view.inner[1], pageX: 0, pageY: 0 },
    }),
    "Page.createIsolatedWorld": () => ({ executionContextId: 7 }),
    "Runtime.evaluate": (params) => {
      const expression = String(params.expression)
      if (params.contextId === 7 && expression.includes("__opencodeDelivered")) {
        const point = /elementFromPoint\(([\d.]+), ([\d.]+)\)/.exec(expression)
        if (point && inIframe(Number(point[1]), Number(point[2]))) return { result: { value: null } }
        return { result: { value: view.delivered } }
      }
      if (expression.includes("maxTouchPoints")) return { result: { value: [false, 2] } }
      if (expression === "[innerWidth, innerHeight]") return { result: { value: view.inner } }
      if (expression === "document.visibilityState") return { result: { value: "visible" } }
      return { result: { value: { editable: false } } }
    },
    "Input.dispatchMouseEvent": (params) => {
      if (params.type === "mousePressed" && !view.blocked && !inIframe(Number(params.x), Number(params.y)))
        view.delivered++
      return {}
    },
    "Input.dispatchKeyEvent": () => ({}),
    "Input.insertText": () => ({}),
  }
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request, server) {
      const url = new URL(request.url)
      if (url.pathname.startsWith("/devtools/browser/"))
        return server.upgrade(request, { data: undefined }) ? undefined : new Response(null, { status: 400 })
      if (url.pathname === "/json/version")
        return Response.json({ webSocketDebuggerUrl: `ws://127.0.0.1:${server.port}/devtools/browser/fake` })
      if (url.pathname === "/json/list") return Response.json(pages)
      return new Response(null, { status: 404 })
    },
    websocket: {
      open: (socket) => void sockets.add(socket),
      close: (socket) => void sockets.delete(socket),
      message(socket, raw) {
        const message = JSON.parse(String(raw)) as {
          id: number
          method: string
          params?: Record<string, unknown>
          sessionId?: string
        }
        sent.push({
          method: message.method,
          params: message.params ?? {},
          ...(message.sessionId ? { sessionId: message.sessionId } : {}),
        })
        const result = results[message.method]
        if (!result)
          return void socket.send(
            JSON.stringify({ id: message.id, error: { message: `${message.method} is not faked` } }),
          )
        socket.send(JSON.stringify({ id: message.id, result: result(message.params ?? {}) }))
        if (message.method === "Page.startScreencast") frame(socket, message.sessionId)
      },
    },
  })
  results["Page.startScreencast"] = () => ({})
  const frame = (socket: Bun.ServerWebSocket<undefined>, sessionId?: string) =>
    socket.send(
      JSON.stringify({
        method: "Page.screencastFrame",
        sessionId,
        params: {
          data: jpeg,
          sessionId: 1,
          metadata: {
            offsetTop: 0,
            pageScaleFactor: 1,
            deviceWidth: view.device[0],
            deviceHeight: view.device[1],
            scrollOffsetX: 0,
            scrollOffsetY: 0,
            timestamp: Date.now() / 1000,
          },
        },
      }),
    )
  const event = (method: string, params: unknown) =>
    sockets.forEach((socket) => socket.send(JSON.stringify({ method, params })))
  return { server, sent, view, event, cdp: `http://127.0.0.1:${server.port}` }
}

export function entryOf(meta: Resources.Meta, id: string): Entry {
  return { id, kind: "chrome", meta, status: "running", discoveredAt: 1, lastUsedAt: 1, updatedAt: 1 }
}

/** Streams `entry` into `states` until the returned `stop`. */
export function watch(adapter: ReturnType<typeof makeChromeAdapter>, entry: Entry) {
  const states: ChromeState[] = []
  const frames: Uint8Array[] = []
  const notices: string[] = []
  const controller = new AbortController()
  const sink: StreamSink = {
    hello: () => undefined,
    frame: (payload) => void frames.push(payload),
    // The Chrome adapter publishes exactly `ChromeState`.
    meta: (value) => void states.push(value as unknown as ChromeState),
    notice: (message) => void notices.push(message),
  }
  const streaming = adapter.stream!(entry, sink, controller.signal).catch((error: unknown) => error)
  const until = async (condition: () => boolean) => {
    const deadline = Date.now() + 5_000
    while (!condition()) {
      if (Date.now() > deadline) throw new Error(`timed out; last state ${JSON.stringify(states.at(-1))}`)
      await Bun.sleep(10)
    }
  }
  return { states, frames, notices, until, streaming, stop: () => controller.abort() }
}
