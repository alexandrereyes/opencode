import { createEffect, on, onCleanup } from "solid-js"
import type { PermissionRequest } from "@opencode/client/promise"
import type { Data } from "@opencode/client/solid"
import { Requests } from "@opencode/plugin-app-custom/rpc"
import type { ServerSDK } from "@/runtime/server/client"
import { useSettings } from "@/settings/model"

const respondedLimit = 1000
const retryLimit = 2
const retryDelayMs = 1000

// Auto-approves permission requests on one server connection whenever the
// app-level auto-approve setting is on. The setting lives in the client-local
// settings store, so it applies to every session, tab, and server at once.
export function createPermissionAutoApprover(input: {
  sdk: ServerSDK
  data: Data
  pending?: () => PermissionRequest[]
}) {
  const enabled = useSettings().permissions.autoApprove
  const state = { disposed: false, generation: 0, responded: new Set<string>() }

  const unsubscribe = input.sdk.event.on("permission.asked", (event) => {
    if (enabled()) approve(event.data)
  })
  onCleanup(() => {
    state.disposed = true
    unsubscribe()
  })

  // Every physical event stream starts with server.connected. Its retained,
  // server-scoped epoch also covers consumers attached after the handshake.
  createEffect(
    on([enabled, input.sdk.connection.epoch], ([enabled, epoch]) => {
      if (!enabled || epoch === 0) return
      const generation = ++state.generation
      void sweepWithRetry(generation, 0)
    }),
  )

  // Approves pending requests that reach the local store, which is how a
  // previously unknown idle session's requests surface when its view opens
  // and syncs them. Store changes do not re-trigger the network sweep.
  createEffect(() => {
    if (!enabled()) return
    input.pending?.().forEach((request) => approve(request))
    for (const session of input.data.session.list()) {
      for (const request of input.data.session.permission.list(session.id) ?? []) approve(request)
    }
  })

  // An incomplete sweep leaves pending requests hidden with no later trigger
  // to recover them, so retry it a bounded number of times. A newer sweep
  // supersedes scheduled retries.
  async function sweepWithRetry(generation: number, attempt: number) {
    const complete = await sweep()
    if (complete || attempt >= retryLimit) return
    setTimeout(
      () => {
        if (state.disposed || !enabled() || generation !== state.generation) return
        void sweepWithRetry(generation, attempt + 1)
      },
      retryDelayMs * (attempt + 1),
    )
  }

  async function sweep() {
    return input.sdk.api
      .rpc(Requests.Definition)
      .permissions({})
      .then((pending) => {
        if (!state.disposed) pending.forEach((request) => approve(request))
        return true
      })
      .catch(() => false)
  }

  function approve(permission: Pick<PermissionRequest, "id" | "sessionID">, attempt = 0) {
    // enabled() guards the retry timer path: the user may disable the setting
    // between a failed reply and its scheduled retry.
    if (state.disposed || !enabled() || state.responded.has(permission.id)) return
    remember(permission.id)
    input.sdk.api.permission
      .reply({ sessionID: permission.sessionID, requestID: permission.id, decision: "once" })
      .catch(() => {
        // A reply failure leaves the request pending but invisible (the UI
        // hides prompts while auto-approve is on), so retry a bounded number
        // of times. Later sweeps retry it after that.
        state.responded.delete(permission.id)
        if (state.disposed || attempt >= retryLimit) return
        setTimeout(() => approve(permission, attempt + 1), retryDelayMs * (attempt + 1))
      })
  }

  function remember(id: string) {
    state.responded.add(id)
    for (const oldest of state.responded) {
      if (state.responded.size <= respondedLimit) break
      state.responded.delete(oldest)
    }
  }
}
