import { createEffect, createMemo, on, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import { SUBAGENT_PAGE_SIZE, type SubagentInfo } from "@/session/family"

export function createSubagentList(input: {
  sessionID: () => string | undefined
  active: () => boolean
  version: (id: string) => number | undefined
  page: (
    id: string,
    after: string | undefined,
    signal: AbortSignal,
  ) => Promise<{ data: SubagentInfo[]; next?: string } | undefined>
}) {
  const [state, setState] = createStore({
    owner: input.sessionID(),
    open: true,
    subagentLimit: SUBAGENT_PAGE_SIZE,
    children: [] as SubagentInfo[],
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
    // Invalidated rows refresh in place to the depth already shown, without a visible reload.
    const depth = more ? state.children.length + 1 : Math.max(state.children.length, 1)
    setState({ loading: !state.loaded || more, failed: false })
    const children = more ? [...state.children] : []
    const walk = async (after: string | undefined): Promise<string | undefined> => {
      const page = await input.page(request.id, after, request.signal)
      if (!page || request.signal.aborted) return
      children.push(...page.data)
      if (!page.next || children.length >= depth) return page.next
      return walk(page.next)
    }
    await walk(more ? state.next : undefined)
      .then((next) => {
        if (request.signal.aborted) return
        setState({
          children,
          next,
          loaded: true,
          subagentLimit: more ? state.subagentLimit + SUBAGENT_PAGE_SIZE : state.subagentLimit,
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
