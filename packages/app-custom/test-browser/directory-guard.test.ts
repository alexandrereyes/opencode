import { expect, test } from "bun:test"
import { createRoot, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import { OpenCode, type OpenCodeEvent, type SessionMessageInfo } from "@opencode/client/promise"
import { createData } from "@opencode/client/solid"
import { createOpenCodeEventSource } from "../src/runtime/server/client"
import { createDirectoryGuard, guardLocationSync } from "../src/runtime/server/directory-guard"

test("guards real data resources and their internal event refreshes without blocking session reads", async () => {
  const requests: string[] = []
  const errors: unknown[] = []
  const listeners = new Set<(event: { name: OpenCodeEvent["type"]; details: OpenCodeEvent }) => void>()
  const api = OpenCode.make({
    baseUrl: "http://fixture",
    fetch: async (input) => {
      const url = new URL(input instanceof Request ? input.url : input.toString())
      requests.push(url.pathname)
      return Response.json([])
    },
  })
  const root = createRoot((dispose) => {
    const data = createData({
      api: () => api,
      directory: "/removed",
      onError: (error) => errors.push(error),
      event: {
        on: () => () => {},
        listen: (handler) => {
          listeners.add(handler)
          return () => listeners.delete(handler)
        },
      },
    })
    guardLocationSync(
      data,
      createDirectoryGuard(async () => false),
    )
    return { data, dispose }
  })
  try {
    await root.data.location.sync({ directory: "/removed" })
    for (const type of ["mcp.resources.changed", "mcp.status.changed"] as const) {
      const details = {
        type,
        id: "event",
        created: 1,
        location: { directory: "/removed" },
        data: { server: "fixture" },
      }
      for (const listener of listeners) listener({ name: type, details })
    }
    await new Promise((resolve) => setTimeout(resolve, 200))
    await root.data.location.model.sync({ directory: "/removed" })
    await root.data.session.form.sync("ses_history")
    expect(requests).toEqual(["/api/session/ses_history/form"])
    expect(errors).toEqual([])
  } finally {
    root.dispose()
  }
})

test("late deletion catches HTTP 500s before onError, stops event refreshes, and retains history", async () => {
  const fixture = catalogFixture()
  try {
    await fixture.data.location.sync({ directory: "/repo" })
    expect(fixture.data.location.model.list({ directory: "/repo" })).toEqual([])
    expect(fixture.probes).toEqual(["/repo"])
    const before = fixture.requests.length
    const failures = Promise.withResolvers<void>()
    const probe = Promise.withResolvers<boolean>()
    fixture.state.failure = failures.promise
    fixture.state.probe = probe.promise
    fixture.publish()
    await until(() => fixture.requests.length === before + 3)
    failures.resolve()
    await until(() => fixture.probes.length === 2)
    // The HTTP errors have arrived, but the missing-directory confirmation is pending.
    expect(fixture.errors).toEqual([])
    probe.resolve(false)
    await fixture.data.location.model.sync({ directory: "/repo" })
    fixture.publish()
    await new Promise((resolve) => setTimeout(resolve, 200))
    await fixture.data.location.sync({ directory: "/repo" })
    expect(fixture.requests.length).toBe(before + 3)
    expect(fixture.probes).toEqual(["/repo", "/repo"])
    expect(fixture.errors).toEqual([])
    await fixture.data.session.message.sync("ses_history")
    expect(fixture.data.session.message.list("ses_history")).toEqual(history)
    fixture.connection("reconnecting")
    await new Promise((resolve) => setTimeout(resolve, 0))
    fixture.state.failure = undefined
    fixture.state.probe = Promise.resolve(true)
    fixture.connection("connected")
    fixture.events.publish({ type: "server.connected", id: "restored", data: {} })
    await fixture.data.location.sync({ directory: "/repo" })
    expect(fixture.probes.filter((directory) => directory === "/repo")).toHaveLength(3)
    expect(fixture.data.location.model.list({ directory: "/repo" })).toEqual([])
    expect(fixture.requests.filter((path) => path === "/api/model")).toHaveLength(3)
    expect(fixture.errors).toEqual([])
  } finally {
    fixture.dispose()
  }
})

test("HTTP 500s in existing directories reach createData onError", async () => {
  const fixture = catalogFixture()
  try {
    await fixture.data.location.sync({ directory: "/repo" })
    fixture.state.failure = Promise.resolve()
    fixture.publish()
    await until(() => fixture.errors.length === 3)
    expect(fixture.errors.map((error) => error instanceof Error && error.cause)).toEqual([
      { status: 500 },
      { status: 500 },
      { status: 500 },
    ])
  } finally {
    fixture.dispose()
  }
})

test("aggregate sync stops its fan-out when syncInfo confirms a late deletion", async () => {
  const fixture = catalogFixture()
  try {
    await fixture.data.location.model.sync({ directory: "/repo" })
    fixture.state.failedPaths = ["/api/location"]
    fixture.state.failure = Promise.resolve()
    fixture.state.probe = Promise.resolve(false)
    await fixture.data.location.sync({ directory: "/repo" })
    await fixture.data.location.syncInfo({ directory: "/repo" })
    expect(fixture.requests).toEqual(["/api/model", "/api/location"])
    expect(fixture.probes).toEqual(["/repo", "/repo"])
    expect(fixture.errors).toEqual([])
  } finally {
    fixture.dispose()
  }
})

test("real server.connected event clears a cached absence before reconnect catalog refreshes", async () => {
  const fixture = catalogFixture()
  try {
    fixture.state.probe = Promise.resolve(false)
    await fixture.data.location.sync({ directory: "/repo" })
    expect(fixture.requests).toEqual([])
    fixture.connection("reconnecting")
    await new Promise((resolve) => setTimeout(resolve, 0))
    fixture.state.probe = Promise.resolve(true)
    fixture.connection("connected")
    fixture.events.publish({ type: "server.connected", id: "reconnected", data: {} })
    fixture.publish()
    await until(() => fixture.requests.includes("/api/mcp"))
    await fixture.data.location.sync({ directory: "/repo" })
    expect(fixture.data.location.info({ directory: "/repo" })?.directory).toBe("/repo")
    expect(fixture.data.location.model.list({ directory: "/repo" })).toEqual([])
    expect(fixture.probes.filter((directory) => directory === "/repo")).toHaveLength(2)
    expect(fixture.errors).toEqual([])
  } finally {
    fixture.dispose()
  }
})

const history: SessionMessageInfo[] = [{ id: "msg_history", type: "user", time: { created: 1 }, text: "Saved history" }]

function catalogFixture() {
  return createRoot((dispose) => {
    const requests: string[] = []
    const errors: unknown[] = []
    const probes: string[] = []
    const state = {
      probe: Promise.resolve(true),
      failure: undefined as Promise<void> | undefined,
      failedPaths: ["/api/model", "/api/mcp", "/api/mcp/resource"],
    }
    const events = createOpenCodeEventSource()
    const [connection, setConnection] = createStore({ status: "connected" as "connected" | "reconnecting" })
    const guard = createDirectoryGuard((directory) => {
      probes.push(directory)
      return state.probe
    })
    // Match runtime.tsx: the clear listener is registered before createData subscribes.
    onCleanup(events.event.on("server.connected", () => guard.clear()))
    const api = OpenCode.make({
      baseUrl: "http://fixture",
      fetch: async (input) => {
        const url = new URL(input instanceof Request ? input.url : input.toString())
        requests.push(url.pathname)
        const location = { directory: url.searchParams.get("location[directory]") || "/default" }
        if (url.pathname === "/api/session/ses_history/message") return Response.json({ data: history, cursor: {} })
        if (state.failure && state.failedPaths.includes(url.pathname)) {
          await state.failure
          return Response.json({ message: "catalog failed" }, { status: 500 })
        }
        if (url.pathname === "/api/location") return Response.json({ ...location, project: { id: "project" } })
        if (url.pathname === "/api/session/active") return Response.json({ data: {} })
        if (url.pathname === "/api/project") return Response.json([])
        return Response.json({ location, data: url.pathname === "/api/mcp/resource" ? { resources: [] } : [] })
      },
    })
    const data = createData({
      api: () => api,
      directory: "",
      connection: { status: () => connection.status },
      onError: (error) => errors.push(error),
      event: {
        on: events.event.on,
        listen: (handler) => events.event.listen((event) => handler({ name: event.type, details: event })),
      },
    })
    guardLocationSync(data, guard)
    return {
      data,
      events,
      state,
      requests,
      errors,
      probes,
      dispose,
      connection: (status: "connected" | "reconnecting") => setConnection("status", status),
      publish: () => {
        for (const type of ["model.updated", "mcp.resources.changed", "mcp.status.changed"] as const) {
          events.publish({
            type,
            id: "event",
            created: 1,
            location: { directory: "/repo" },
            data: { server: "fixture" },
          })
        }
      },
    }
  })
}

async function until(ready: () => boolean) {
  for (let i = 0; i < 100; i++) {
    if (ready()) return
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  expect(ready()).toBe(true)
}
