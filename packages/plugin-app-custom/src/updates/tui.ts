import { OpenCode } from "@opencode/client/promise"
import type { Endpoint } from "@opencode/client/service"
import { updateClient } from "./client.js"
import { Updates } from "./rpc.js"

/** Loaded only by the explicit custom TUI launcher; never replaces another host's updater. */
export function createUpdater(input: { endpoint: Endpoint }) {
  const client = updateClient(
    OpenCode.make({
      baseUrl: input.endpoint.url,
      headers: input.endpoint.auth
        ? { authorization: `Basic ${btoa(`${input.endpoint.auth.username}:${input.endpoint.auth.password}`)}` }
        : undefined,
    }),
  )
  let prepared: Updates.Target | undefined
  return {
    remote: false,
    async subscribe(notify: (notice: { type: "available"; version: string }) => void, signal: AbortSignal) {
      const state = await client.check(signal)
      if (state.status !== "ready") return
      prepared = { commit: state.commit, version: state.version }
      notify({ type: "available", version: state.version })
    },
    async check(signal: AbortSignal) {
      const state = await client.check(signal)
      if (state.status === "disabled")
        return { type: "unavailable" as const, message: "This server does not have a custom release installation." }
      if (state.status === "installing")
        return {
          type: "unavailable" as const,
          message: "A release was selected. Wait for the launchd service to restart.",
        }
      if (state.status !== "ready") return
      prepared = { commit: state.commit, version: state.version }
      return { type: "available" as const, version: state.version }
    },
    async apply(version: string) {
      if (!prepared || prepared.version !== version) throw new Error("Check for updates again before confirming")
      await client.install(prepared)
    },
  }
}
