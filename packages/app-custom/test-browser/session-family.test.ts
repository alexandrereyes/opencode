import { afterEach, expect, test } from "bun:test"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import { OpenCode, type SessionInfo, type FormInfo, type PermissionRequest } from "@opencode/client/promise"
import { createOpenCodeEventSource } from "@/runtime/server/client"
import { createSessionFamilies } from "@/session/family"
import { createSubagentList } from "@/session/files/subagent-list"
import { createSubagentContextSnapshot } from "@/session/files/subagent-context-model"

const cleanups: VoidFunction[] = []
afterEach(() => cleanups.splice(0).forEach((dispose) => dispose()))
const tick = () => new Promise((resolve) => setTimeout(resolve, 10))
const child = (i: number): SessionInfo => ({
  id: `ses_child_${String(i).padStart(3, "0")}`,
  parentID: "ses_root",
  title: `Child ${i}`,
  projectID: "project",
  location: { directory: "/repo" },
  cost: 0.5,
  tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  time: { created: 1, updated: 1 },
})
const question: FormInfo = {
  id: "frm_nested",
  sessionID: "ses_grandchild",
  title: "Question",
  fields: [{ key: "answer", type: "string" }],
  metadata: { kind: "question" },
}

function fixture() {
  return createRoot((dispose) => {
    cleanups.push(dispose)
    const events = createOpenCodeEventSource()
    const [state, setState] = createStore({ id: "ses_root", active: true, connected: true, selected: -1 })
    const requests: {
      method: string
      input: { sessionID: string; after?: string; limit?: number }
      signal: AbortSignal
    }[] = []
    const remembered: SessionInfo[] = []
    const statuses = new Map<string, string>()
    const pending = {
      forms: [question],
      running: [child(153)],
      failures: 0,
      defer: false,
      deferPage: false,
      pages: [] as ReturnType<typeof Promise.withResolvers<Response>>[],
      permissions: [] as PermissionRequest[],
      snapshots: [] as ReturnType<typeof Promise.withResolvers<Response>>[],
    }
    const api = OpenCode.make({
      baseUrl: "http://family.local",
      fetch: async (input, init) => {
        const request = input instanceof Request ? input : new Request(input, init)
        const body = {
          ...((await request.json()) as { input: { sessionID: string; after?: string; limit?: number } }),
          method: new URL(request.url).pathname.split("/").at(-1)!,
        }
        requests.push({ ...body, signal: request.signal })
        if (body.method === "snapshot") {
          if (pending.failures > 0) {
            pending.failures--
            return Response.json({ message: "temporary failure" }, { status: 503 })
          }
          const data = {
            count: 154,
            cost: 77,
            active: pending.running,
            forms: pending.forms,
            permissions: pending.permissions,
          }
          if (pending.defer) {
            const response = Promise.withResolvers<Response>()
            pending.snapshots.push(response)
            return response.promise
          }
          return Response.json({ output: data })
        }
        if (body.method === "page") {
          if (pending.deferPage) {
            const response = Promise.withResolvers<Response>()
            pending.pages.push(response)
            return response.promise
          }
          const start = body.input.after ? Number(body.input.after.split("_").at(-1)) + 1 : 0
          const data = Array.from({ length: Math.min(10, 154 - start) }, (_, i) => child(start + i))
          return Response.json({ output: { data, ...(start + 10 < 154 ? { next: data.at(-1)!.id } : {}) } })
        }
        throw new Error(`Unexpected request ${request.url}: ${JSON.stringify(body)}`)
      },
    })
    const sdk = {
      api,
      event: events.event,
      connection: {
        status: () => (state.connected ? ("connected" as const) : ("reconnecting" as const)),
        epoch: events.connectionEpoch,
      },
    }
    const families = createSessionFamilies({
      sdk,
      remember: (info) => remembered.push(info),
      status: (id, status) => statuses.set(id, status),
    })
    families.watch(() => state.id)
    families.watch(() => state.id)
    const list = createSubagentList({
      sessionID: () => state.id,
      active: () => state.active,
      version: (id) => families.get(id)?.version,
      page: families.page,
    })
    return { state, setState, events, requests, families, list, pending, remembered, statuses, sdk }
  })
}

test("154 descendants cost one shared opening snapshot, one page per expansion and real pagination, with cached reopen", async () => {
  const value = fixture()
  await tick()
  expect(value.requests.map((request) => request.method)).toEqual(["snapshot"])
  expect(value.families.get("ses_root")?.snapshot?.count).toBe(154)
  expect(value.list.state.children).toHaveLength(0)
  expect(value.remembered.map((session) => session.id)).toEqual([child(153).id])
  expect(value.families.get("ses_root")?.snapshot?.forms[0]).toEqual(question)
  value.list.setState("open", true)
  await tick()
  expect(value.requests.map((request) => request.method)).toEqual(["snapshot", "page"])
  expect(value.list.state.children).toHaveLength(10)
  await value.list.load(true)
  expect(value.list.state.children).toHaveLength(20)
  expect(value.requests.at(-1)?.input).toMatchObject({ after: child(9).id, limit: 10 })
  value.list.setState("open", false)
  value.list.setState("open", true)
  await tick()
  expect(value.requests).toHaveLength(3)
  expect(value.list.state.children).toHaveLength(10)
})

test("closing demand aborts the real page signal and switching session clears rows and pending", async () => {
  const value = fixture()
  await tick()
  value.list.setState("open", true)
  await tick()
  const signal = value.requests.find((request) => request.method === "page")!.signal
  expect(signal.aborted).toBeFalse()
  value.list.setState("open", false)
  expect(signal.aborted).toBeTrue()
  value.setState("id", "ses_other")
  expect(value.list.state.children).toHaveLength(0)
  expect(value.families.get("ses_other")?.snapshot).toBeUndefined()
  expect(value.list.state.open).toBeFalse()
})

