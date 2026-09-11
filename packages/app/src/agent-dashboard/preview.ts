import { createEffect, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import type { ServerSDK } from "@/runtime/server/client"
import { dashboardPreview, PREVIEW_LIMIT } from "./model"

// Shared by the cards in one dashboard, not by the session timeline cache.
export function createPreviewQueue() {
  const tasks: (() => Promise<void>)[] = []
  let active = 0
  const drain = () => {
    const task = active < 4 ? tasks.shift() : undefined
    if (!task) return
    active++
    void task().finally(() => {
      active--
      drain()
    })
    drain()
  }
  return (task: () => Promise<void>) => {
    tasks.push(task)
    drain()
  }
}

export function createDashboardPreview(input: {
  sdk: {
    connection: Pick<ServerSDK["connection"], "status">
    event: Pick<ServerSDK["event"], "listen">
    api: Pick<ServerSDK["api"], "message">
  }
  sessionID: string
  visible: () => boolean
  enqueue: ReturnType<typeof createPreviewQueue>
}) {
  const [state, setState] = createStore({
    text: "",
    tool: undefined as string | undefined,
    loading: true,
    error: false,
  })
  createEffect(() => {
    if (!input.visible() || input.sdk.connection.status() !== "connected") return
    const abort = new AbortController()
    const work = { revision: 0, queued: false, timer: undefined as ReturnType<typeof setTimeout> | undefined }
    const load = () => {
      work.timer = undefined
      if (work.queued) return
      work.queued = true
      input.enqueue(async () => {
        work.queued = false
        if (abort.signal.aborted) return
        const revision = work.revision
        await input.sdk.api.message
          .list({ sessionID: input.sessionID, limit: 3, order: "desc" }, { signal: abort.signal })
          .then((page) => {
            if (abort.signal.aborted || revision !== work.revision) return
            setState({ ...dashboardPreview(page.data), loading: false, error: false })
          })
          .catch(() => {
            if (!abort.signal.aborted && revision === work.revision) setState({ loading: false, error: true })
          })
      })
    }
    const refresh = () => {
      if (work.timer === undefined) work.timer = setTimeout(load, 250)
    }
    const unsubscribe = input.sdk.event.listen((event) => {
      if (!("sessionID" in event.data) || event.data.sessionID !== input.sessionID) return
      switch (event.type) {
        case "session.text.started":
          work.revision++
          setState({ text: "", loading: false, error: false })
          return
        case "session.text.delta":
          work.revision++
          setState("text", (text) => (text + event.data.delta).slice(0, PREVIEW_LIMIT))
          return
        case "session.text.ended":
          work.revision++
          setState({ text: event.data.text.slice(0, PREVIEW_LIMIT), loading: false, error: false })
          return
        case "session.tool.input.started":
          work.revision++
          setState("tool", event.data.name)
          return
        case "session.tool.success":
        case "session.tool.failed":
        case "session.step.ended":
        case "session.inbox.delivered":
        case "session.revert.committed":
          work.revision++
          refresh()
          return
        case "session.execution.succeeded":
        case "session.execution.failed":
        case "session.execution.interrupted":
          work.revision++
          setState("tool", undefined)
          refresh()
      }
    })
    load()
    onCleanup(() => {
      abort.abort()
      unsubscribe()
      clearTimeout(work.timer)
    })
  })
  return state
}
