import { createResource, onCleanup } from "solid-js"
import { Snippets } from "@opencode/plugin-app-custom/snippets/rpc"
import type { ServerSDK } from "@/runtime/server/client"

type SnippetServer = {
  readonly api: ServerSDK["api"]
  readonly connection: Pick<ServerSDK["connection"], "status" | "epoch">
}

export function createServerSnippets(sdk: SnippetServer) {
  const client = sdk.api.rpc(Snippets.Definition)
  const [items, actions] = createResource(
    () => (sdk.connection.status() === "connected" ? `connected:${sdk.connection.epoch()}` : false),
    () => client.list({}).then((result) => result.items),
  )
  const refresh = () => Promise.resolve(actions.refetch()).catch(() => undefined)
  onCleanup(client.events.on("updated", () => refresh().then(() => undefined)))
  return {
    list: () => (items.error ? [] : (items.latest ?? [])),
    loading: () => items.loading,
    error: () => items.error,
    ready: () => sdk.connection.status() === "connected" && items.state === "ready",
    refresh,
    async save(snippet: Snippets.Info) {
      await client.save(snippet)
      await refresh()
    },
    async remove(id: string) {
      await client.remove({ id })
      await refresh()
    },
  }
}

export type ServerSnippets = ReturnType<typeof createServerSnippets>