test("resolved prompts cannot be restored by an old snapshot; reconnect discovers pending and reconciles active status", async () => {
  const value = fixture()
  await tick()
  value.pending.defer = true
  value.families.retry("ses_root")
  await tick()
  expect(value.pending.snapshots).toHaveLength(1)
  value.events.publish({
    id: "evt_reply",
    type: "form.replied",
    created: 2,
    data: { id: question.id, sessionID: question.sessionID, answer: {} },
  })
  expect(value.families.get("ses_root")?.snapshot?.forms).toEqual([])
  value.pending.snapshots[0].resolve(
    Response.json({ output: { count: 154, cost: 77, active: [], forms: [question], permissions: [] } }),
  )
  await tick()
  expect(value.families.get("ses_root")?.snapshot?.forms).toEqual([])
  value.pending.defer = false
  value.pending.running = []
  value.setState("connected", false)
  value.setState("connected", true)
  await new Promise((resolve) => setTimeout(resolve, 175))
  expect(value.families.get("ses_root")?.snapshot?.forms[0]).toEqual(question)
  expect(value.statuses.get(child(153).id)).toBe("idle")
})

test("hidden subagent details make no message or model requests, selected item is bounded and reuses its snapshot", async () => {
  const value = fixture()
  const messages: { id: string; limit?: number; signal?: AbortSignal }[] = []
  const models: string[] = []
  createRoot((dispose) => {
    cleanups.push(dispose)
    Array.from({ length: 10 }, (_, i) =>
      createSubagentContextSnapshot({
        child: () => child(i),
        active: () => value.state.active && value.state.selected === i,
        sdk: {
          ...value.sdk,
          api: {
            message: {
              list: async (input, options) => {
                messages.push({ id: input.sessionID, limit: input.limit, signal: options?.signal })
                return { data: [], cursor: {} }
              },
            },
          },
        },
        data: {
          session: { message: { get: () => undefined } },
          location: {
            model: {
              sync: async (location) => {
                models.push(location!.directory!)
              },
            },
          },
        },
      }),
    )
  })
  await tick()
  expect(messages).toEqual([])
  expect(models).toEqual([])
  value.setState("selected", 3)
  await tick()
  expect(messages.map((request) => [request.id, request.limit])).toEqual([[child(3).id, 20]])
  value.setState("selected", -1)
  expect(messages[0].signal?.aborted).toBeTrue()
  value.setState("selected", 3)
  await tick()
  expect(messages).toHaveLength(1)
})

test("in-flight optional pages are cancelled on collapse and cannot hydrate the shared cache after navigation", async () => {
  const value = fixture()
  await tick()
  value.pending.deferPage = true
  value.list.setState("open", true)
  await tick()
  expect(value.list.state.loading).toBeTrue()
  expect(value.pending.pages).toHaveLength(1)
  const signal = value.requests.at(-1)!.signal
  value.list.setState("open", false)
  expect(signal.aborted).toBeTrue()
  value.setState("id", "ses_other")
  value.pending.pages[0].resolve(Response.json({ output: { data: [child(0)], next: child(0).id } }))
  await tick()
  expect(value.list.state.children).toHaveLength(0)
  expect(value.remembered.some((session) => session.id === child(0).id)).toBeFalse()
})

test("new descendant permissions are automatic, text deltas do not refresh, and runtime event bursts coalesce", async () => {
  const value = fixture()
  await tick()
  const permission: PermissionRequest = {
    id: "per_unloaded",
    sessionID: "ses_grandchild",
    action: "shell",
    resources: [],
  }
  value.pending.permissions = [permission]
  value.events.publish({ type: "permission.asked", id: "evt_asked", created: 2, data: permission })
  await new Promise((resolve) => setTimeout(resolve, 175))
  expect(value.families.get("ses_root")?.snapshot?.permissions).toEqual([permission])
  expect(value.families.permissions()).toEqual([permission])
  expect(value.list.state.children).toHaveLength(0)
  const count = value.requests.length
  Array.from({ length: 100 }, (_, i) =>
    value.events.publish({
      id: `evt_text_${i}`,
      type: "session.text.delta",
      created: 3,
      data: { sessionID: "ses_unrelated", assistantMessageID: "msg_unrelated", ordinal: 0, delta: "x" },
    }),
  )
  await new Promise((resolve) => setTimeout(resolve, 175))
  expect(value.requests).toHaveLength(count)
  Array.from({ length: 100 }, (_, i) =>
    value.events.publish({
      id: `evt_end_${i}`,
      type: "session.execution.succeeded",
      created: 4,
      data: { sessionID: child(i).id },
    }),
  )
  await new Promise((resolve) => setTimeout(resolve, 175))
  expect(value.requests).toHaveLength(count + 1)
  expect(value.requests.every((request) => request.method === "snapshot")).toBeTrue()
  value.events.publish({
    type: "permission.replied",
    id: "evt_reply_permission",
    created: 5,
    data: { sessionID: permission.sessionID, requestID: permission.id, reply: "once" },
  })
  expect(value.families.get("ses_root")?.snapshot?.permissions).toEqual([])
})

test("snapshot failure is visible and explicit retry restores unloaded pending requests", async () => {
  const value = fixture()
  value.pending.failures = 1
  await tick()
  expect(value.families.get("ses_root")?.failed).toBeTrue()
  expect(value.families.get("ses_root")?.snapshot).toBeUndefined()
  value.families.retry("ses_root")
  await tick()
  expect(value.families.get("ses_root")?.failed).toBeFalse()
  expect(value.families.get("ses_root")?.snapshot?.forms[0]).toEqual(question)
  expect(value.requests).toHaveLength(2)
})
