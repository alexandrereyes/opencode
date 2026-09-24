import type { SessionMessageUser } from "@opencode/client/promise"
import { createResizeObserver } from "@solid-primitives/resize-observer"
import { useLocation } from "@solidjs/router"
import { createEffect, createMemo, on, onCleanup, untrack } from "solid-js"
import { createStore } from "solid-js/store"
import { useLayout } from "@/shell/state/layout"
import type { SessionModel } from "../model"
import { useSessionHashScroll } from "../use-session-hash-scroll"
import { createHistoryAdmission } from "./history-admission"
import { createTimelineModel } from "./model"
import { readingPositions } from "./reading-position"

export function createSessionTimelineInteraction(session: SessionModel) {
  const layout = useLayout()
  const location = useLocation()
  const timeline = createTimelineModel({ session })
  const historyAdmission = createHistoryAdmission()
  const entry = createMemo(
    on(session.identity.sessionKey, (key) => ({
      explicit: !!location.hash || !!layout.pendingMessage.peek(key),
      pinned: readingPositions.get(key)?.pinned ?? true,
    })),
  )
  const [state, setState] = createStore({
    messageID: undefined as string | undefined,
    pendingMessage: undefined as string | undefined,
    scroll: {
      overflow: false,
      jump: false,
    },
    follow: {
      sessionKey: session.identity.sessionKey(),
      pinned: !entry().explicit && entry().pinned,
    },
    refs: {
      scroller: undefined as HTMLDivElement | undefined,
      content: undefined as HTMLDivElement | undefined,
      dock: undefined as HTMLDivElement | undefined,
    },
  })
  // The single source of truth for "follow the newest content". The virtualizer pins and unpins
  // it from scroll geometry; everything else only expresses explicit intent.
  const pinned = () =>
    state.follow.sessionKey !== session.identity.sessionKey()
      ? !entry().explicit && entry().pinned
      : state.follow.pinned
  let cancelRestoration = () => {}
  const restorations = new Set<string>()
  const restoring = () => restorations.has(session.identity.sessionKey())
  const follow = (value: boolean) => {
    const key = session.identity.sessionKey()
    readingPositions.follow(key, value)
    setState("follow", { sessionKey: key, pinned: value })
  }
  readingPositions.follow(session.identity.sessionKey(), state.follow.pinned)
  const pin = () => follow(true)
  const pause = () => {
    cancelRestoration()
    follow(false)
  }
  const unpin = () => {
    if (!scroller || scroller.scrollHeight - scroller.clientHeight <= 1) return
    pause()
  }
  let scroller: HTMLDivElement | undefined
  let dockHeight = 0
  let revealMessage = (_id: string, _partID?: string) => {}
  let scrollToEnd = () => {}
  let scrollToOffset = (_offset: number, _behavior: ScrollBehavior) => {}
  let scrollMark = 0
  let messageMark = 0
  let scrollStateFrame: number | undefined
  let scrollStateTarget: HTMLDivElement | undefined
  let fillFrame: number | undefined
  let historyContinuationFrame: number | undefined
  const historyRequests = new Set<string>()
  const visibleUserMessages = timeline.visibleUserMessages
  const anchor = (id: string) => `message-${id}`

  const cursor = () => {
    if (!scroller) return state.messageID
    const box = scroller.getBoundingClientRect()
    const line = box.top + 100
    const list = [...scroller.querySelectorAll<HTMLElement>("[data-message-id]")]
      .map((element) => {
        const id = element.dataset.messageId
        if (!id) return undefined
        const rect = element.getBoundingClientRect()
        return { id, top: rect.top, bottom: rect.bottom }
      })
      .filter((item): item is { id: string; top: number; bottom: number } => !!item)
    const shown = list.filter((item) => item.bottom > box.top && item.top < box.bottom)
    const hit = shown.find((item) => item.top <= line && item.bottom >= line)
    if (hit) return hit.id
    const near = [...shown].sort((a, b) => {
      const aDistance = Math.abs(a.top - line)
      const bDistance = Math.abs(b.top - line)
      if (aDistance !== bDistance) return aDistance - bDistance
      return a.top - b.top
    })[0]
    if (near) return near.id
    return list.filter((item) => item.top <= line).at(-1)?.id ?? list[0]?.id ?? state.messageID
  }
  const setActiveMessage = (message: SessionMessageUser | undefined) => {
    messageMark = scrollMark
    setState("messageID", message?.id)
  }
  const jumpThreshold = (element: HTMLDivElement) => Math.max(400, element.clientHeight)
  const updateScrollState = (element: HTMLDivElement) => {
    const max = element.scrollHeight - element.clientHeight
    const distance = max - element.scrollTop
    const overflow = max > 1
    const jump = overflow && distance > jumpThreshold(element)
    if (state.scroll.overflow === overflow && state.scroll.jump === jump) return
    setState("scroll", { overflow, jump })
  }
  const scheduleScrollState = (element: HTMLDivElement) => {
    scrollStateTarget = element
    if (scrollStateFrame !== undefined) return
    scrollStateFrame = requestAnimationFrame(() => {
      scrollStateFrame = undefined
      const target = scrollStateTarget
      scrollStateTarget = undefined
      if (target) updateScrollState(target)
    })
  }
  createEffect(
    on(
      session.identity.sessionKey,
      () => {
        follow(untrack(pinned))
        historyAdmission.release()
        setState("messageID", undefined)
        setState("pendingMessage", undefined)
        setState("scroll", { overflow: false, jump: false })
      },
      { defer: true },
    ),
  )
  const { clearMessageHash, scrollToMessage } = useSessionHashScroll({
    sessionKey: session.identity.sessionKey,
    sessionID: () => session.identity.params.id,
    messagesReady: timeline.ready,
    visibleUserMessages,
    historyMore: timeline.history.more,
    historyLoading: timeline.history.loading,
    loadMore: loadOlder,
    currentMessageId: () => state.messageID,
    pendingMessage: () => state.pendingMessage,
    setPendingMessage: (value) => setState("pendingMessage", value),
    setActiveMessage,
    follow: {
      unpin: pause,
      toBottom: () => {
        if (pinned()) scrollToEnd()
      },
    },
    onNavigate: () => cancelRestoration(),
    scroller: () => scroller,
    anchor,
    revealMessage: (id) => revealMessage(id),
    scrollToOffset: (offset, behavior) => scrollToOffset(offset, behavior),
    scheduleScrollState,
    consumePendingMessage: (key) => layout.pendingMessage.consume(key),
  })
  const resume = () => {
    setState("messageID", undefined)
    pin()
    scrollToEnd()
    clearMessageHash()
    if (scroller) scheduleScrollState(scroller)
  }
  const navigateMessage = (offset: number) => {
    const messages = visibleUserMessages()
    if (messages.length === 0) return
    const current = state.messageID && messageMark === scrollMark ? state.messageID : cursor()
    const base = current ? messages.findIndex((message) => message.id === current) : messages.length
    const target = (base === -1 ? messages.length : base) + offset
    if (target < 0 || target > messages.length) return
    if (target === messages.length) {
      resume()
      return
    }
    unpin()
    scrollToMessage(messages[target], "auto")
  }
  // A gesture inside a nested scrollable region scrolls that region, not the timeline.
  const markUserScroll = (target?: EventTarget | null) => {
    if (!scroller) return
    const element = target instanceof Element ? target : undefined
    const nested = element?.closest("[data-scrollable]")
    if (nested && nested !== scroller) return
    scrollMark += 1
  }
  const selectionInteraction = () => {
    const selection = window.getSelection()
    if (selection && selection.toString().length > 0) unpin()
  }
  const setScrollRef = (element: HTMLDivElement | undefined) => {
    scroller = element
    setState("refs", "scroller", element)
    if (!element) return
    scheduleScrollState(element)
    fill()
  }
  async function loadOlder() {
    const owner = session.ownership.capture()
    if (timeline.history.loading() || historyRequests.has(owner.key)) return
    historyRequests.add(owner.key)
    const before = timeline.messages().length
    try {
      await timeline.history.loadOlder()
    } finally {
      historyRequests.delete(owner.key)
    }
    if (!owner.current() || timeline.messages().length <= before) return
    historyAdmission.loaded()
    if (restoring() || pinned() || !scroller || scroller.scrollTop >= 200 || !timeline.history.more()) return
    if (historyContinuationFrame !== undefined) cancelAnimationFrame(historyContinuationFrame)
    historyContinuationFrame = requestAnimationFrame(() => {
      historyContinuationFrame = undefined
      owner.run(onHistoryScroll)
    })
  }
  const onHistoryScroll = () => {
    if (
      restoring() ||
      historyRequests.has(session.ownership.key()) ||
      timeline.history.loading() ||
      historyAdmission.waiting() ||
      pinned() ||
      !scroller ||
      scroller.scrollTop >= 200
    )
      return
    void loadOlder()
  }
  const fill = () => {
    if (fillFrame !== undefined) return
    fillFrame = requestAnimationFrame(() => {
      fillFrame = undefined
      if (restoring() || !session.identity.params.id || !timeline.ready()) return
      if (!pinned() || timeline.history.loading() || !scroller) return
      if (scroller.scrollHeight > scroller.clientHeight + 1 || !timeline.history.more()) return
      void loadOlder()
    })
  }
  createEffect(
    on(
      () => visibleUserMessages().at(-1)?.id,
      (lastID, previousID) => {
        if (lastID && previousID && lastID > previousID) setState("messageID", undefined)
      },
      { defer: true },
    ),
  )
  createEffect(
    on(
      () => session.identity.params.id,
      (id, previous) => {
        if (!id || !previous || id === previous || state.messageID || state.pendingMessage || location.hash) return
        if (pinned()) scrollToEnd()
      },
    ),
  )
  createEffect(
    on(
      pinned,
      (value) => {
        if (!value) return
        setState("messageID", undefined)
        clearMessageHash()
      },
      { defer: true },
    ),
  )
  createEffect(
    on(
      () =>
        [
          session.identity.params.id,
          timeline.ready(),
          timeline.history.more(),
          timeline.history.loading(),
          pinned(),
          visibleUserMessages().length,
        ] as const,
      ([id, ready, more, loading, following]) => {
        if (id && ready && more && !loading && following) fill()
      },
      { defer: true },
    ),
  )
  createResizeObserver(
    () => state.refs.content,
    () => {
      if (scroller) scheduleScrollState(scroller)
      fill()
    },
  )
  createResizeObserver(
    () => state.refs.dock,
    ({ height }) => {
      const next = Math.ceil(height)
      if (next === dockHeight) return
      const delta = next - dockHeight
      const stick = scroller
        ? pinned() ||
          (!restoring() && scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop < 10 + Math.max(0, delta))
        : false
      dockHeight = next
      if (stick) scrollToEnd()
      if (scroller) scheduleScrollState(scroller)
      fill()
    },
  )
  onCleanup(() => {
    if (historyContinuationFrame !== undefined) cancelAnimationFrame(historyContinuationFrame)
    if (scrollStateFrame !== undefined) cancelAnimationFrame(scrollStateFrame)
    if (fillFrame !== undefined) cancelAnimationFrame(fillFrame)
  })

  return {
    actions: {
      navigateMessage,
      revealMessage: (id: string, partID?: string) => revealMessage(id, partID),
      resume,
      setActiveMessage,
    },
    lastUserMessage: timeline.lastUserMessage,
    resource: timeline.resource,
    ready: timeline.ready,
    scroll: state.scroll,
    scroller: () => state.refs.scroller,
    view: {
      pause,
      explicitNavigation: () =>
        !!location.hash || !!state.pendingMessage || !!layout.pendingMessage.peek(session.identity.sessionKey()),
      history: { ...timeline.history, settled: () => !timeline.resource.loading },
      historyAdmission,
      setRestoring: (key: string, value: boolean) => {
        if (value) restorations.add(key)
        if (!value) restorations.delete(key)
      },
      setCancelRestoration: (cancel: () => void) => {
        cancelRestoration = cancel
      },
      anchor,
      markUserScroll,
      onHistoryScroll,
      pin,
      pinned,
      selectionInteraction,
      scheduleScrollState,
      setContentRef: (element: HTMLDivElement | undefined) => {
        setState("refs", "content", element)
        if (scroller) scheduleScrollState(scroller)
      },
      setDockRef: (element: HTMLDivElement | undefined) => {
        setState("refs", "dock", element)
      },
      setRevealMessage: (reveal: (id: string, partID?: string) => void) => {
        revealMessage = reveal
      },
      setScrollRef,
      setScrollToEnd: (scroll: () => void) => {
        scrollToEnd = scroll
      },
      setScrollToOffset: (scroll: (offset: number, behavior: ScrollBehavior) => void) => {
        scrollToOffset = scroll
      },
      unpin,
    },
  }
}

export type SessionTimelineInteraction = ReturnType<typeof createSessionTimelineInteraction>
