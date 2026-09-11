import { createEffect, onCleanup } from "solid-js"
import { createStore, produce, reconcile } from "solid-js/store"
import type { SessionNavigationInfo } from "@opencode/client/promise"
import type { ServerCtx } from "@/runtime/server/runtime"
import { loadNavigation } from "./sidebar-model"
import { sessionTreeIDs } from "@/session/requests/session-request-tree"

export function createSidebarIndex(ctx: {
  data: { session: Pick<ServerCtx["data"]["session"], "remember"> }
  sdk: {
    api: Pick<ServerCtx["sdk"]["api"], "session">
    connection: Pick<ServerCtx["sdk"]["connection"], "status">
    event: Pick<ServerCtx["sdk"]["event"], "listen">
  }
}) {
  const [state, setState] = createStore({
    rows: {} as Record<string, SessionNavigationInfo>,
    loading: true,
    error: false,
  })
  const [request, setRequest] = createStore({ retry: 0 })
  createEffect(() => {
    request.retry
    if (ctx.sdk.connection.status() !== "connected") return
    const abort = new AbortController()
    const pending = new Set<string>()
    const work = { loading: true, timer: undefined as ReturnType<typeof setTimeout> | undefined }
    const refresh = () => {
      work.timer = undefined
      if (work.loading) return
      const ids = [...pending]
      pending.clear()
      void Promise.all(
        ids.map(async (sessionID) => {
          const page = await ctx.sdk.api.session.navigation({ sessionID }, { signal: abort.signal })
          if (abort.signal.aborted) return
          const row = page.data[0]
          if (row) setState("rows", sessionID, reconcile(row))
          if (!row)
            setState(
              "rows",
              produce((rows) => {
                delete rows[sessionID]
              }),
            )
          if (row) ctx.data.session.remember(row.session)
        }),
      ).catch(() => {
        if (!abort.signal.aborted) setState("error", true)
      })
    }
    const unsubscribe = ctx.sdk.event.listen((event) => {
      // Content deltas do not change the creation clock. Refresh only facts relevant to navigation.
      if (
        ![
          "session.created",
          "session.deleted",
          "session.archived",
          "session.renamed",
          "session.moved",
          "session.viewed",
          "session.inbox.delivered",
          "session.step.started",
          "session.step.ended",
          "session.execution.succeeded",
          "session.execution.failed",
          "session.execution.interrupted",
          "session.forked",
          "session.revert.committed",
          "session.revert.staged",
          "session.revert.cleared",
          "permission.asked",
          "permission.replied",
          "form.created",
          "form.replied",
          "form.cancelled",
        ].includes(event.type)
      )
        return
      const id =
        "sessionID" in event.data ? event.data.sessionID : "form" in event.data ? event.data.form.sessionID : undefined
      if (typeof id !== "string" || id === "global") return
      pending.add(id)
      // Causal undo changes descendant projections without a separate child revert event.
      if (event.type.startsWith("session.revert.")) {
        sessionTreeIDs(
          Object.values(state.rows).map((row) => row.session),
          id,
        ).forEach((id) => pending.add(id))
      }
      if (work.timer === undefined) work.timer = setTimeout(refresh, 100)
    })
    setState({ loading: true, error: false })
    void loadNavigation(ctx.sdk.api.session.navigation, abort.signal)
      .then((rows) => {
        if (abort.signal.aborted) return
        setState("rows", reconcile(Object.fromEntries(rows.map((row) => [row.session.id, row]))))
        rows.forEach((row) => ctx.data.session.remember(row.session))
        setState("loading", false)
        work.loading = false
        refresh()
      })
      .catch(() => {
        if (!abort.signal.aborted) setState({ loading: false, error: true })
      })
    onCleanup(() => {
      abort.abort()
      unsubscribe()
      clearTimeout(work.timer)
    })
  })
  return { state, retry: () => setRequest("retry", (n) => n + 1) }
}
