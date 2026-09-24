import {
  createVirtualizer,
  defaultRangeExtractor,
  elementScroll,
  observeElementRect,
  type Range,
  type VirtualItem,
} from "@tanstack/solid-virtual"
import { isScrollKeyTarget, scrollKey, scrollKeyOwner, ScrollView } from "@opencode/ui-custom/scroll-view"
import { TimelineRow } from "@opencode/session-ui-custom/timeline/projection"
import { useLanguage } from "@/runtime/i18n/language"
import {
  batch,
  createComputed,
  createEffect,
  createMemo,
  createSignal,
  For,
  on,
  onCleanup,
  onMount,
  untrack,
  Show,
  type Accessor,
  type JSX,
} from "solid-js"
import { createStore, reconcile } from "solid-js/store"
import { createMediaQuery } from "@solid-primitives/media"
import type { createTimelineProjection } from "./projection"
import { observeElementOffsetReconnectAware } from "./observe-element-offset"
import { filterVirtualIndexes } from "./virtual-items"
import type { ReadingAnchor } from "./reading-position"
import { defersScrollWrites, type HistoryAdmission } from "./history-admission"

const fallbackItemSize = 60
const pendingMarkdown = '[data-component="markdown"]:not([data-markdown-ready])'
// Distance from the bottom that counts as "at the end". Deliberately tight: a collapse clamps
// exactly to the end, while a one-pixel nudge upward is a deliberate move away from it.
const endEpsilon = 0.5
const upwardKeys = new Set(["up", "page-up", "home"])
// Longer than TanStack's 150ms post-touchend grace and isScrolling reset, so the
// iOS write after settling is immediate instead of deferred by TanStack.
const settleDelay = 200
const cache = new Map<
  string,
  {
    measurements: VirtualItem[]
    toolOpen: Record<string, boolean | undefined>
    patchGroupKeys: Map<string, string>
    presentationKey?: string
  }
>()

type Projection = Pick<
  ReturnType<typeof createTimelineProjection>,
  "activeMessageID" | "messageLastRowIndex" | "messageRowIndex" | "rowByKey" | "rows"
>

type Input = {
  active?: Accessor<boolean>
  sessionKey: Accessor<string>
  presentationKey?: Accessor<string>
  projection: Projection
  showHeader: Accessor<boolean>
  /** True while the timeline follows the newest content. Drives every anchoring decision. */
  pinned: Accessor<boolean>
  scroll: Accessor<{ overflow: boolean; jump: boolean }>
  onResumeScroll: () => void
  setScrollRef: (element: HTMLDivElement | undefined) => void
  setContentRef: (element: HTMLDivElement) => void
  onScheduleScrollState: (element: HTMLDivElement) => void
  onPin: () => void
  onUnpin: () => void
  onSelectionInteraction: (event: MouseEvent) => void
  onUserScroll: (target?: EventTarget | null) => void
  onHistoryScroll: () => void
  readingAnchor?: () => ReadingAnchor | undefined
  onLeave?: (key: string, anchor: ReadingAnchor) => void
  explicitNavigation?: () => boolean
  history?: { more: () => boolean; loading: () => boolean; settled: () => boolean; loadOlder: () => Promise<void> }
  historyAdmission?: Pick<HistoryAdmission, "held" | "hold" | "release">
  setRestoring?: (key: string, value: boolean) => void
  setCancelRestoration?: (cancel: () => void) => void
  canRenderImmediately?: (
    row: TimelineRow.TimelineRow,
    disclosure: Readonly<Record<string, boolean | undefined>>,
  ) => boolean
  setRevealMessage?: (fn: (id: string, partID?: string) => void) => void
  setScrollToEnd?: (fn: () => void) => void
  setScrollToOffset?: (fn: (offset: number, behavior: ScrollBehavior) => void) => void
}

type ViewProps = {
  header: JSX.Element
  bottomSpacer?: JSX.Element
  workspaceSession: Accessor<boolean>
  deferred: (row: TimelineRow.TimelineRow) => boolean
  renderRow: (row: Accessor<TimelineRow.TimelineRow>, onSizeChange?: () => void) => JSX.Element
}

