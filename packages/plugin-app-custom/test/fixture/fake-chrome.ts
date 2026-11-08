import type { Entry, StreamSink } from "../../src/resources/adapters/types"
import type { ChromeState, makeChromeAdapter } from "../../src/resources/adapters/chrome"
import type { Resources } from "../../src/resources/rpc"

/**
 * A browser for the Chrome adapter's tests that needs no Chrome: a browse relay (with `token`: its HTTP token, session
 * header and `/json/list` of every session) or a plain Chrome (without), with enough CDP for one tab whose window
 * shows `view.device` DIP and `view.inner` CSS pixels (Alexandre's Chrome at 125 % by default). Every CDP command is
 * kept in `sent`.
 */

export const jpeg =
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAA//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AN//Z"
export const token = "relay-token-0123456789abcdefghijklmnopqrstuvwxyzAB"

export type Sent = { readonly method: string; readonly params: Record<string, unknown>; readonly sessionId?: string }

export const pages = [
  {
    id: "TAB1",
    type: "page",
    title: "Entrar · Abacato",
    url: "http://127.0.0.1:5191/",
    opencodeBrowserSessionId: "login",
  },
  { id: "TAB2", type: "page", title: "Ajuda", url: "http://127.0.0.1:5191/ajuda", opencodeBrowserSessionId: "login" },
  {
    id: "OTHER",
    type: "page",
    title: "Extrato · Banco do Alexandre",
    url: "https://banco.example/extrato",
    opencodeBrowserSessionId: "pessoal",
  },
]

/** A browse relay (with `token`) or a plain Chrome (without), whose one window shows `device` DIP and `inner` CSS px. */
export function fakeBrowser(options: { readonly token?: string }) {
  const sent: Sent[] = []
  const refused: string[] = []
  /**
   * `delivered` counts the trusted presses the page received (what the adapter reads from its isolated world);
   * `blocked` drops them, as Chrome does while a dialog of its own covers the tab.
   */
  const view = {
    device: [1400, 771] as [number, number],
    inner: [1120, 616.8] as [number, number],
    delivered: 0,
    blocked: false,
  }
  /**
   * What bringing a tab forward meets: Chrome refuses `Target.activateTarget` to the extension, and the relay blocks
   * `Page.bringToFront` unless its environment allows it (both as browse 0.0.14 behaves by default).
   */
  const refuse: Record<string, string> = {
    "Target.activateTarget": JSON.stringify({ code: -32000, message: "Not allowed" }),
    "Page.bringToFront": "browse blocked Page.bringToFront: it raises the user's browser window over their work",
  }
  const sockets = new Set<Bun.ServerWebSocket<{ session: string }>>()
  const info = (id: string) => {
    const page = pages.find((item) => item.id === id)!
    return { targetId: page.id, type: page.type, title: page.title, url: page.url }
  }
  const results: Record<
    string,
    (params: Record<string, unknown>, socket: Bun.ServerWebSocket<{ session: string }>) => unknown
  > = {
    "Target.setDiscoverTargets": () => ({}),
    "Target.getTargets": (_params, socket) => ({
      targetInfos: pages
        .filter((page) => page.opencodeBrowserSessionId === socket.data.session)
        .map((page) => info(page.id)),
    }),
    "Target.attachToTarget": (params) => ({ sessionId: `S-${params.targetId}` }),
    "Target.detachFromTarget": () => ({}),
    "Target.getTargetInfo": (params) => ({ targetInfo: info(String(params.targetId)) }),
    "Target.activateTarget": () => ({}),
    "Page.bringToFront": () => ({}),
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
      if (params.contextId === 7 && expression.includes("__opencodeDelivered"))
        return { result: { value: view.delivered } }
      if (expression.includes("maxTouchPoints")) return { result: { value: [false, 2] } }
      if (expression === "[innerWidth, innerHeight]") return { result: { value: view.inner } }
      if (expression === "document.visibilityState") return { result: { value: "visible" } }
      return { result: { value: { editable: false } } }
    },
    "Input.dispatchMouseEvent": (params) => {
      if (params.type === "mousePressed" && !view.blocked) view.delivered++
      return {}
    },
    "Input.dispatchKeyEvent": () => ({}),
    "Input.insertText": () => ({}),
  }
  const server = Bun.serve<{ session: string }>({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request, server) {
      const url = new URL(request.url)
      if (url.pathname.startsWith("/devtools/browser/")) {
        if (options.token && url.searchParams.get("opencodeBrowserToken") !== options.token) {
          refused.push(url.pathname)
          return new Response(null, { status: 401 })
        }
        const session = url.searchParams.get("opencodeBrowserSessionId") ?? "login"
        return server.upgrade(request, { data: { session } }) ? undefined : new Response(null, { status: 400 })
      }
      if (options.token && request.headers.get("authorization") !== `Bearer ${options.token}`) {
        refused.push(url.pathname)
        return new Response(null, { status: 401 })
      }
      const session = request.headers.get("opencode-browser-session-id")
      if (url.pathname === "/json/version") {
        const query = options.token ? `?opencodeBrowserSessionId=${session}&opencodeBrowserToken=${options.token}` : ""
        return Response.json({ webSocketDebuggerUrl: `ws://127.0.0.1:${server.port}/devtools/browser/fake${query}` })
      }
      if (url.pathname === "/json/list") return Response.json(options.token ? pages : pages.slice(0, 1))
      if (url.pathname === "/cli/sessions")
        return Response.json({
          sessions: [
            { id: "login", pageUrl: "http://127.0.0.1:5191/" },
            { id: "pessoal", pageUrl: "https://banco.example/extrato" },
          ],
        })
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
        if (refuse[message.method])
          return void socket.send(JSON.stringify({ id: message.id, error: { message: refuse[message.method] } }))
        if (!result)
          return void socket.send(
            JSON.stringify({ id: message.id, error: { message: `${message.method} is not faked` } }),
          )
        socket.send(JSON.stringify({ id: message.id, result: result(message.params ?? {}, socket) }))
        if (message.method === "Page.startScreencast") frame(socket, message.sessionId)
      },
    },
  })
  results["Page.startScreencast"] = () => ({})
  const frame = (socket: Bun.ServerWebSocket<{ session: string }>, sessionId?: string) =>
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
  return { server, sent, refused, refuse, view, event, cdp: `http://127.0.0.1:${server.port}` }
}

export function entryOf(meta: Resources.Meta, id = "chrome:browse:login"): Entry {
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
