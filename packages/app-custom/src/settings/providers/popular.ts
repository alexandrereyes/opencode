import type { IntegrationInfo } from "@opencode/client/promise"
import { popularProviders } from "@/providers/catalog/order"

export function popularConnections<T extends { id: string }>(
  providers: T[],
  connected: ReadonlySet<string>,
  console: IntegrationInfo | undefined,
) {
  return providers
    .filter((provider) => {
      // A Zen key is not a Console account, even though both use the same integration ID.
      if (provider.id !== "opencode" || !console) return !connected.has(provider.id)
      return console.connections.find((connection) => connection.type === "credential")?.method !== "oauth"
    })
    .toSorted((a, b) => popularProviders.indexOf(a.id) - popularProviders.indexOf(b.id))
}