export function createTimelineVirtualizer(input: Input) {
  const language = useLanguage()
  const active = () => input.active?.() !== false
  const isDesktop = createMediaQuery("(min-width: 768px)")
  const deferredScrollWrites = defersScrollWrites()
  const topOffset = () => (input.showHeader() ? 64 : isDesktop() ? 0 : 16)
  const ownerSessionKey = input.sessionKey()
  const entry = cache.get(ownerSessionKey)
  const cached = entry?.presentationKey === input.presentationKey?.() ? entry : undefined
  const initialMeasurements = cached?.measurements
  const coldBottomMount = !initialMeasurements?.length && input.pinned()
  const [listRoot, setListRoot] = createSignal<HTMLDivElement>()
  const [toolOpen, setToolOpen] = createStore<Record<string, boolean | undefined>>(cached?.toolOpen ?? {})
  const patchGroupKeys = cached?.patchGroupKeys ?? new Map<string, string>()
  createEffect(
    on(
      () => input.presentationKey?.(),
      () => setToolOpen(reconcile({})),
      { defer: true },
    ),
  )
  const [rendering, setRendering] = createStore({ initialTail: coldBottomMount, scrollAdjustment: 0 })
  const rows = input.projection.rows
  const rowByKey = input.projection.rowByKey
  const userIndexes = createMemo(() => rows().flatMap((row, index) => (row._tag === "UserMessage" ? [index] : [])))
  const userRows = createMemo(
    () => new Map(userIndexes().map((index, position) => [index, userIndexes()[position + 1]])),
  )
  const rowKeys = createMemo(() => rows().map(TimelineRow.key), undefined, {
    equals: (previous, next) => previous.length === next.length && previous.every((key, index) => key === next[index]),
  })
  const knownKeys = new Set(rowKeys())
  const addedKeys = new Set<string>()
  const getItemKey = createMemo(() => {
    const keys = rowKeys()
    keys
      .filter((key) => !knownKeys.has(key))
      .forEach((key) => {
        knownKeys.add(key)
        addedKeys.add(key)
      })
    return (index: number) => keys[index] ?? `removed:${index}`
  })
  const rangeExtractor = createMemo(() => {
    const id = input.projection.activeMessageID()
    const active = id ? (input.projection.messageLastRowIndex().get(id) ?? -1) : -1
    const initialTail = rendering.initialTail && input.pinned()
    return (range: Range) => {
      // Batch a bounded cheap suffix, but stop before unknown/large content.
      // A large tail still mounts alone before estimates expose earlier history.
      const start = Math.max(0, range.startIndex - 2)
      const boundary = initialTail
        ? rows()
            .slice(start, range.count)
            .findLastIndex(
              (row) =>
                !(
                  row._tag === "AssistantPart" &&
                  row.group.type === "context" &&
                  row.group.refs.length <= 64 &&
                  !toolOpen[`context:${row.group.key}`]
                ) && !input.canRenderImmediately?.(row, toolOpen),
            )
        : -1
      const first = Math.min(range.count - 1, start + boundary + 1)
      const indexes = initialTail
        ? Array.from({ length: range.count - first }, (_, index) => first + index)
        : defaultRangeExtractor({ ...range, overscan: 2 })
      // Keep just the user header owning the visible response. Its single DOM
      // instance sticks inside a containing block ending at the next message.
      // TurnGap belongs to the upcoming user in the projection; the previous
      // header still owns that gap until the next user actually reaches it.
      const users = userIndexes()
      let low = 0
      let high = users.length
      while (low < high) {
        const middle = (low + high) >>> 1
        if (users[middle] <= range.startIndex) {
          low = middle + 1
          continue
        }
        high = middle
      }
      const header = users[low - 1]
      return filterVirtualIndexes(
        [
          ...new Set([
            ...indexes,
            ...(active < 0 ? [] : [active]),
            ...(header === undefined || initialTail ? [] : [header]),
          ]),
        ].sort((a, b) => a - b),
        range.count,
      )
    }
  })
  const measuredElements = new WeakSet<Element>()
  let touchStart: number | undefined
  let touchTarget: EventTarget | null = null
  let touchNested = false
  let touchScrolling = false
  let touchAdjustment = 0
  let touchEndedAt = -Infinity
  let pointerHeld = false
  let maxScroll = 0
  let virtualContent: HTMLDivElement | undefined
  let scrollTop = 0
  let reportOffset: ((offset: number, scrolling: boolean) => void) | undefined
  let reportRect: ((rect: { width: number; height: number }) => void) | undefined
  let batchingColdSizes = false
  let logicalOffset: number | undefined
  const recovery = {
    attempt: undefined as
      | undefined
      | {
          anchor: ReadingAnchor
          deadline: number
          pages: number
          loading: boolean
          frame: number
          measured: Element | undefined
          stable: number
          geometry: string
        },
    entered: false,
  }

  function finishRestoration(reason: "cancel" | "complete" | "timeout" | "error" = "cancel") {
    const attempt = recovery.attempt
    if (!attempt) return
    cancelAnimationFrame(attempt.frame)
    recovery.attempt = undefined
    const root = listRoot()
    if (root) {
      scrollTop = root.scrollTop
      maxScroll = root.scrollHeight - root.clientHeight
      if (active() && maxScroll <= 1 && (reason === "complete" || reason === "timeout")) input.onPin()
      if (active()) input.onScheduleScrollState(root)
    }
    input.setRestoring?.(ownerSessionKey, false)
  }

  function leave() {
    if (!recovery.entered) return
    recovery.entered = false
    if (recovery.attempt) {
      finishRestoration()
      return
    }
    // The virtualizer offset already includes the iOS translation. Sticky user
    // containers span a whole group, so their DOM rectangles are not row bounds.
    const offset = logicalOffset ?? virtualizer.scrollOffset ?? scrollTop
    const item = virtualizer.measurementsCache.find((item) => item.start <= offset && offset < item.end)
    const row = item && rows()[item.index]
    if (!item || !row) return
    input.onLeave?.(ownerSessionKey, {
      rowKey: String(item.key),
      messageID: row.userMessageID,
      offset: Math.max(0, offset - item.start),
    })
  }

  function restore() {
    recovery.entered = true
    input.setCancelRestoration?.(finishRestoration)
    const anchor = input.readingAnchor?.()
    if (!anchor || input.pinned() || input.explicitNavigation?.()) return
    const attempt = {
      anchor,
      deadline: performance.now() + 3000,
      pages: 0,
      loading: false,
      frame: 0,
      measured: undefined as Element | undefined,
      stable: 0,
      geometry: "",
    }
    recovery.attempt = attempt
    input.setRestoring?.(ownerSessionKey, true)
    const frame = () => {
      if (recovery.attempt !== attempt) return
      if (!active() || input.explicitNavigation?.()) {
        finishRestoration()
        return
      }
      if (performance.now() >= attempt.deadline) {
        finishRestoration("timeout")
        return
      }
      attempt.frame = requestAnimationFrame(frame)
      if (attempt.loading || input.history?.loading()) {
        attempt.stable = 0
        return
      }
      const settled = input.history?.settled() ?? true
      const exact = rowKeys().indexOf(anchor.rowKey)
      const user =
        exact < 0 ? rows().findIndex((row) => row._tag === "UserMessage" && row.userMessageID === anchor.messageID) : -1
      const index = exact >= 0 ? exact : user >= 0 ? user : input.projection.messageRowIndex().get(anchor.messageID)
      if (index === undefined && !settled) {
        attempt.stable = 0
        return
      }
      const root = listRoot()
      if (!root?.isConnected || !root.clientHeight) return
      if (index === undefined) {
        if (input.history?.more() && attempt.pages < 3) {
          attempt.pages += 1
          attempt.loading = true
          void input.history.loadOlder().then(
            () => {
              if (recovery.attempt === attempt) attempt.loading = false
            },
            () => {
              if (recovery.attempt === attempt) finishRestoration("error")
            },
          )
          return
        }
        input.onPin()
        virtualizer.scrollToEnd()
        finishRestoration("complete")
        return
      }
      const item = virtualizer.measurementsCache[index]
      if (!item) return
      const element = virtualizer.elementsCache.get(item.key)
      const measured = element?.isConnected && !element.style.minHeight
      const ready = measured && !element.querySelector(pendingMarkdown)
      if (measured && attempt.measured !== element) {
        attempt.measured = element
        attempt.stable = 0
        virtualizer.measureElement(element)
        return
      }
      if (!measured) attempt.measured = undefined
      const desired = item.start + (measured && exact >= 0 ? Math.min(anchor.offset, Math.max(0, item.size - 1)) : 0)
      const destination = Math.max(0, Math.min(desired, root.scrollHeight - root.clientHeight))
      const geometry = `${item.key}/${item.start}/${item.size}/${destination}`
      const write = Math.abs(root.scrollTop + rendering.scrollAdjustment - destination) > 1
      attempt.stable = settled && ready && !write && geometry === attempt.geometry ? attempt.stable + 1 : 0
      attempt.geometry = geometry
      if (write) virtualizer.scrollToOffset(destination)
      if (attempt.stable >= 2) finishRestoration("complete")
    }
    attempt.frame = requestAnimationFrame(frame)
  }

  const virtualizer = createVirtualizer<HTMLDivElement, HTMLDivElement>({
    get count() {
      return rows().length
    },
    getScrollElement: () => listRoot() ?? null,
    observeElementRect: (instance, callback) => {
      reportRect = callback
      return observeElementRect(instance, (rect) => {
        if (rect.height > 0) listRoot()?.style.setProperty("--timeline-user-max-height", `${rect.height * 0.4}px`)
        if (active()) callback(rect)
      })
    },
    // Route navigation detaches and reattaches the scroll element, which drops its offset.
    observeElementOffset: (instance, callback) => {
      reportOffset = (offset, scrolling) => {
        if (!active()) return
        // Rows and the sizer use the opposite translation while native touch
        // scrolling keeps its own offset. Range selection uses the logical offset.
        batch(() => {
          logicalOffset = offset + rendering.scrollAdjustment
          callback(rendering.scrollAdjustment ? Math.max(0, logicalOffset) : offset, scrolling)
          // Reconcile both start boundaries in one native write. Gradually
          // clamping row translations lets the compositor paint between
          // corrections and makes the content oscillate at the top.
          const root = listRoot()
          if (
            rendering.scrollAdjustment !== 0 &&
            root &&
            // iOS applies a native write under a held finger or during momentum
            // only a frame later, after the rows dropped their translation.
            // It waits for the settle timer below instead.
            !deferredScrollWrites &&
            (logicalOffset <= 0 || offset <= 0 || (touchStart !== undefined && offset <= root.clientHeight))
          )
            flushTouchAdjustment()
          if (!scrolling && touchStart === undefined && !deferredScrollWrites) finishTouchScroll()
        })
        settleColdBottom()
        // Any reported scroll, including our own anchoring write, defers iOS corrections.
        if (scrolling) holdHistory()
        else scheduleSettle()
      }
      return observeElementOffsetReconnectAware(instance, reportOffset, () => {
        if (!active()) return
        virtualContent?.querySelectorAll<HTMLDivElement>("[data-index]").forEach(virtualizer.measureElement)
        if (input.pinned()) virtualizer.scrollToEnd()
        settleColdBottom()
      })
    },
    initialOffset: () => (input.pinned() ? Number.MAX_SAFE_INTEGER : 0),
    initialMeasurementsCache: initialMeasurements,
    estimateSize: () => fallbackItemSize,
    // A newly observed element gets a real ResizeObserver box before paint. Reuse
    // its snapshot on attachment, but later explicit measurements must read layout
    // so deferred/rewrapped content cannot keep stale, clipped heights (TanStack/virtual#1183).
    measureElement: (element, entry, instance) => {
      if (!active() || !element.isConnected)
        return (
          instance.itemSizeCache.get(instance.options.getItemKey(instance.indexFromElement(element))) ??
          fallbackItemSize
        )
      const initial = !measuredElements.has(element)
      measuredElements.add(element)
      const box = entry?.borderBoxSize[0]
      if (box) return Math.round(box.blockSize)
      if (initial) {
        const size = instance.itemSizeCache.get(instance.options.getItemKey(instance.indexFromElement(element)))
        if (size !== undefined || coldPending) return size ?? fallbackItemSize
      }
      return element.offsetHeight
    },
    scrollToFn: (offset, options, instance) => {
      if (!active()) return
      if (batchingColdSizes && input.pinned()) return
      setRendering("scrollAdjustment", 0)
      if (virtualContent) virtualContent.style.height = `${instance.getTotalSize()}px`
      elementScroll(offset, options, instance)
      // Navigation can leave this view before the native scroll event reports
      // the committed (possibly clamped) write back to the virtualizer.
      const root = listRoot()
      if (root?.isConnected) logicalOffset = root.scrollTop
    },
    get getItemKey() {
      return getItemKey()
    },
    get anchorTo() {
      return input.pinned() ? "end" : "start"
    },
    get followOnAppend() {
      return input.pinned()
    },
    scrollEndThreshold: 80,
    get scrollMargin() {
      // Empty projections still need the bottom spacer for running status.
      return rows().length > 0 ? topOffset() : 0
    },
    paddingEnd: 64,
    get rangeExtractor() {
      return rangeExtractor()
    },
  })
  const resizeItem = virtualizer.resizeItem
  const pendingSizes = new Map<number, { key: string; size: number }>()
  let resizeScheduled = false
  // Read the whole measurement delivery before committing reactive row sizes.
  // Otherwise each row can render and force layout before the next is measured.
  virtualizer.resizeItem = (index, size) => {
    if (!active()) return
    const row = rows()[index]
    if (!row) return
    const key = TimelineRow.key(row)
    if ((virtualizer.itemSizeCache.get(key) ?? fallbackItemSize) === size) {
      pendingSizes.delete(index)
      return
    }
    pendingSizes.set(index, { key, size })
    if (resizeScheduled) return
    resizeScheduled = true
    queueMicrotask(() => {
      resizeScheduled = false
      if (!pendingSizes.size) return
      const sizes = [...pendingSizes]
      pendingSizes.clear()
      if (!active()) return
      // The hidden pinned mount needs one bottom write after the whole batch,
      // not a layout-forcing scroll adjustment for every measured row.
      batchingColdSizes = coldPending && input.pinned()
      batch(() => {
        sizes.forEach(([index, value]) => {
          const row = rows()[index]
          if (!row || TimelineRow.key(row) !== value.key) return
          resizeItem(index, value.size)
          // TanStack recalculates its range after each resize. Advance the
          // logical fold before deciding whether the next row needs anchoring.
          if (!touchAdjustment) return
          setRendering("scrollAdjustment", (value) => value + touchAdjustment)
          touchAdjustment = 0
          const root = listRoot()
          if (root) reportOffset?.(root.scrollTop, virtualizer.isScrolling)
        })
      })
      batchingColdSizes = false
      if (coldPending) pinColdBottom()
      settleColdBottom()
      if (coldPending) return
      if (!input.pinned()) return
      const root = listRoot()
      // Reopening a settled scroll-to-end operation can fight subsequent keyboard scrolling.
      if (root && Math.abs(root.scrollHeight - root.clientHeight - root.scrollTop) > endEpsilon)
        virtualizer.scrollToEnd()
    })
  }
  onCleanup(() => pendingSizes.clear())
  virtualizer.shouldAdjustScrollPositionOnItemSizeChange = (item, delta, instance) => {
    // Prepended rows can resize more than once as deferred content mounts. Keep
    // compensating while they remain entirely above the visible content fold.
    const first = instance.range?.startIndex
    const adjust = addedKeys.has(String(item.key))
      ? item.end <= (instance.scrollOffset ?? 0) + instance.scrollAdjustments + instance.options.scrollMargin
      : first !== undefined && item.index < first
    // iOS also defers while any scroll, including our own anchoring write, is
    // still reported, and for a grace period after release. Translate those
    // corrections too instead of moving rows.
    const deferred =
      touchScrolling ||
      (deferredScrollWrites && (instance.isScrolling || performance.now() - touchEndedAt < settleDelay))
    if (!deferred || input.pinned()) return adjust
    // iOS defers native scroll writes until momentum ends. Keep the same visual
    // anchor now, rather than moving rows now and snapping the viewport back later.
    if (adjust) touchAdjustment += delta
    return false
  }

  function finishTouchScroll() {
    touchScrolling = false
    flushTouchAdjustment()
  }

  function prepareNavigation() {
    if (!active()) return
    finishRestoration()
    if (touchStart === undefined) touchScrolling = false
    flushTouchAdjustment()
    // Explicit navigation writes the offset anyway and may target a held page.
    admitHistory()
  }

  let settleTimer: ReturnType<typeof setTimeout> | undefined

  function holdHistory() {
    if (!deferredScrollWrites) return
    input.historyAdmission?.hold()
    scheduleSettle()
  }

  // iOS writes only after the finger, momentum and rubber band have settled.
  // Translated corrections and held history pages are applied together then.
  function scheduleSettle() {
    if (!deferredScrollWrites) return
    if (!touchScrolling && !rendering.scrollAdjustment && !input.historyAdmission?.held()) return
    clearTimeout(settleTimer)
    settleTimer = setTimeout(() => {
      settleTimer = undefined
      // Release reschedules while the finger is still down.
      if (active() && touchStart !== undefined) return
      const root = listRoot()
      // Rubber-banding reports offsets outside the scrollable range; writing
      // there would anchor against a position Safari is about to discard.
      const bouncing = !!root && (root.scrollTop < 0 || root.scrollTop > root.scrollHeight - root.clientHeight + 1)
      if (active() && (virtualizer.isScrolling || bouncing)) {
        scheduleSettle()
        return
      }
      if (!active()) return
      finishTouchScroll()
      admitHistory()
    }, settleDelay)
  }

  function admitHistory() {
    clearTimeout(settleTimer)
    settleTimer = undefined
    if (!input.historyAdmission?.held()) return
    flushTouchAdjustment()
    input.historyAdmission.release()
    // Admission may leave the reader near the top without a native scroll event.
    requestAnimationFrame(() => {
      if (active() && !recovery.attempt) input.onHistoryScroll()
    })
  }
  onCleanup(() => {
    clearTimeout(settleTimer)
    // Cached inactive timelines share the admission and must not release the active hold.
    if (active()) input.historyAdmission?.release()
  })

  function flushTouchAdjustment() {
    const adjustment = rendering.scrollAdjustment
    const root = listRoot()
    if (!adjustment || !root) return
    // Transfer the translation into the native offset in the same paint.
    batch(() => {
      setRendering("scrollAdjustment", 0)
      if (virtualContent) virtualContent.style.height = `${virtualizer.getTotalSize()}px`
      elementScroll(Math.max(0, root.scrollTop + adjustment), {}, virtualizer)
    })
  }
  const virtualItemByKey = createMemo(
    () => new Map(virtualizer.getVirtualItems().map((item) => [item.key, item] as const)),
  )
  const virtualRowKeys = createMemo(() => virtualizer.getVirtualItems().map((item) => String(item.key)))

  createComputed(
    on(active, (value) =>
      untrack(() => {
        if (!value) {
          leave()
          return
        }
        restore()
      }),
    ),
  )
  createEffect(() => {
    if (active() && input.explicitNavigation?.()) finishRestoration()
  })
  onCleanup(leave)

  createEffect(() => {
    if (!active()) return
    const root = listRoot()
    if (root) input.setScrollRef(root)
    if (virtualContent) input.setContentRef(virtualContent)
    queueMicrotask(() => {
      if (!active() || !root?.isConnected) return
      // A detached view can miss its nonzero ResizeObserver delivery. Publish
      // its real viewport before restoring the offset and admitting rows.
      reportRect?.({ width: root.offsetWidth, height: root.offsetHeight })
      if (input.pinned()) virtualizer.scrollToEnd()
      reportOffset?.(root.scrollTop, false)
      settleColdBottom()
    })
    input.setRevealMessage?.((id, partID) => {
      if (!active()) return
      prepareNavigation()
      const partIndex = partID
        ? rows().findIndex(
            (row) => row._tag === "AssistantPart" && row.group.type === "part" && row.group.ref.partID === partID,
          )
        : -1
      const index = partIndex >= 0 ? partIndex : input.projection.messageRowIndex().get(id)
      if (index === undefined) return
      virtualizer.scrollToIndex(index, { align: "center" })
    })
    input.setScrollToOffset?.((offset, behavior) => {
      if (!active()) return
      prepareNavigation()
      virtualizer.scrollToOffset(offset, { behavior: behavior === "smooth" ? "smooth" : "auto" })
    })
    input.setScrollToEnd?.(() => {
      if (!active()) return
      prepareNavigation()
      if (!listRoot()?.isConnected) return
      input.onPin()
      virtualizer.scrollToEnd()
    })
  })

  let coldPending = coldBottomMount
  let settleQueued = false
  let contentObserver: MutationObserver | undefined
  let viewportObserver: ResizeObserver | undefined
  const pinColdBottom = () => {
    if (!active()) return
    const root = listRoot()
    if (!input.pinned() || !virtualContent || !root) return
    // scrollToEnd computes its target from the DOM, not the new size cache.
    virtualContent.style.height = `${virtualizer.getTotalSize()}px`
    if (Math.abs(root.scrollHeight - root.clientHeight - root.scrollTop) > endEpsilon) virtualizer.scrollToEnd()
    // Report after core size adjustments finish so they cannot apply a delta
    // twice. This avoids waiting a frame for the native scroll event.
    if (virtualizer.scrollOffset !== root.scrollTop) reportOffset?.(root.scrollTop, false)
  }
  const pendingMeasurements = () => {
    const items = virtualizer.getVirtualItems()
    return (
      (rows().length > 0 && items.length === 0) ||
      items.some((item) => !virtualizer.elementsCache.get(item.key)?.isConnected)
    )
  }
  const settleColdBottom = () => {
    if (!active() || !coldPending || settleQueued) return
    settleQueued = true
    queueMicrotask(() => {
      settleQueued = false
      const root = listRoot()
      if (!coldPending || !virtualContent?.isConnected || !root) return
      if (virtualContent.querySelector(pendingMarkdown)) return
      if (!root.clientHeight) return
      // Markdown can finish before ResizeObserver delivers its new box. The
      // normal measureElement path skips reads while scrolling; this gate needs
      // current boxes before expanding the estimated range or revealing it.
      virtualizer.elementsCache.forEach((element) => {
        if (element.isConnected) virtualizer.resizeItem(virtualizer.indexFromElement(element), element.offsetHeight)
      })
      if (pendingSizes.size || pendingMeasurements()) return
      pinColdBottom()
      if (input.pinned() && Math.abs(root.scrollHeight - root.clientHeight - root.scrollTop) > 1) return
      // The scroll event must update the range before newly exposed rows can reveal.
      if (root.scrollHeight > root.clientHeight && Math.abs((virtualizer.scrollOffset ?? 0) - root.scrollTop) > 1)
        return
      if (rendering.initialTail) {
        setRendering("initialTail", false)
        settleColdBottom()
        return
      }
      if (pendingSizes.size || pendingMeasurements() || virtualContent.querySelector(pendingMarkdown)) return
      coldPending = false
      contentObserver?.disconnect()
      viewportObserver?.disconnect()
      virtualContent.style.removeProperty("visibility")
    })
  }
  onMount(() => {
    if (!coldPending || !virtualContent) return
    contentObserver = new MutationObserver(settleColdBottom)
    contentObserver.observe(virtualContent, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["data-markdown-ready"],
    })
    viewportObserver = new ResizeObserver(settleColdBottom)
    const root = listRoot()
    if (root) viewportObserver.observe(root)
    settleColdBottom()
  })

  let measuredSessionKey = input.sessionKey()
  createEffect(() => {
    const key = input.sessionKey()
    if (measuredSessionKey !== key) {
      measuredSessionKey = key
      virtualizer.measure()
    }
  })

  const bindListRoot = (root: HTMLDivElement) => {
    if (root === listRoot()) return
    // TanStack owns anchoring; browser scroll anchoring would fight its adjustments.
    root.style.overflowAnchor = "none"
    setListRoot(root)
    scrollTop = root.scrollTop
    maxScroll = root.scrollHeight - root.clientHeight
    if (active()) input.setScrollRef(root)
    viewportObserver?.observe(root)
    settleColdBottom()
  }

  // Upward input is the one intent geometry cannot recover: nudging up while still a pixel from
  // the end must stop following, even though the resulting position still looks like the end.
  const handleListWheel = (event: WheelEvent & { currentTarget: HTMLDivElement }) => {
    if (!active()) return
    finishRestoration()
    holdHistory()
    input.onUserScroll(event.target)
    const header =
      event.target instanceof Element ? event.target.closest<HTMLElement>("[data-sticky-user] [data-scrollable]") : null
    if (header && header.scrollHeight > header.clientHeight) return
    if (event.deltaY < 0) input.onUnpin()
  }

  const handleListTouchStart = (event: TouchEvent) => {
    if (!active()) return
    finishRestoration()
    clearTouchTarget()
    input.onUserScroll(event.target)
    touchScrolling = true
    touchStart = event.touches[0]?.clientY
    holdHistory()
    const root = listRoot()
    const nested = event.target instanceof Element ? event.target.closest<HTMLElement>("[data-scrollable]") : null
    touchNested = !!nested && nested !== root && nested.scrollHeight > nested.clientHeight
    // Native touch events keep their original target, even when streaming or
    // virtualization detaches it. Listen there instead of relying on bubbling.
    touchTarget = event.target
    touchTarget?.addEventListener("touchmove", handleListTouchMove, { passive: true })
    touchTarget?.addEventListener("touchend", handleListTouchEnd, { passive: true })
    touchTarget?.addEventListener("touchcancel", handleListTouchEnd, { passive: true })
    if (root) reportOffset?.(root.scrollTop, virtualizer.isScrolling)
  }

  const handleListTouchMove = (event: Event) => {
    if (!(event instanceof TouchEvent)) return
    const current = event.touches[0]?.clientY
    if (current === undefined || touchStart === undefined) return
    const previous = touchStart
    touchStart = current
    // A retained target can outlive its whole session view. Only the active
    // timeline may change the shared follow state; release still cleans up below.
    if (!active()) return
    // Dragging the content downward reveals earlier messages.
    if (current <= previous) return
    // A nested scrollport owns the intent. If it chains into the timeline at a
    // boundary, the resulting native timeline scroll below will unpin instead.
    if (touchNested) return
    input.onUnpin()
  }

  const handleListTouchEnd = () => {
    clearTouchTarget()
    touchStart = undefined
    touchEndedAt = performance.now()
    if (!virtualizer.isScrolling && !deferredScrollWrites) finishTouchScroll()
    scheduleSettle()
  }

  function clearTouchTarget() {
    touchTarget?.removeEventListener("touchmove", handleListTouchMove)
    touchTarget?.removeEventListener("touchend", handleListTouchEnd)
    touchTarget?.removeEventListener("touchcancel", handleListTouchEnd)
    touchTarget = null
  }
  onCleanup(clearTouchTarget)

  // Drag-selecting past the edge and dragging the scrollbar both scroll without a wheel or key,
  // so a held pointer is what separates those from the virtualizer's own measurement adjustments.
  const handleListPointerDown = (event: PointerEvent & { currentTarget: HTMLDivElement }) => {
    if (!active()) return
    finishRestoration()
    input.onUserScroll(event.target)
    pointerHeld = true
  }
  const releasePointer = () => {
    pointerHeld = false
  }
  onMount(() => {
    window.addEventListener("pointerup", releasePointer)
    window.addEventListener("pointercancel", releasePointer)
  })
  onCleanup(() => {
    window.removeEventListener("pointerup", releasePointer)
    window.removeEventListener("pointercancel", releasePointer)
  })

  const handleListKeyDown = (event: KeyboardEvent & { currentTarget: HTMLDivElement }) => {
    if (!active()) return
    const key = scrollKey(event)
    if (!key) return
    if (!isScrollKeyTarget(event.target, key)) return
    if (scrollKeyOwner(event.currentTarget, event.target, key) !== event.currentTarget) return
    finishRestoration()
    input.onUserScroll(event.currentTarget)
    if (upwardKeys.has(key)) input.onUnpin()
  }

  // Following resumes by arriving at the end, either by scrolling there or by content shrinking
  // under a viewport that was already there. Merely resting near the end is not enough, otherwise
  // a later scroll would overwrite an upward intent expressed a pixel short of the bottom.
  const handleListScroll = (event: Event & { currentTarget: HTMLDivElement }) => {
    if (!active()) return
    const root = event.currentTarget
    const previousTop = scrollTop
    const previousMaxScroll = maxScroll
    scrollTop = root.scrollTop
    maxScroll = root.scrollHeight - root.clientHeight
    const atEnd = maxScroll - scrollTop <= endEpsilon
    const arrived = scrollTop > previousTop + endEpsilon || maxScroll < previousMaxScroll
    const pin = !recovery.attempt && (maxScroll <= 1 || (atEnd && arrived))
    if (pin) input.onPin()
    if (!pin && (pointerHeld || touchScrolling) && scrollTop < previousTop - endEpsilon) input.onUnpin()
    settleColdBottom()
    input.onScheduleScrollState(root)
    if (!recovery.attempt) input.onHistoryScroll()
  }

  function View(props: ViewProps) {
    function VirtualRow(rowProps: { rowKey: string }) {
      let element: HTMLDivElement
      const initialItem = virtualItemByKey().get(rowProps.rowKey)!
      const initialRow = rowByKey().get(rowProps.rowKey)!
      const item = createMemo(() => virtualItemByKey().get(rowProps.rowKey) ?? initialItem)
      const row = createMemo(() => rowByKey().get(rowProps.rowKey) ?? rows()[item().index] ?? initialRow)
      const user = () => row()._tag === "UserMessage"
      const containingHeight = () => {
        if (!user()) return item().size
        // Reading total size subscribes to the virtualizer's measurement updates.
        const end = virtualizer.getTotalSize() - 64 + topOffset()
        const next = userRows().get(item().index)
        return Math.max(
          item().size,
          (next === undefined ? end : (virtualizer.measurementsCache[next]?.start ?? end)) - item().start,
        )
      }
      const [ready, setReady] = createSignal(initialItem.size <= fallbackItemSize || !props.deferred(initialRow))
      let contentMeasureFrame: number | undefined

      onMount(() => virtualizer.measureElement(element))
      // Prepending history changes data-index, not the keyed element's identity.
      // Its observer reads the current index and delivers any actual size change.
      onCleanup(() => {
        if (contentMeasureFrame !== undefined) cancelAnimationFrame(contentMeasureFrame)
        queueMicrotask(() => virtualizer.measureElement(null))
      })

      return (
        <div
          data-timeline-key={rowProps.rowKey}
          style={{
            position: "absolute",
            top: `${item().start - topOffset() - rendering.scrollAdjustment}px`,
            left: "0",
            width: "100%",
            height: `${containingHeight()}px`,
            overflow: user() ? "visible" : "clip",
            "pointer-events": user() ? "none" : undefined,
            "z-index": user() ? 20 : undefined,
            "overflow-clip-margin": row()._tag === "TurnGap" ? undefined : "0.5px",
          }}
        >
          <div
            ref={(value) => {
              element = value
              if (row()._tag !== "UserMessage" || !addedKeys.has(rowProps.rowKey) || !input.pinned() || coldPending)
                return
              // The optimistic row can paint before ResizeObserver corrects the tail estimates.
              // Measure the mounted tail and pin it in this render's microtask instead.
              queueMicrotask(() => {
                if (!active() || !input.pinned() || !virtualContent?.isConnected) return
                virtualizer.elementsCache.forEach((item) => {
                  if (item.isConnected) virtualizer.resizeItem(virtualizer.indexFromElement(item), item.offsetHeight)
                })
                virtualizer.resizeItem(item().index, element.offsetHeight)
                virtualContent.style.height = `${virtualizer.getTotalSize()}px`
                virtualizer.scrollToEnd()
              })
            }}
            data-index={item().index}
            data-sticky-user={user() ? "" : undefined}
            style={{
              "min-height": ready() ? undefined : `${initialItem.size}px`,
              position: user() ? "sticky" : undefined,
              top: user() ? (input.showHeader() ? "48px" : "0px") : undefined,
              "pointer-events": user() ? "auto" : undefined,
              background: user() ? "var(--v2-background-bg-base)" : undefined,
            }}
          >
            {props.renderRow(row, () => {
              setReady(true)
              if (contentMeasureFrame !== undefined) cancelAnimationFrame(contentMeasureFrame)
              contentMeasureFrame = requestAnimationFrame(() => {
                contentMeasureFrame = undefined
                if (active() && element.isConnected) virtualizer.measureElement(element)
              })
            })}
          </div>
        </div>
      )
    }

    return (
      <div
        class="relative w-full h-full min-w-0"
        data-workspace-session={props.workspaceSession() ? "" : undefined}
        data-local-session={!props.workspaceSession() ? "" : undefined}
      >
        <div
          class="absolute left-1/2 -translate-x-1/2 z-[60] pointer-events-none transition-all duration-200 ease-out"
          classList={{
            "bottom-8": true,
            "opacity-100 translate-y-0 scale-100": input.scroll().overflow && input.scroll().jump,
            "opacity-0 translate-y-2 pointer-events-none": !input.scroll().overflow || !input.scroll().jump,
            "scale-[0.8]": !input.scroll().overflow || !input.scroll().jump,
          }}
        >
          <button
            type="button"
            aria-label={language.t("session.messages.jumpToLatest")}
            class="pointer-events-auto flex items-center justify-center w-8 h-7 px-2 py-1.5 rounded-lg border-none cursor-pointer text-v2-text-text-base backdrop-blur-[2px]"
            style={{
              background: "color-mix(in srgb, var(--v2-background-bg-base) 92%, transparent)",
              "box-shadow": "var(--v2-elevation-raised), 0px 2px 8px var(--v2-background-bg-base)",
            }}
            onClick={input.onResumeScroll}
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <path
                d="M12.3333 8.66665L8 13L3.66667 8.66665M8 12.6667V2.83332"
                stroke="currentColor"
                stroke-linecap="square"
              />
            </svg>
          </button>
        </div>
        <ScrollView
          data-slot="session-timeline-scroll"
          viewportRef={bindListRoot}
          onBeforeScroll={prepareNavigation}
          verticalScrollAdjustment={rendering.scrollAdjustment}
          onWheel={handleListWheel}
          onTouchStart={handleListTouchStart}
          onPointerDown={handleListPointerDown}
          onKeyDown={handleListKeyDown}
          onScroll={handleListScroll}
          onClick={input.onSelectionInteraction}
          class="relative min-w-0 w-full h-full"
          style={{ "--sticky-accordion-top": input.showHeader() ? "48px" : "0px" }}
        >
          <Show when={input.showHeader()} fallback={<div aria-hidden="true" class="h-4 md:hidden" />}>
            {props.header}
          </Show>
          <div
            data-timeline-virtual-content
            ref={(element) => {
              virtualContent = element
              if (active()) input.setContentRef(element)
            }}
            style={{
              height: `${virtualizer.getTotalSize() - rendering.scrollAdjustment}px`,
              position: "relative",
              width: "100%",
              visibility: coldBottomMount ? "hidden" : undefined,
            }}
          >
            <For each={virtualRowKeys()}>{(rowKey) => <VirtualRow rowKey={rowKey} />}</For>
            <div
              data-timeline-row="bottom-spacer"
              class="h-16 absolute top-0 left-0 w-full"
              style={{ transform: `translateY(${virtualizer.getTotalSize() - 64 - rendering.scrollAdjustment}px)` }}
            >
              {props.bottomSpacer}
            </div>
          </div>
        </ScrollView>
      </div>
    )
  }

  onCleanup(() => {
    cache.delete(ownerSessionKey)
    cache.set(ownerSessionKey, {
      measurements: virtualizer.takeSnapshot(),
      toolOpen: { ...toolOpen },
      patchGroupKeys,
      presentationKey: input.presentationKey?.(),
    })
    while (cache.size > 16) cache.delete(cache.keys().next().value!)
    coldPending = false
    contentObserver?.disconnect()
    viewportObserver?.disconnect()
    if (active()) {
      input.setScrollRef(undefined)
      input.setRevealMessage?.(() => {})
      input.setScrollToEnd?.(() => {})
      input.setScrollToOffset?.(() => {})
    }
  })

  return {
    disclosure: {
      patchGroupKeys,
      value: (key: string) => toolOpen[key],
      set: (key: string, open: boolean) => setToolOpen(key, open),
    },
    View,
  }
}
