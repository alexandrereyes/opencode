import type { OpenCodeClient } from "@opencode/client/promise"
import { Updates } from "./rpc.js"

export async function waitForRelease(client: OpenCodeClient, version: string, signal: AbortSignal) {
  while (!signal.aborted) {
    const health = await client.health
      .get({ signal: AbortSignal.any([signal, AbortSignal.timeout(3_000)]) })
      .catch(() => undefined)
    if (health?.healthy && health.version === version) return
    await new Promise<void>((resolve) => {
      const done = () => {
        clearTimeout(timer)
        signal.removeEventListener("abort", done)
        resolve()
      }
      const timer = setTimeout(done, 500)
      signal.addEventListener("abort", done, { once: true })
    })
  }
  throw new Error(
    "The selected release has not become healthy. Inspect the launchd service logs; no rollback was attempted.",
  )
}

export function updateClient(client: OpenCodeClient) {
  const rpc = client.rpc(Updates.Definition)
  return {
    check: (signal?: AbortSignal) => rpc.check({}, { signal }),
    install: async (target: Updates.Target) => {
      await rpc.install(target)
      await waitForRelease(client, target.version, AbortSignal.timeout(120_000))
    },
  }
}
