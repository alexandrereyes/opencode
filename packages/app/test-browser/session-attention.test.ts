import { expect, test } from "bun:test"
import { createEffect, createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import { createData, type CreateDataInput } from "@opencode/client/solid"
import { OpenCode, type OpenCodeEvent } from "@opencode/client/promise"
import { sessionAttention } from "@/shell/notifications/session-attention"
import { createSidebarIndex } from "@/shell/titlebar/sidebar-index"
import { attentionGroups, projectKey, rootSessions, sessionKey } from "@/shell/titlebar/sidebar-model"
import { ServerConnection } from "@/runtime/server/registry"
import type { SessionNavigationInfo } from "@/shell/titlebar/sidebar-model"

for (const kind of ["question", "permission"] as const) {
  test(`${kind}: partial SSE and reconnect cannot override authoritative navigation requests`, async () => {
    const sessionID = "ses_partial"
    const server = ServerConnection.Key.make("http://opencode.local")
    const field = kind === "question" ? "questionAt" : "permissionAt"
    const snapshot: SessionNavigationInfo = {
      session: {
        id: sessionID,
        projectID: "repo",
        location: { directory: "/repo" },
        time: { created: 1, updated: 1 },
        cost: 0,
        tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
      },
      [field]: 10,
    }
    const requests: string[] = []
    const api = OpenCode.make({
      baseUrl: server,
      fetch: async (input, init) => {
        const request = input instanceof Request ? input : new Request(input, init)
        const path = new URL(request.url).pathname
        requests.push(path)
        if (path === "/api/session/active") return Response.json({ data: {} })
        if (path !== "/api/rpc/custom.navigation/list") throw new Error(`Unexpected request: ${path}`)
        return Response.json({ output: { data: [snapshot] } })
      },
    })
    const listeners = new Set<Parameters<CreateDataInput["event"]["listen"]>[0]>()
    const navigationListeners = new Set<(event: OpenCodeEvent) => void>()
    const [connection, setConnection] = createStore<{ status: "connected" | "reconnecting" }>({ status: "connected" })
    const status = { status: () => connection.status }
    const setup = createRoot((dispose) => {
      const data = createData({
        api: () => api,
        directory: "/repo",
        connection: status,
        event: {
          on: () => () => {},
          listen: (listener) => {
            listeners.add(listener)
            return () => listeners.delete(listener)
          },
        },
      })
      const index = createSidebarIndex({
        data,
        sdk: {
          api,
          connection: status,
          event: {
            listen: (listener) => {
              navigationListeners.add(listener)
              return () => navigationListeners.delete(listener)
            },
          },
        },
      })
      return { data, index, dispose }
    })
    const emit = (event: OpenCodeEvent) => {
      listeners.forEach((listener) => listener({ name: event.type, details: event }))
      navigationListeners.forEach((listener) => listener(event))
    }
    const created = (id: string, time: number) =>
      emit(
        kind === "question"
          ? {
              id: `evt_created_${id}`,
              created: time,
              type: "form.created",
              location: { directory: "/repo" },
              data: {
                form: {
                  id: `frm_${id}`,
                  sessionID,
                  title: id,
                  created: time,
                  metadata: { kind: "question" },
                  fields: [{ key: "answer", type: "string" }],
                },
              },
            }
          : {
              id: `evt_asked_${id}`,
              created: time,
              type: "permission.asked",
              location: { directory: "/repo" },
              data: { id: `per_${id}`, sessionID, created: time, action: "shell", resources: [] },
            },
      )
    const cache = () =>
      kind === "question" ? setup.data.session.form.list(sessionID) : setup.data.session.permission.list(sessionID)
    const row = () => setup.index.state.rows[sessionID]
    const attention = () => sessionAttention({ ...row(), notifications: [] })
    const priority = () =>
      attentionGroups(
        rootSessions([
          {
            ...row(),
            ...attention(),
            server,
            key: sessionKey(server, sessionID),
            project: projectKey(server, { id: "repo", worktree: "/repo" }),
          },
        ]).rows,
        Date.now(),
      ).priority.map((row) => row.session.id)
    try {
      await until(() => !setup.index.state.loading)
      expect(cache()).toBeUndefined()
      expect(attention().attention).toBe(10)
      snapshot[field] = 20
      created("B", 20)
      expect(cache()?.map((request) => request.id)).toEqual([kind === "question" ? "frm_B" : "per_B"])
      await until(() => row()[field] === 20)
      expect(attention().attention).toBe(20)
      snapshot[field] = 10
      emit(
        kind === "question"
          ? {
              id: "evt_resolved",
              created: 30,
              type: "form.replied",
              location: { directory: "/repo" },
              data: { id: "frm_B", sessionID, answer: { answer: "done" } },
            }
          : {
              id: "evt_resolved",
              created: 30,
              type: "permission.replied",
              location: { directory: "/repo" },
              data: { requestID: "per_B", sessionID, reply: "once" },
            },
      )
      expect(cache()).toEqual([])
      await until(() => row()[field] === 10)
      expect(attention().attention).toBe(10)
      expect(priority()).toEqual([sessionID])

      // A is now observed through SSE. Its resolution happens on another client while disconnected.
      created("A", 10)
      expect(cache()?.map((request) => request.id)).toEqual([kind === "question" ? "frm_A" : "per_A"])
      setConnection("status", "reconnecting")
      delete snapshot[field]
      setConnection("status", "connected")
      await until(() => !setup.index.state.loading && row()[field] === undefined)
      // Real createData invalidates reads on disconnect but retains the old incremental collection.
      expect(cache()?.map((request) => request.id)).toEqual([kind === "question" ? "frm_A" : "per_A"])
      expect(attention().attention).toBeUndefined()
      expect(priority()).toEqual([])
      expect(requests).toEqual([
        "/api/rpc/custom.navigation/list",
        "/api/session/active",
        "/api/rpc/custom.navigation/list",
        "/api/rpc/custom.navigation/list",
        "/api/rpc/custom.navigation/list",
        "/api/session/active",
      ])
    } finally {
      setup.dispose()
    }
  })
}

function until(ready: () => boolean) {
  return new Promise<void>((resolve) =>
    createRoot((dispose) =>
      createEffect(() => {
        if (!ready()) return
        dispose()
        resolve()
      }),
    ),
  )
}
