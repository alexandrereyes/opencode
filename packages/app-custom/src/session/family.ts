import { batch, createEffect, onCleanup, untrack } from "solid-js"
import { createStore, reconcile } from "solid-js/store"
import { Family } from "@opencode/plugin-app-custom/session-family/rpc"
import type { FormInfo, PermissionRequest, SessionInfo } from "@opencode/client/promise"
import type { ServerSDK } from "@/runtime/server/client"

export const SUBAGENT_PAGE_SIZE = 10

type Snapshot = {
  count: number
  cost: number
  active: SessionInfo[]
  forms: FormInfo[]
  permissions: PermissionRequest[]
}
/** Latest measured assistant context, read with the page instead of each child's transcript. */
export type MeasuredContext = { id: string; tokens: SessionInfo["tokens"]; model: NonNullable<SessionInfo["model"]> }
export type SubagentInfo = SessionInfo & { context?: MeasuredContext }
type Page = { data: SubagentInfo[]; next?: string }
type Entry = { snapshot?: Snapshot; failed: boolean; version: number }

export function createSessionFamilies(input: {
  sdk: {
    api: Pick<ServerSDK["api"], "rpc">
    event: Pick<ServerSDK["event"], "listen">
    connection: Pick<ServerSDK["connection"], "status" | "epoch">
  }
  remember: (session: SessionInfo) => void
  status: (id: string, status: "running" | "idle") => void
}) {
  const [state, setState] = createStore<Record<string, Entry>>({})
  const cache = new Map<
    string,
    {
      users: number
      dirty: boolean
      revision: number
      failures: number
      pageRevision: number
      pagesDirty: boolean
      request?: AbortController
      timer?: ReturnType<typeof setTimeout>
      pages: Map<string, Page>
    }
  >()
  const entry = (id: string) => {
    const existing = cache.get(id)
    if (existing) return existing
    const value = {
      users: 0,
      dirty: true,
      revision: 0,
      failures: 0,
      pageRevision: 0,
      pagesDirty: false,
      pages: new Map<string, Page>(),
    }
    cache.set(id, value)
    setState(id, { failed: false, version: 0 })
    return cache.get(id)!
  }
  const refresh = async (id: string) => {
    const work = entry(id)
    work.timer = undefined
    if (!work.users || !work.dirty || work.request || input.sdk.connection.status() !== "connected") return
    if (work.pagesDirty) {
      work.pagesDirty = false
      setState(id, "version", (version) => version + 1)
    }
    const abort = new AbortController()
    const revision = work.revision
    work.request = abort
    await input.sdk.api
      .rpc(Family.Definition)
      .snapshot({ sessionID: id }, { signal: abort.signal })
      .then((result) => {
        if (abort.signal.aborted || revision !== work.revision) return
        // RPC JSON becomes mutable client state at this boundary.
        // oxlint-disable-next-line typescript-eslint/no-unsafe-type-assertion
        const snapshot = result as Snapshot
        batch(() => {
          const active = new Set(snapshot.active.map((session) => session.id))
          state[id]?.snapshot?.active.forEach((session) => {
            if (!active.has(session.id)) input.status(session.id, "idle")
          })
          snapshot.active.forEach((session) => {
            input.remember(session)
            input.status(session.id, "running")
          })
          setState(id, "snapshot", reconcile(snapshot))
          setState(id, "failed", false)
        })
        work.dirty = false
        work.failures = 0
      })
      .catch(() => {
        if (!abort.signal.aborted) {
          setState(id, "failed", true)
          work.failures++
          if (work.failures <= 3) schedule(id, 1000 * work.failures)
        }
      })
      .finally(() => {
        if (work.request === abort) work.request = undefined
        if (!abort.signal.aborted && revision !== work.revision) schedule(id)
      })
  }
  const schedule = (id: string, delay = 150) => {
    const work = entry(id)
    if (work.users && !work.timer) work.timer = setTimeout(() => void refresh(id), delay)
  }
  onCleanup(
    input.sdk.event.listen((event) => {
      const settledForm = event.type === "form.replied" || event.type === "form.cancelled" ? event.data.id : undefined
      const settledPermission = event.type === "permission.replied" ? event.data.requestID : undefined
      const topology = event.type === "session.created" || event.type === "session.deleted"
      // Page rows carry measured context, so a listed member's step or revert changes page data.
      const measured =
        event.type === "session.step.ended" ||
        (event.type === "session.step.failed" && event.data.tokens) ||
        event.type === "session.revert.committed"
          ? event.data.sessionID
          : undefined
      const relevant =
        topology ||
        measured ||
        settledForm ||
        settledPermission ||
        event.type === "form.created" ||
        event.type === "permission.asked" ||
        event.type === "session.execution.started" ||
        event.type === "session.execution.succeeded" ||
        event.type === "session.execution.failed" ||
        event.type === "session.execution.interrupted"
      if (!relevant) return
      cache.forEach((work, id) => {
        work.dirty = true
        work.revision++
        // Remove resolved prompts immediately; invalidate in-flight snapshots before they can restore them.
        if (settledForm && state[id]?.snapshot)
          setState(id, "snapshot", "forms", (forms) => forms.filter((form) => form.id !== settledForm))
        if (settledPermission && state[id]?.snapshot)
          setState(id, "snapshot", "permissions", (permissions) =>
            permissions.filter((request) => request.id !== settledPermission),
          )
        const listed =
          measured !== undefined &&
          [...work.pages.values()].some((page) => page.data.some((session) => session.id === measured))
        if (topology || listed) {
          work.pages.clear()
          work.pageRevision++
          work.pagesDirty = true
        }
        schedule(id)
      })
    }),
  )
  createEffect(() => {
    input.sdk.connection.epoch()
    const connected = input.sdk.connection.status() === "connected"
    cache.forEach((work, id) => {
      work.request?.abort()
      work.request = undefined
      work.dirty = true
      work.revision++
      work.pages.clear()
      work.pageRevision++
      setState(id, "version", (version) => version + 1)
      if (connected) schedule(id, 0)
    })
  })
  onCleanup(() =>
    cache.forEach((work) => {
      work.request?.abort()
      clearTimeout(work.timer)
    }),
  )
  return {
    watch(sessionID: () => string | undefined) {
      createEffect(() => {
        const id = sessionID()
        if (!id) return
        const work = untrack(() => entry(id))
        work.users++
        schedule(id, 0)
        onCleanup(() => {
          work.users--
          if (work.users) return
          work.request?.abort()
          work.request = undefined
          clearTimeout(work.timer)
          work.timer = undefined
        })
      })
    },
    retry(id: string) {
      const work = entry(id)
      work.failures = 0
      work.dirty = true
      clearTimeout(work.timer)
      work.timer = undefined
      schedule(id, 0)
    },
    permissions: () => Object.values(state).flatMap((entry) => entry.snapshot?.permissions ?? []),
    get: (id: string | undefined) => (id ? state[id] : undefined),
    async page(id: string, after: string | undefined, signal: AbortSignal) {
      const work = entry(id)
      const cached = work.pages.get(after ?? "")
      if (cached) return cached
      const version = work.pageRevision
      const result = await input.sdk.api
        .rpc(Family.Definition)
        .page({ sessionID: id, after, limit: SUBAGENT_PAGE_SIZE }, { signal })
      if (signal.aborted || version !== work.pageRevision) return
      // oxlint-disable-next-line typescript-eslint/no-unsafe-type-assertion
      const page = result as Page
      work.pages.set(after ?? "", page)
      // The optional context field is inert in the session cache; consumers read SessionInfo fields only.
      page.data.forEach(input.remember)
      return page
    },
  }
}
