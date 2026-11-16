import { Schema } from "effect"
import type { Input } from "../protocol.js"
import type { Resources } from "../rpc.js"
import { callTool, extensionConnected, imageOf, jsonOf, relayEndpoint, RelayError } from "./browse-relay.js"
import { decodeFocus, focusScript, normalizeURL, type ChromeState, type Focus } from "./chrome-page.js"
import type { Entry, Image, Probe, StreamSink } from "./types.js"

/**
 * The Chrome adapter's browse mode (`docs/browse-handoff-remoto.md`, rev. 2026-11-16): an OpenCode session's tabs in
 * Alexandre's own Chrome, reached through browse 0.1.0's relay as that session's owner (`meta.browse`). browse gives
 * clients no CDP, so everything goes through its tools, the same the agent calls: `tabs` for liveness and the tab
 * list, `screenshot` for frames (polled: there is no screencast), `click`, `drag`, `scroll`, `press`, `type` and
 * `navigate` for input, and `eval` in browse's isolated world for the address, the history and the focused field.
 */

export const browseSettings = {
  /** Between the starts of two captures: while Alexandre controls the tab, while he only watches, on economy. */
  controlledMs: 250,
  watchingMs: 1_000,
  economyMs: 2_000,
  quality: 70,
  economyQuality: 50,
  /** The address, history, focus and tab list are read again at most this often while streaming (and after input). */
  stateMs: 2_000,
  /** CSS pixels a finger may move before a touch scrolls (or drags) instead of clicking. */
  dragSlop: 8,
  /** A finger held this long before it moves drags (a slider, a map pin) instead of scrolling the page. */
  holdMs: 500,
  /** The longest a viewer's call may take (an input waits for what it changed). */
  callMs: 15_000,
  /** A capture that fails while its tab stays open is retried after this long, with a notice at most this often. */
  retryMs: 1_000,
  noticeMs: 10_000,
}

const ListedTab = Schema.Struct({
  tab: Schema.Int,
  url: Schema.String,
  title: Schema.String,
  lent: Schema.optional(Schema.Boolean),
})
type ListedTab = typeof ListedTab.Type
const TabList = Schema.Struct({ tabs: Schema.Array(ListedTab) })
const Shot = Schema.Struct({ width: Schema.Number, height: Schema.Number, scale: Schema.optional(Schema.Number) })
const PageState = Schema.Struct({
  url: Schema.String,
  title: Schema.String,
  canGoBack: Schema.Boolean,
  canGoForward: Schema.Boolean,
  focus: Schema.Unknown,
})
const Size = Schema.Tuple([Schema.Number, Schema.Number])

/** Runs in browse's isolated world: what the viewer shows besides the frame. `navigation` knows both directions. */
const stateScript = `(() => {
  const history = globalThis.navigation
  return {
    url: location.href,
    title: document.title,
    canGoBack: history ? history.canGoBack : window.history.length > 1,
    canGoForward: history ? history.canGoForward : false,
    focus: ${focusScript},
  }
})()`

type Point = { readonly x: number; readonly y: number }

/** What the adapter keeps for one browse resource between its stream, its inputs and its snapshots. */
interface View {
  entry: Entry
  /** The followed tab: the resource's (`meta.targetID`), or the one Alexandre picked in the viewer. */
  tab?: number
  controlled: boolean
  focus: Focus
  editTaps: number
  tabs: readonly ListedTab[]
  page?: Pick<ChromeState, "url" | "title" | "canGoBack" | "canGoForward">
  /** CSS pixels of the newest frame, which normalized input maps to. */
  viewport?: { width: number; height: number }
  sink?: StreamSink
  /** The state is read again with the next capture. */
  stale: boolean
  /** The next capture follows at once (after an input). */
  hurry: boolean
  wake?: () => void
  gesture?: { readonly start: Point; last: Point; readonly at: number; mode?: "scroll" | "drag" }
  /** Inputs run one after another, in order. */
  queue: Promise<unknown>
  /** A wheel scroll waiting its turn: more wheel input adds to it, so a trackpad's flood becomes a few calls. */
  wheel?: { dx: number; dy: number }
}

/** A browse resource's tab is locked in place while a handoff waits on it (`Resources.handoffCapabilities`). */
export function handoffLocked(entry: Pick<Entry, "handoff" | "capabilities">) {
  return entry.handoff !== undefined || entry.capabilities?.tabs === false
}

