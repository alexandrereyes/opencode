import { expect, mock, test } from "bun:test"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import type { PermissionRequest } from "@opencode/client/promise"
import type { Data } from "@opencode/client/solid"
import type { ServerSDK } from "@/runtime/server/client"

const [settings, setSettings] = createStore({ enabled: false })
mock.module("@/settings/model", () => ({
  useSettings: () => ({ permissions: { autoApprove: () => settings.enabled } }),
}))
const { createPermissionAutoApprover } = await import("@/session/requests/auto-approve")

test("sweeps unknown sessions, retries RPC failure, and preserves event/store approvals", async () => {
  const [state, set] = createStore({ epoch: 1, pending: [] as PermissionRequest[] })
  const replied: string[] = []
  const calls: string[] = []
  const listeners = new Set<(event: { data: PermissionRequest }) => void>()
  const finished = Promise.withResolvers<void>()
  const request = (id: string): PermissionRequest => ({
    id,
    sessionID: "unknown-idle-session",
    action: "shell",
    resources: [],
  })
  const sdk = {
    connection: { epoch: () => state.epoch },
    event: {
      on: (_: string, callback: (event: { data: PermissionRequest }) => void) => {
        listeners.add(callback)
        return () => listeners.delete(callback)
      },
    },
    api: {
      rpc: (definition: { id: string }) => ({
        permissions: async () => {
          calls.push(definition.id)
          if (calls.length === 1) throw new Error("temporary failure")
          return [request("rpc")]
        },
      }),
      permission: {
        reply: async (input: { requestID: string; decision: string }) => {
          expect(input.decision).toBe("once")
          replied.push(input.requestID)
          if (input.requestID === "rpc") finished.resolve()
        },
      },
    },
  } as ServerSDK
  const data = {
    session: {
      list: () => [{ id: "stale-session", location: { directory: "/deleted-worktree" } }],
      permission: { list: () => state.pending },
    },
  } as Data
  const dispose = createRoot((dispose) => {
    createPermissionAutoApprover({ sdk, data })
    return dispose
  })
  try {
    expect(calls).toEqual([])
    setSettings("enabled", true)
    await finished.promise
    expect(calls).toEqual(["custom.requests", "custom.requests"])
    expect(replied).toEqual(["rpc"])
    listeners.forEach((listener) => listener({ data: request("event") }))
    set("pending", [request("store"), request("rpc")])
    expect(replied).toEqual(["rpc", "event", "store"])
    setSettings("enabled", false)
    listeners.forEach((listener) => listener({ data: request("disabled") }))
    expect(replied).toEqual(["rpc", "event", "store"])
  } finally {
    dispose()
  }
  expect(listeners.size).toBe(0)
})
