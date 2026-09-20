import { createMemo } from "solid-js"
import { createStore } from "solid-js/store"
import type { Mcp } from "@opencode/schema/mcp"
import { useMcpToggle, type McpControls } from "@/providers/connect/mcp"
import { useLanguage } from "@/runtime/i18n/language"
import { useServerSDK } from "@/runtime/server/client"
import { useServer } from "@/runtime/server/current"
import { useTabs } from "@/shell/tabs/tabs"
import { showToast } from "@/shell/notifications/toast"
import { useWorkspaceLocation } from "@/workspaces/location"

type McpServer = Pick<Mcp.Server, "name" | "status">

export async function applyDraftMcpStates(input: {
  pending?: Promise<boolean>
  states: Readonly<Record<string, boolean>>
  list: () => Promise<readonly McpServer[]>
  change: (name: string, enabled: boolean) => Promise<boolean>
}) {
  if (input.pending && !(await input.pending)) return { ready: false as const }
  const entries = Object.entries(input.states)
  if (entries.length === 0) return { ready: true as const }
  const catalog = await input.list()
  const missing = entries.find(([name, enabled]) => enabled && !catalog.some((server) => server.name === name))
  if (missing) return { ready: false as const, issue: "unavailable" as const, name: missing[0] }
  const results = await Promise.all(
    entries
      .filter(([name, enabled]) => {
        const server = catalog.find((item) => item.name === name)
        return server && (enabled ? server.status.status !== "connected" : server.status.status !== "disabled")
      })
      .map(([name, enabled]) => input.change(name, enabled)),
  )
  if (results.some((success) => !success)) return { ready: false as const }
  const current = await input.list()
  const unresolved = entries.find(([name, enabled]) => {
    const status = current.find((server) => server.name === name)?.status.status
    return enabled ? status !== "connected" : status !== undefined && status !== "disabled"
  })
  if (!unresolved) return { ready: true as const }
  return {
    ready: false as const,
    issue: current.find((server) => server.name === unresolved[0])?.status.status === "needs_auth"
      ? ("needs_auth" as const)
      : ("not_ready" as const),
    name: unresolved[0],
  }
}

export function createDraftMcpControls(input: { draftID: string; worktree: () => string }) {
  const tabs = useTabs()
  const location = useWorkspaceLocation()
  const server = useServer()
  const sdk = useServerSDK()
  const language = useLanguage()
  const [store, setStore] = createStore<{
    preparing: boolean
    pending: Record<string, Promise<boolean> | undefined>
  }>({ preparing: false, pending: {} })
  const key = (worktree: string) => JSON.stringify([server.key, location().directory, worktree])
  const target = createMemo(() => key(input.worktree()))
  const preview = () => input.worktree() === "create"
  const directory = createMemo(() => {
    const selected = input.worktree()
    return selected === "main" || selected === "create" ? location().directory : selected
  })
  const states = createMemo(() => {
    const draft = tabs.store.find((tab) => tab.type === "draft" && tab.draftID === input.draftID)
    return draft?.type === "draft" && draft.mcp?.target === target() ? draft.mcp.states : {}
  })
  const toggle = useMcpToggle(directory)
  const controls: McpControls = {
    get preview() {
      return preview()
    },
    get states() {
      return states()
    },
    get pending() {
      return store.preparing || (!preview() && store.pending[directory()] !== undefined)
    },
    change(name, enabled) {
      if (controls.pending) return
      tabs.updateDraft(input.draftID, { mcp: { target: target(), states: { ...states(), [name]: enabled } } })
      if (preview()) return
      const current = directory()
      const request = toggle.mutateAsync({ name, enabled, directory: current }).then(
        () => true,
        () => false,
      )
      setStore("pending", current, request)
      void request.finally(() => setStore("pending", current, undefined))
    },
  }

  return {
    controls,
    directory,
    capture: () => ({ ...states() }),
    remember(directory: string, states: Readonly<Record<string, boolean>>) {
      tabs.updateDraft(input.draftID, { mcp: { target: key(directory), states: { ...states } } })
    },
    async prepare(directory: string, states: Readonly<Record<string, boolean>>) {
      if (!store.pending[directory] && !Object.keys(states).length) return true
      setStore("preparing", true)
      return applyDraftMcpStates({
        pending: store.pending[directory],
        states,
        list: () => sdk.api.mcp.list({ location: { directory } }).then((result) => result.data),
        change: (name, enabled) =>
          toggle.mutateAsync({ name, enabled, directory }).then(
            () => true,
            () => false,
          ),
      })
        .then((result) => {
          if (result.ready) return true
          if (!result.issue) return false
          const key =
            result.issue === "unavailable"
              ? "session.summary.mcp.unavailable"
              : result.issue === "needs_auth"
                ? "session.summary.mcp.signInBeforeSend"
                : "session.summary.mcp.notReady"
          throw new Error(language.t(key, { name: result.name }))
        })
        .catch((error) => {
          showToast({
            variant: "error",
            title: language.t("session.summary.mcp.prepareFailed"),
            description: error instanceof Error ? error.message : String(error),
          })
          return false
        })
        .finally(() => setStore("preparing", false))
    },
  }
}

export type DraftMcpControls = ReturnType<typeof createDraftMcpControls>