/**
 * The tab a browse resource shows among its owner's: the followed one while it is open, else (not while a handoff
 * waits: only its tab counts then) the newest the owner opened. Tabs Alexandre lent are followed but never picked.
 */
export function pick(tabs: readonly ListedTab[], followed: string | undefined, locked: boolean) {
  const found = tabs.find((tab) => String(tab.tab) === followed)
  if (found || locked) return found
  return tabs.filter((tab) => !tab.lent).at(-1)
}

export function makeBrowseView() {
  const views = new Map<string, View>()

  const viewOf = (entry: Entry) => {
    const existing = views.get(entry.id)
    if (existing) {
      existing.entry = entry
      return existing
    }
    const view: View = {
      entry,
      controlled: false,
      focus: { editable: false },
      editTaps: 0,
      tabs: [],
      stale: true,
      hurry: false,
      queue: Promise.resolve(),
    }
    views.set(entry.id, view)
    return view
  }

  const owner = (entry: Entry) => (entry.meta.kind === "chrome" ? (entry.meta.browse ?? "") : "")

  const list = async (browse: string, signal?: AbortSignal) => {
    const listed = jsonOf(await callTool(browse, "tabs", { action: "list" }, { signal, timeoutMs: 5_000 }), TabList)
    if (!listed) throw new RelayError("refused", "browse tabs: resposta inesperada do relay.")
    return listed.tabs
  }

  /** The tab to act on: the handoff's while one waits, else the followed one, else the owner's newest. */
  const tabOf = async (view: View, signal?: AbortSignal) => {
    const meta = view.entry.meta.kind === "chrome" ? view.entry.meta : undefined
    const assigned = Number(meta?.targetID)
    if (handoffLocked(view.entry)) {
      if (!Number.isInteger(assigned)) throw new Error("A aba do handoff não está aberta.")
      return assigned
    }
    if (view.tab !== undefined) return view.tab
    if (Number.isInteger(assigned)) return (view.tab = assigned)
    const found = pick(await list(owner(view.entry), signal), undefined, false)
    if (!found) throw new Error("O agente não tem nenhuma aba aberta no navegador.")
    return (view.tab = found.tab)
  }

  const capture = async (view: View, tab: number, quality: number, signal?: AbortSignal) => {
    const output = await callTool(
      owner(view.entry),
      "screenshot",
      { tab, format: "jpeg", quality, scale: "css" },
      { signal, timeoutMs: browseSettings.callMs },
    )
    const data = imageOf(output)
    const shot = jsonOf(output, Shot)
    if (!data || !shot) throw new RelayError("refused", "browse screenshot: resposta sem imagem.")
    return { data, width: shot.width, height: shot.height, scale: shot.scale ?? 1 }
  }

  const evaluate = <A>(view: View, tab: number, expression: string, schema: Schema.Codec<A, unknown>) =>
    callTool(
      owner(view.entry),
      "eval",
      { tab, expression, world: "isolated", timeout: 3_000 },
      { timeoutMs: 5_000 },
    ).then((output) => jsonOf(output, schema))

  const state = (view: View): ChromeState => {
    const listed = view.tabs.find((tab) => tab.tab === view.tab)
    const shown = handoffLocked(view.entry)
      ? view.tabs.filter((tab) => tab.tab === view.tab)
      : view.tabs.filter((tab) => !tab.lent || tab.tab === view.tab)
    return {
      url: view.page?.url ?? listed?.url ?? "",
      title: view.page?.title ?? listed?.title ?? "",
      canGoBack: view.page?.canGoBack ?? false,
      canGoForward: view.page?.canGoForward ?? false,
      targetID: view.tab === undefined ? "" : String(view.tab),
      tabs: shown.map((tab) => ({ id: String(tab.tab), title: tab.title, url: tab.url })),
      focus: view.focus,
      editTaps: view.editTaps,
      ...(view.viewport
        ? { viewport: { width: Math.round(view.viewport.width), height: Math.round(view.viewport.height) } }
        : {}),
    }
  }

  const publish = (view: View) => view.sink?.meta({ ...state(view) })

  const hurry = (view: View) => {
    view.hurry = true
    view.wake?.()
  }

  /** Reads the tab list and the page's state; a failure leaves the previous ones. */
  const refresh = async (view: View, tab: number, signal: AbortSignal) => {
    const [tabs, page] = await Promise.all([
      list(owner(view.entry), signal).catch(() => undefined),
      evaluate(view, tab, stateScript, PageState).catch(() => undefined),
    ])
    if (tabs) view.tabs = tabs
    if (!page || view.tab !== tab) return
    view.page = { url: page.url, title: page.title, canGoBack: page.canGoBack, canGoForward: page.canGoForward }
    view.focus = decodeFocus(page.focus)
  }

  const probeFocus = async (view: View, tapped: boolean) => {
    const tab = view.tab
    if (tab === undefined) return
    const value = await evaluate(view, tab, focusScript, Schema.Unknown).catch(() => undefined)
    const focus = decodeFocus(value)
    const edited = tapped && focus.editable
    if (!edited && focus.editable === view.focus.editable && focus.field === view.focus.field) return
    view.focus = focus
    if (edited) view.editTaps++
    publish(view)
  }

  /** Queues work on the followed tab after the inputs before it; the stream captures again once it is done. */
  const enqueue = (view: View, work: (tab: number) => Promise<unknown>) => {
    const run = view.queue.then(async () => work(await tabOf(view)))
    view.queue = run.catch(() => undefined)
    return run.finally(() => hurry(view))
  }

  const act = (view: View, name: string, args: Record<string, unknown>) =>
    enqueue(view, (tab) => callTool(owner(view.entry), name, { tab, ...args }, { timeoutMs: browseSettings.callMs }))

  const wheel = (view: View, dx: number, dy: number) => {
    if (view.wheel) {
      view.wheel.dx += dx
      view.wheel.dy += dy
      return
    }
    const pending = { dx, dy }
    view.wheel = pending
    void enqueue(view, (tab) => {
      if (view.wheel === pending) view.wheel = undefined
      return callTool(
        owner(view.entry),
        "scroll",
        { tab, deltaX: round(pending.dx), deltaY: round(pending.dy) },
        { timeoutMs: browseSettings.callMs },
      )
    }).catch(() => undefined)
  }

  /** CSS pixels of the newest frame, which normalized input maps to (read from the page before the first frame). */
  const viewport = async (view: View) => {
    if (view.viewport) return view.viewport
    const size = await evaluate(view, await tabOf(view), "[innerWidth, innerHeight]", Size)
    if (!size) throw new Error("O tamanho da aba não pôde ser lido.")
    return (view.viewport = { width: size[0], height: size[1] })
  }

  const point = async (view: View, x: number, y: number): Promise<Point> => {
    const size = await viewport(view)
    return { x: round(Math.min(x * size.width, size.width - 1)), y: round(Math.min(y * size.height, size.height - 1)) }
  }

  /**
   * A finger (or the Mac's mouse) that stays put clicks where it lifts; one that moves past `dragSlop` scrolls the
   * page like a phone browser, or drags when it was held `holdMs` first. Only the first finger counts.
   */
  const touch = async (view: View, event: Extract<Input, { type: "touch" }>) => {
    if ((event.pointer ?? 0) !== 0) return
    if (event.phase === "cancelled") return void (view.gesture = undefined)
    const at = await point(view, event.x, event.y)
    if (event.phase === "began") return void (view.gesture = { start: at, last: at, at: Date.now() })
    const gesture = view.gesture
    if (!gesture) return
    if (!gesture.mode && Math.hypot(at.x - gesture.start.x, at.y - gesture.start.y) < browseSettings.dragSlop) {
      if (event.phase === "moved") return
      view.gesture = undefined
      await act(view, "click", { x: at.x, y: at.y })
      return void probeFocus(view, true)
    }
    gesture.mode ??= Date.now() - gesture.at >= browseSettings.holdMs ? "drag" : "scroll"
    if (event.phase === "ended") view.gesture = undefined
    if (gesture.mode === "drag") {
      gesture.last = at
      if (event.phase === "ended") await act(view, "drag", { from: gesture.start, to: at })
      return
    }
    const delta = { x: gesture.last.x - at.x, y: gesture.last.y - at.y }
    gesture.last = at
    if (Math.abs(delta.x) + Math.abs(delta.y) >= 1) await act(view, "scroll", { deltaX: delta.x, deltaY: delta.y })
  }

  const navigate = async (view: View, event: Extract<Input, { type: "navigate" }>) => {
    // The hub refuses these first (`capabilities`); a handoff's tab never leaves its page from the viewer.
    if (handoffLocked(view.entry)) throw new Error("not_allowed")
    if (event.action === "tab") {
      const target = view.tabs.find((tab) => String(tab.tab) === event.target)
      if (!target || target.tab === view.tab || (target.lent && target.tab !== view.tab)) return
      view.tab = target.tab
      view.page = undefined
      view.focus = { editable: false }
      view.stale = true
      publish(view)
      return hurry(view)
    }
    if (event.action === "url" && !event.url?.trim()) return
    await act(
      view,
      "navigate",
      event.action === "url"
        ? { url: normalizeURL(event.url ?? ""), waitUntil: "commit" }
        : { action: event.action, waitUntil: "commit" },
    )
    view.stale = true
  }

  /** Waits `ms` before the next capture, or less when an input or the end of the stream comes first. */
  const pause = (view: View, ms: number, signal: AbortSignal) =>
    new Promise<void>((resolve) => {
      if (view.hurry || ms <= 0 || signal.aborted) return resolve()
      const done = () => {
        clearTimeout(timer)
        signal.removeEventListener("abort", done)
        view.wake = undefined
        resolve()
      }
      const timer = setTimeout(done, ms)
      view.wake = done
      signal.addEventListener("abort", done, { once: true })
    })

  return {
    async probe(entries: readonly Entry[]) {
      const lists = new Map<string, Promise<readonly ListedTab[] | undefined>>()
      const listed = (browse: string) => {
        const known = lists.get(browse)
        if (known) return known
        const reading = list(browse).catch(() => undefined)
        lists.set(browse, reading)
        return reading
      }
      const endpoint = relayEndpoint()
      let connected: Promise<boolean> | undefined
      const probes = await Promise.all(
        entries.map(async (entry): Promise<[string, Probe]> => {
          const meta = entry.meta.kind === "chrome" ? entry.meta : undefined
          const tabs = await listed(owner(entry))
          // No relay (or a refused token) says nothing about the agent's tabs.
          if (!tabs || !meta) return [entry.id, { status: "stopped" }]
          const target = pick(tabs, meta.targetID, handoffLocked(entry))
          if (target)
            return [
              entry.id,
              {
                status: "running",
                meta: {
                  kind: "chrome",
                  browse: owner(entry),
                  cdp: await endpoint,
                  targetID: String(target.tab),
                  url: target.url,
                  title: target.title,
                },
              },
            ]
          if (handoffLocked(entry)) return [entry.id, { status: "stopped" }]
          // A browser that is away (asleep, restarting) lists no tabs either: only a connected one says they are gone.
          connected ??= extensionConnected()
          return [entry.id, { status: (await connected) ? "gone" : "stopped" }]
        }),
      )
      return new Map(probes)
    },

    /** A handoff's tab, which its owner must see: browse refuses a handoff on another agent's tab. */
    async identify(meta: Resources.Meta): Promise<Resources.Meta> {
      if (meta.kind !== "chrome" || !meta.browse) return meta
      const tab = (await list(meta.browse)).find((item) => String(item.tab) === meta.targetID)
      if (!tab) throw new Error("A aba do handoff não está aberta.")
      return { ...meta, cdp: await relayEndpoint(), url: tab.url, title: tab.title }
    },

    async snapshot(entry: Entry): Promise<Image> {
      const view = viewOf(entry)
      const shot = await capture(view, await tabOf(view), 80)
      return { mime: "image/jpeg", data: shot.data, width: shot.width, height: shot.height }
    },

    async stream(entry: Entry, sink: StreamSink, signal: AbortSignal) {
      const view = viewOf(entry)
      view.sink = sink
      view.stale = true
      let size = { width: 0, height: 0 }
      let previous: Uint8Array | undefined
      let stateAt = 0
      let noticeAt = 0
      try {
        while (!signal.aborted) {
          const started = Date.now()
          await sink.whenReady?.(signal)
          if (signal.aborted) return
          view.hurry = false
          const economy = sink.profile?.() === "economy"
          const tab = await tabOf(view, signal)
          const at = Date.now()
          const shot = await capture(
            view,
            tab,
            economy ? browseSettings.economyQuality : browseSettings.quality,
            signal,
          ).then(
            (frame) => ({ frame }),
            (error: unknown) => ({ error }),
          )
          if (signal.aborted) return
          if ("error" in shot) {
            const error = shot.error
            if (!(error instanceof RelayError) || error.reason !== "tool") throw error
            const tabs = await list(owner(view.entry), signal)
            view.tabs = tabs
            // The tab closed: a handoff's has no replacement; otherwise the owner's newest tab takes over.
            if (!tabs.some((item) => item.tab === tab)) {
              if (handoffLocked(view.entry)) throw new Error("A aba do handoff foi fechada.")
              const next = pick(tabs, undefined, false)
              if (!next) throw new Error("O agente não tem mais abas abertas no navegador.")
              view.tab = next.tab
              view.page = undefined
              view.focus = { editable: false }
              view.stale = true
              continue
            }
            if (Date.now() - noticeAt >= browseSettings.noticeMs) {
              noticeAt = Date.now()
              sink.notice?.(`O navegador não deixou capturar a aba: ${error.message}`)
            }
            await pause(view, browseSettings.retryMs, signal)
            continue
          }
          const frame = shot.frame
          if (frame.width !== size.width || frame.height !== size.height) {
            size = { width: frame.width, height: frame.height }
            previous = undefined
            sink.hello({ format: "jpeg", width: frame.width, height: frame.height })
            view.stale = true
          }
          view.viewport = { width: frame.width / frame.scale, height: frame.height / frame.scale }
          // An unchanged page is not sent again: viewers keep the last frame, and a joining one gets it from the hub.
          if (!previous || !same(previous, frame.data)) {
            previous = frame.data
            sink.frame(frame.data, { keyframe: true, capturedAt: at })
          }
          if (view.stale || Date.now() - stateAt >= browseSettings.stateMs) {
            view.stale = false
            stateAt = Date.now()
            await refresh(view, tab, signal)
            publish(view)
          }
          const gap = view.controlled
            ? browseSettings.controlledMs
            : economy
              ? browseSettings.economyMs
              : browseSettings.watchingMs
          await pause(view, started + gap - Date.now(), signal)
        }
      } finally {
        if (view.sink === sink) view.sink = undefined
      }
    },

    async input(entry: Entry, event: Input) {
      const view = viewOf(entry)
      view.controlled = true
      switch (event.type) {
        case "touch":
          return touch(view, event)
        case "scroll": {
          // browse scrolls the page's own scroller: the wheel's point cannot be passed on.
          const size = await viewport(view)
          return wheel(view, event.dx * size.width, event.dy * size.height)
        }
        case "key": {
          await act(view, "press", { key: combo(event) })
          if (event.key === "Tab" || event.key === "Enter" || event.key === "Escape") void probeFocus(view, false)
          return
        }
        case "text":
          // Never log `event.text` (it may be a password), nor an error that could carry it.
          if (event.text.length === 0) return
          await act(view, "type", { text: event.text }).catch(() => {
            throw new Error("browse type failed")
          })
          return
        case "navigate":
          return navigate(view, event)
        case "button":
          if (event.button === "back") return navigate(view, { type: "navigate", action: "back" })
          return
      }
    },

    async released(entry: Entry) {
      const view = views.get(entry.id)
      if (view) view.controlled = false
    },

    /**
     * The resource moved to another tab (the agent's call, a handoff that starts on its tab) or its locks changed: the
     * stream follows without ending.
     */
    async update(entry: Entry) {
      const view = views.get(entry.id)
      if (!view) return
      view.entry = entry
      const assigned = Number(entry.meta.kind === "chrome" ? entry.meta.targetID : undefined)
      if (Number.isInteger(assigned) && assigned !== view.tab) {
        view.tab = assigned
        view.page = undefined
        view.focus = { editable: false }
      }
      view.stale = true
      publish(view)
      hurry(view)
    },

    async forget(entry: Entry) {
      views.delete(entry.id)
    },

    /**
     * browse 0.1.0 brings no tab to the front (its `bringToFront` does nothing): `failed`, so the Mac app selects the
     * tab itself through Chrome's AppleScript, as it does for any failure but `not_found`, `unsupported` and `gone`.
     */
    async focus() {
      throw new Error("O browse não traz abas para a frente; o app seleciona a aba no Chrome.")
    },
  }
}

/** `press` takes "Control+Shift+K"-style combos with DOM key names. */
function combo(event: Extract<Input, { type: "key" }>) {
  const names = { shift: "Shift", control: "Control", alt: "Alt", meta: "Meta" } as const
  return [...(event.modifiers ?? []).map((modifier) => names[modifier]), event.key].join("+")
}

const round = (value: number) => Math.round(value * 10) / 10

const same = (a: Uint8Array, b: Uint8Array) =>
  a.byteLength === b.byteLength &&
  Buffer.from(a.buffer, a.byteOffset, a.byteLength).equals(Buffer.from(b.buffer, b.byteOffset, b.byteLength))
