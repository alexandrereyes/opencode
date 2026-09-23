import { TimelineRow } from "@opencode/session-ui-custom/timeline/projection"
import { createMemo, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import { render } from "solid-js/web"
import { LanguageProvider } from "../src/runtime/i18n/language"
import { createTimelineVirtualizer } from "../src/session/timeline/virtualizer"
import type { ReadingAnchor } from "../src/session/timeline/reading-position"

export function mountTimelineVirtualizer(input: { count: number; rowHeight: number; immediate?: boolean }) {
  const host = document.createElement("main")
  host.dataset.testid = "timeline-virtualizer-fixture"
  host.dataset.scrolls = "0"
  host.dataset.viewportResizes = "0"
  host.style.cssText = "position:fixed;top:24px;right:24px;width:400px;z-index:1000"
  document.body.appendChild(host)

  function Fixture() {
    const [state, setState] = createStore({ pinned: true, ready: false })
    const rows = Array.from(
      { length: input.count },
      (_, index) => new TimelineRow.UserMessage({ userMessageID: `message-${index}` }),
    )
    const rowByKey = new Map(rows.map((row) => [TimelineRow.key(row), row]))
    const indexes = new Map(rows.map((row, index) => [row.userMessageID, index]))
    let viewport!: HTMLDivElement
    let content!: HTMLDivElement
    let container!: HTMLDivElement
    const timeline = createTimelineVirtualizer({
      sessionKey: () => "cold-reveal-fixture",
      projection: {
        rows: () => rows,
        rowByKey: () => rowByKey,
        activeMessageID: () => undefined,
        messageRowIndex: () => indexes,
        messageLastRowIndex: () => indexes,
      },
      showHeader: () => false,
      pinned: () => state.pinned,
      scroll: () => ({ overflow: false, jump: false }),
      setScrollRef: (element) => {
        if (!element) return
        viewport = element
        resize.observe(element, { box: "border-box" })
      },
      setContentRef: (element) => {
        content = element
        reveal.observe(element, { attributes: true, attributeFilter: ["style"] })
      },
      onPin: () => setState("pinned", true),
      onUnpin: () => setState("pinned", false),
      onScheduleScrollState: (element) => {
        host.dataset.scrolls = String(Number(host.dataset.scrolls) + 1)
        host.dataset.lastScrollTop = String(element.scrollTop)
      },
      onResumeScroll: () => {},
      onSelectionInteraction: () => {},
      onUserScroll: () => {},
      onHistoryScroll: () => {},
      canRenderImmediately: () => input.immediate ?? false,
    })

    const resize = new ResizeObserver((entries) => {
      host.dataset.observedHeight = String(entries[0].borderBoxSize[0].blockSize)
      host.dataset.viewportResizes = String(Number(host.dataset.viewportResizes) + 1)
    })
    const reveal = new MutationObserver(() => {
      if (content.style.visibility === "hidden" || host.dataset.firstReveal) return
      // Capture the first reveal, not a later frame after geometry has recovered.
      const mounted = [...content.querySelectorAll<HTMLElement>("[data-timeline-key]")]
      host.dataset.firstReveal = JSON.stringify({
        rows: mounted.map((element) => Number(element.firstElementChild!.getAttribute("data-index"))),
        pendingMarkdown: content.querySelectorAll('[data-component="markdown"]:not([data-markdown-ready])').length,
        viewportHeight: viewport.clientHeight,
        scrollTop: viewport.scrollTop,
        clipped: mounted
          .filter((element) => element.firstElementChild!.getBoundingClientRect().height > element.offsetHeight + 1)
          .map((element) => element.dataset.timelineKey),
      })
    })
    onCleanup(() => {
      resize.disconnect()
      reveal.disconnect()
    })

    return (
      <div data-testid="timeline-controls" data-pinned={state.pinned}>
        <button type="button" onClick={() => setState("ready", true)}>
          Complete Markdown
        </button>
        <button type="button" onClick={() => (container.style.display = "none")}>
          Hide viewport
        </button>
        <button
          type="button"
          onClick={() => {
            const parent = viewport.parentElement!
            host.dataset.scrolls = "0"
            // Keep the same scroller and complete Markdown while it has no layout box.
            viewport.remove()
            viewport.scrollTop = 0
            setState("ready", true)
            parent.prepend(viewport)
            container.style.removeProperty("display")
          }}
        >
          Reconnect ready rows
        </button>
        <div ref={container} style={{ height: "180px", width: "400px" }}>
          <timeline.View
            header={null}
            workspaceSession={() => false}
            deferred={() => false}
            renderRow={(row) => (
              <div
                data-component="markdown"
                data-markdown-ready={state.ready ? "" : undefined}
                style={{ height: `${input.rowHeight}px` }}
              >
                {row().userMessageID}
              </div>
            )}
          />
        </div>
      </div>
    )
  }

  render(
    () => (
      <LanguageProvider locale="en">
        <Fixture />
      </LanguageProvider>
    ),
    host,
  )
}

export function mountReadingVirtualizer(input: {
  index: number
  offset: number
  missing?: boolean
  streaming?: boolean
  request?: "wait" | "error"
  count?: number
  pendingAnchor?: boolean
  slowSync?: "missing" | "available"
}) {
  const host = document.createElement("main")
  host.dataset.testid = "reading-fixture"
  host.style.cssText = "position:fixed;top:24px;right:24px;width:400px;z-index:1000"
  document.body.appendChild(host)
  function Fixture() {
    const [state, setState] = createStore({
      active: true,
      pinned: false,
      restoring: false,
      pages: 0,
      growth: 0,
      settled: !input.slowSync,
      prefixGrowth: 0,
    })
    const rows = Array.from(
      { length: input.count ?? 30 },
      (_, index) => new TimelineRow.UserMessage({ userMessageID: `reading-${index}` }),
    )
    const visible = createMemo(() => (!state.settled && input.slowSync === "missing" ? rows.slice(20) : rows))
    const rowByKey = createMemo(() => new Map(visible().map((row) => [TimelineRow.key(row), row])))
    const indexes = createMemo(() => new Map(visible().map((row, index) => [row.userMessageID, index])))
    const saved = {
      anchor: {
        rowKey: `user-message:reading-${input.index}`,
        messageID: `reading-${input.index}`,
        offset: input.offset,
      } as ReadingAnchor,
    }
    const navigation = {
      end: () => {},
      reveal: (_id: string) => {},
      offset: (_offset: number, _behavior: ScrollBehavior) => {},
    }
    const request = Promise.withResolvers<void>()
    const observation = { started: 0, writes: 0, viewport: undefined as HTMLDivElement | undefined }
    const timeline = createTimelineVirtualizer({
      active: () => state.active,
      sessionKey: () => "reading-fixture",
      readingAnchor: () => saved.anchor,
      onLeave: (_key, anchor) => {
        saved.anchor = anchor
        host.dataset.anchor = JSON.stringify(anchor)
      },
      setRestoring: (_key, value) => {
        if (value) observation.started = performance.now()
        if (!value) host.dataset.restorationMs = String(performance.now() - observation.started)
        setState("restoring", value)
      },
      history: {
        more: () => !!input.missing,
        loading: () => false,
        settled: () => state.settled,
        loadOlder: async () => {
          setState("pages", (value) => value + 1)
          if (input.request === "wait") await request.promise
          if (input.request === "error") throw new Error("History unavailable")
        },
      },
      projection: {
        rows: visible,
        rowByKey,
        activeMessageID: () => (input.streaming ? "reading-29" : undefined),
        messageRowIndex: indexes,
        messageLastRowIndex: indexes,
      },
      showHeader: () => false,
      pinned: () => state.pinned,
      scroll: () => ({ overflow: true, jump: true }),
      setScrollRef: (element) => {
        if (!element || observation.viewport === element) return
        observation.viewport = element
        const scroll = element.scrollTo.bind(element)
        element.scrollTo = (options?: ScrollToOptions | number, y?: number) => {
          observation.writes += 1
          host.dataset.writes = String(observation.writes)
          if (typeof options === "number") {
            scroll(options, y ?? 0)
            return
          }
          scroll(options)
        }
      },
      setContentRef: () => {},
      onPin: () => setState("pinned", true),
      onUnpin: () => setState("pinned", false),
      onScheduleScrollState: () => {},
      onResumeScroll: () => navigation.end(),
      setScrollToEnd: (end) => {
        navigation.end = end
      },
      setRevealMessage: (reveal) => {
        navigation.reveal = reveal
      },
      setScrollToOffset: (offset) => {
        navigation.offset = offset
      },
      onSelectionInteraction: () => {},
      onUserScroll: () => {},
      onHistoryScroll: () => {
        host.dataset.historyScroll = "true"
      },
    })
    const interval = window.setInterval(() => {
      if (input.streaming) setState("growth", (value) => value + 1)
    }, 30)
    onCleanup(() => clearInterval(interval))
    return (
      <div
        data-pinned={state.pinned}
        data-restoring={state.restoring}
        data-pages={state.pages}
        data-growth={state.growth}
      >
        <button onClick={() => setState("active", false)}>Leave</button>
        <button onClick={() => setState("active", true)}>Return</button>
        <button onClick={() => request.resolve()}>Resolve history</button>
        <button onClick={() => setState("settled", true)}>Complete sync</button>
        <button
          onClick={() => {
            navigation.reveal("reading-12")
            navigation.offset(740, "auto")
            setState("prefixGrowth", 100)
          }}
        >
          Position after reveal and resize
        </button>
        <button
          onClick={() => {
            navigation.reveal("reading-20")
            setState("active", false)
          }}
        >
          Navigate and leave
        </button>
        <div style={{ height: "180px" }}>
          <timeline.View
            header={null}
            workspaceSession={() => false}
            deferred={() => false}
            renderRow={(row) => (
              <div
                data-component="markdown"
                data-markdown-ready={
                  (input.streaming && row().userMessageID === "reading-29") ||
                  (input.pendingAnchor && row().userMessageID === `reading-${input.index}`)
                    ? undefined
                    : ""
                }
                style={{
                  height: `${60 + (row().userMessageID === "reading-29" ? state.growth : row().userMessageID === "reading-11" ? state.prefixGrowth : 0)}px`,
                }}
              >
                {row().userMessageID}
              </div>
            )}
          />
        </div>
      </div>
    )
  }
  render(
    () => (
      <LanguageProvider locale="en">
        <Fixture />
      </LanguageProvider>
    ),
    host,
  )
}
