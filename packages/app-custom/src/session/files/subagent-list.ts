import { createEffect, createMemo, on, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import type { SessionInfo } from "@opencode/client/promise"
import { SUBAGENT_PAGE_SIZE } from "@/session/family"

export function createSubagentList(input: {
  sessionID: () => string | undefined
  active: () => boolean
  version: (id: string) => number | undefined
  page: (
    id: string,
    after: string | undefined,
    signal: AbortSignal,
  ) => Promise<{ data: SessionInfo[]; next?: string } | undefined>
}) {
  const [state, setState] = createStore({
    owner: input.sessionID(),
    open: false,
    subagentLimit: SUBAGENT_PAGE_SIZE,
    children: [] as SessionInfo[],
    next: undefined as string | undefined,
    loaded: false,
    loading: false,
    failed: false,
  })
  const demand = createMemo(() => {
    const id = input.sessionID()
    if (!input.active() || !state.open || !id || state.owner !== id) return
    const version = input.version(id)
    const controller = new AbortController()
    onCleanup(() => controller.abort())
    return { id, version, signal: controller.signal }
  })
  const load = async (more = false) => {
    const request = demand()
    if (!request || state.loading) return
    setState({ loading: true, failed: false })
    const after = more ? state.next : undefined
    await input
      .page(request.id, after, request.signal)
      .then((page) => {
        if (!page || request.signal.aborted) return
        setState({
          children: more ? [...state.children, ...page.data] : page.data,
          next: page.next,
          loaded: true,
          subagentLimit: more ? state.subagentLimit + SUBAGENT_PAGE_SIZE : SUBAGENT_PAGE_SIZE,
        })
      })
      .catch(() => {
        if (!request.signal.aborted) setState("failed", true)
      })
      .finally(() => {
        if (request === demand()) setState("loading", false)
      })
  }
  createEffect(
    on(demand, (request) => {
      setState("loading", false)
      if (request) void load()
    }),
  )
  createEffect(
    on(
      () => input.sessionID(),
      () =>
        setState({
          owner: input.sessionID(),
          open: false,
          children: [],
          next: undefined,
          loaded: false,
          failed: false,
          subagentLimit: SUBAGENT_PAGE_SIZE,
        }),
      { defer: true },
    ),
  )
  return { state, setState, load }
}
