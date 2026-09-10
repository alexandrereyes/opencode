import { createResource, onCleanup } from "solid-js"
import type { SnippetInfo } from "@opencode/client/promise"
import type { ServerSDK } from "@/runtime/server/client"

export function createServerSnippets(sdk: ServerSDK) {
  const [items, actions] = createResource(
    () => sdk.connection.status() === "connected",
    () => sdk.api.snippet.list(),
  )
  const refresh = () => Promise.resolve(actions.refetch()).catch(() => undefined)
  onCleanup(sdk.event.on("snippet.updated", refresh))
  return {
    list: () => (items.error ? [] : (items.latest ?? [])),
    loading: () => items.loading,
    error: () => items.error,
    ready: () => sdk.connection.status() === "connected" && items.state === "ready",
    refresh,
    async save(snippet: SnippetInfo) {
      await sdk.api.snippet.save(snippet)
      await refresh()
    },
    async remove(id: string) {
      await sdk.api.snippet.remove({ id })
      await refresh()
    },
  }
}

export type ServerSnippets = ReturnType<typeof createServerSnippets>
