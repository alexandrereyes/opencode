import { batch, createEffect, onCleanup } from "solid-js"
import { createStore, produce, reconcile } from "solid-js/store"
import type { SessionNavigationInfo } from "@opencode/client/promise"
import type { ServerCtx } from "@/runtime/server/runtime"
import { loadNavigation } from "./sidebar-model"
import { sessionTreeIDs } from "@/session/requests/session-request-tree"
import { createRecentClock, createRecentOrder } from "./sidebar-order"

export function createSidebarIndex(
  ctx: {
    data: { session: Pick<ServerCtx["data"]["session"], "remember"> }
    sdk: {
      api: { session: Pick<ServerCtx["sdk"]["api"]["session"], "navigation" | "active"> }
      connection: Pick<ServerCtx["sdk"]["connection"], "status">
      event: Pick<ServerCtx["sdk"]["event"], "listen">
    }
  },
  clock = createRecentClock(),
) {
  const order = createRecentOrder(clock)
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
    const revisions = new Map<string, number>()
    const observed = new Set<string>()
    const work = { loading: true, timer: undefined as ReturnType<typeof setTimeout> | undefined }
    const invalidate = (id: string) => {
      revisions.set(id, (revisions.get(id) ?? 0) + 1)
      pending.add(id)
    }
    const refresh = () => {
      work.timer = undefined
      if (work.loading) return
      const ids = [...pending]
      pending.clear()
      void Promise.all(
        ids.map(async (sessionID) => {
          const revision = revisions.get(sessionID)
          const page = await ctx.sdk.api.session.navigation({ sessionID }, { signal: abort.signal })
          // An intervening event invalidates this read even before its replacement starts.
          if (abort.signal.aborted || revision !== revisions.get(sessionID)) return
          const row = page.data[0]
          if (row) {
            order.seed(row)
            setState("rows", sessionID, reconcile(row))
          }
          if (!row) order.remove(sessionID)
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
      if (
        event.type === "session.execution.started" ||
        event.type === "session.execution.succeeded" ||
        event.type === "session.execution.failed" ||
        event.type === "session.execution.interrupted"
      ) {
        if (work.loading) observed.add(event.data.sessionID)
        order.observe(event.data.sessionID, event.type === "session.execution.started")
      }
      if (event.type === "session.deleted" || event.type === "session.archived") {
        if (work.loading) observed.add(event.data.sessionID)
        order.remove(event.data.sessionID)
      }
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
          "session.execution.started",
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
      invalidate(id)
      // Causal undo changes descendant projections without a separate child revert event.
      if (event.type.startsWith("session.revert.")) {
        sessionTreeIDs(
          Object.values(state.rows).map((row) => row.session),
          id,
        ).forEach(invalidate)
      }
      if (work.timer === undefined) work.timer = setTimeout(refresh, 100)
    })
    setState({ loading: true, error: false })
    void Promise.all([
      loadNavigation(ctx.sdk.api.session.navigation, abort.signal),
      ctx.sdk.api.session.active({ signal: abort.signal }).then((active) => {
        // Establish phases before the slower navigation pages: a terminal arriving
        // between these responses must still observe the preceding active phase.
        return {
          active,
          promoted: abort.signal.aborted ? [] : order.activity(new Set(Object.keys(active)), observed),
        }
      }),
    ])
      .then(([rows, snapshot]) => {
        if (abort.signal.aborted) return
        batch(() => {
          order.snapshot(rows, new Set(Object.keys(snapshot.active)), observed, snapshot.promoted)
          setState("rows", reconcile(Object.fromEntries(rows.map((row) => [row.session.id, row]))))
          rows.forEach((row) => ctx.data.session.remember(row.session))
          setState("loading", false)
        })
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
  return { state, ranks: order.ranks, retry: () => setRequest("retry", (n) => n + 1) }
}
