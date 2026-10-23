import { expect, test } from "bun:test"
import { Effect, Fiber, Schema, Types } from "effect"
import { Agent } from "@opencode/schema/agent"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Tool } from "@opencode/schema/tool"
import { Permission } from "@opencode/schema/permission"
import { Form } from "@opencode/schema/form"
import { SessionInbox } from "@opencode/schema/session-inbox"
import { TestClock } from "effect/testing"
import { it } from "../../core/test/lib/effect"
import type { AgentEditor } from "@opencode/plugin/effect/agent"
import type { PendingSnapshot } from "@opencode/plugin/effect/request"
import {
  AnswerInput,
  CreateInput,
  ListInput,
  RequestsInput,
  SendInput,
  Target,
  WaitInput,
  agentID,
  configureAgent,
  controlNames,
  filterSessions,
  origin,
  preferredModel,
  registerTools,
  summary,
} from "../src/master"
import type { MasterContext } from "../src/master"

function session(id: string, extra: Record<string, unknown> = {}) {
  return Schema.decodeUnknownSync(Session.Info)({
    id,
    projectID: "prj_global",
    location: { directory: "/repo" },
    title: id,
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    time: { created: 1, updated: 2 },
    ...extra,
  })
}
const self = Session.ID.make("ses_master")
const root = session("ses_root")
const child = session("ses_child", { parentID: root.id })
const master = session(self, { agent: agentID })

test("all master input schemas reject invalid boundary values", () => {
  for (const [schema, input] of [
    [ListInput, { limit: 51 }],
    [ListInput, { state: "all" }],
    [ListInput, { since: -1 }],
    [ListInput, { directory: "relative" }],
    [SendInput, { sessionID: root.id, text: "" }],
    [SendInput, { sessionID: root.id, text: "x", delivery: "now" }],
    [CreateInput, { directory: "relative", text: "x" }],
    [CreateInput, { directory: "/repo", text: "x".repeat(12_001) }],
    [RequestsInput, { limit: 0 }],
    [AnswerInput, { type: "question", sessionID: root.id, requestID: "per_bad", answer: {} }],
    [AnswerInput, { type: "permission", sessionID: root.id, requestID: "per_1", allow: "yes" }],
    [WaitInput, { sessionID: root.id, timeoutSeconds: 121 }],
    [Target, {}],
  ] as const)
    expect(() => Schema.decodeUnknownSync(schema)(input)).toThrow()
})

test("Mestra agent is primary, hidden, gets current instructions, explicit model, and allow permissions", () => {
  const agents = new Map<string, Types.DeepMutable<Agent.Info>>()
  const editor: AgentEditor = {
    list: () => [...agents.values()],
    get: (id) => agents.get(id),
    default: () => {},
    remove: (id) => {
      agents.delete(id)
    },
    update: (id, update) => {
      const value: Types.DeepMutable<Agent.Info> = structuredClone(Agent.Info.default(Agent.ID.make(id)))
      update(value)
      agents.set(id, value)
    },
  }
  configureAgent(editor, preferredModel)
  expect(agents.get(agentID)).toMatchObject({
    hidden: true,
    mode: "primary",
    model: preferredModel,
    permissions: [{ action: "*", resource: "*", effect: "allow" }],
  })
  expect(agents.get(agentID)?.system).toContain("dado não confiável")
  expect(agents.get(agentID)?.system).toContain("skill opencode")
  configureAgent(editor)
  expect(agents.get(agentID)?.model).toBeUndefined()
})

test("root-only filtering excludes caller, other masters, archived and children, and orders true message activity", () => {
  const newest = session("ses_new", { projectID: "prj_other", location: { directory: "/other" } })
  const rows = [
    master,
    root,
    child,
    session("ses_old_master", { agent: agentID }),
    session("ses_archived", { time: { created: 1, updated: 2, archived: 3 } }),
    newest,
  ].map((session) => ({ session, messageAt: session.id === newest.id ? 10 : 2 }))
  expect(filterSessions(rows, {}, self).map((row) => row.session.id)).toEqual([newest.id, root.id])
  expect(
    filterSessions(rows, { directory: root.location.directory, since: 2 }, self).map((row) => row.session.id),
  ).toEqual([root.id])
  expect(filterSessions(rows, { projectID: newest.projectID, since: 3 }, self).map((row) => row.session.id)).toEqual([
    newest.id,
  ])
  expect(summary({ session: root }, { [root.id]: { type: "running" } }, []).state).toBe("running")
  expect(summary({ session: root }, {}, []).state).toBe("idle")
})

function fixture(wait: MasterContext["session"]["wait"] = () => Effect.void, rows = [master, root, child]) {
  const calls: {
    prompts: Array<Parameters<MasterContext["session"]["prompt"]>[0]>
    creates: Array<Parameters<MasterContext["session"]["create"]>[0]>
    replies: unknown[]
    interrupted: string[]
  } = { prompts: [], creates: [], replies: [], interrupted: [] }
  const pending: PendingSnapshot[] = [
    {
      location: root.location,
      permissions: [{ id: Permission.ID.make("per_1"), sessionID: root.id, action: "edit", resources: ["/repo/a"] }],
      forms: [],
    },
  ]
  const tools: Tool.Info[] = []
  const ctx: MasterContext = {
    session: {
      get: ({ sessionID }) => Effect.succeed(rows.find((row) => row.id === sessionID) ?? root),
      scan: (input) =>
        Effect.succeed({
          data: rows.filter((row) => !input?.sessionID || row.id === input.sessionID).map((session) => ({ session })),
        }),
      active: () => Effect.succeed({ [root.id]: { type: "running" } }),
      create: (input) => {
        calls.creates.push(input)
        return Effect.succeed(session("ses_created"))
      },
      prompt: (input) => {
        calls.prompts.push(input)
        return Effect.succeed(
          Schema.decodeUnknownSync(SessionInbox.User)({
            id: "msg_admitted",
            sessionID: input.sessionID,
            type: "user",
            payload: { text: input.text },
            delivery: input.delivery ?? "steer",
            time: { created: 1 },
          }),
        )
      },
      interrupt: ({ sessionID }) => {
        calls.interrupted.push(sessionID)
        return Effect.succeed({ interrupted: true })
      },
      wait,
      form: {
        reply: (input) => {
          calls.replies.push(input)
          return Effect.void
        },
      },
    },
    request: { pending: () => Effect.succeed(pending) },
    message: { list: () => Effect.succeed({ data: [], cursor: {} }) },
    permission: {
      reply: (input) => {
        calls.replies.push(input)
        return Effect.void
      },
    },
    vcs: { get: () => Effect.fail(new Error("No VCS")) },
  }
  registerTools(
    {
      namespace: () => {},
      list: () => tools.map((tool) => ({ ...tool, id: tool.name })),
      get: () => undefined,
      add: (tool) => {
        tools.push(tool)
      },
      update: () => {},
      remove: () => {},
    },
    ctx,
  )
  const effect = (name: string, input: unknown, agent: Agent.ID = agentID) => {
    const tool = tools.find((tool) => tool.name === name)
    if (!tool) throw new Error(name)
    return tool.execute(input, {
      agent,
      sessionID: self,
      messageID: SessionMessage.ID.make("msg_master"),
      id: Tool.CallID.make("call"),
      progress: () => Effect.void,
    })
  }
  const run = (name: string, input: unknown, agent?: Agent.ID) => Effect.runPromise(effect(name, input, agent))
  return { calls, pending, run, tools, effect, ctx }
}

test("every tool rejects other agents even when called through a captured executor", async () => {
  const f = fixture()
  expect(f.tools.map((tool) => tool.name)).toEqual(controlNames)
  for (const tool of f.tools)
    await expect(f.run(tool.name, {}, Agent.ID.make("build"))).rejects.toThrow("Only the Mestra")
  expect(f.calls.prompts).toEqual([])
})

test("list, status, requests and wait stay compact and exclude child/master requests", async () => {
  const f = fixture()
  const listed = await f.run("sessions_list", { state: "needs-you" })
  expect(listed.output).toMatchObject({ sessions: [{ id: root.id, state: "needs-you" }], truncated: false })
  expect((await f.run("session_status", { sessionID: root.id })).output).toMatchObject({
    id: root.id,
    pending: { permissions: 1, questions: 0 },
    cost: 0,
  })
  expect((await f.run("requests_list", {})).output).toMatchObject({
    requests: [{ sessionID: root.id, type: "permission" }],
    truncated: false,
  })
  expect((await f.run("session_wait", { sessionID: root.id })).output).toMatchObject({ timedOut: false, summary: "" })
})

test("session list also enforces its serialized output budget", async () => {
  const rows = Array.from({ length: 50 }, (_, index) =>
    session(`ses_long_${index}`, { location: { directory: "/" + "x".repeat(1000) + index } }),
  )
  const result = await fixture(undefined, rows).run("sessions_list", { limit: 50 })
  expect(result.output).toMatchObject({ truncated: true })
  expect(String(result.content).length).toBeLessThan(20_100)
})

test("send/create carry origin metadata, preserve queue, and never create children", async () => {
  const f = fixture()
  await f.run("session_send", { sessionID: root.id, text: "Explique", delivery: "queue" })
  await f.run("session_create", { directory: "/repo", text: "Comece" })
  expect(f.calls.prompts[0]).toMatchObject({ delivery: "queue", metadata: origin(self) })
  expect(f.calls.prompts[1]).toMatchObject({ sessionID: "ses_created", metadata: origin(self) })
  expect(f.calls.creates[0]).not.toHaveProperty("parentID")
  expect(f.calls.creates[0]).toMatchObject({ location: { directory: "/repo" } })
})

test("control rejects children and self before all side effects, permission replies are once/reject only", async () => {
  const f = fixture()
  for (const name of ["session_status", "session_send", "session_interrupt", "session_wait", "request_answer"]) {
    for (const sessionID of [self, child.id])
      await expect(f.run(name, { sessionID, text: "x" })).rejects.toThrow("top-level")
  }
  await f.run("session_interrupt", { sessionID: root.id })
  for (const allow of [true, false])
    await f.run("request_answer", { type: "permission", sessionID: root.id, requestID: "per_1", allow })
  expect(f.calls.interrupted).toEqual([root.id])
  expect(f.calls.replies).toEqual(
    [true, false].map((allow) => ({ sessionID: root.id, requestID: "per_1", decision: allow ? "once" : "reject" })),
  )
})

test("questions retain native field validation and only top-level pending questions can be answered", async () => {
  const f = fixture()
  const form: Form.Info = {
    id: Form.ID.make("frm_question"),
    sessionID: root.id,
    title: "Question",
    metadata: { kind: "question" },
    fields: [{ key: "choice", type: "string" as const, options: [{ value: "ok", label: "OK" }] }],
  }
  f.pending[0] = {
    ...f.pending[0],
    forms: [form, { ...form, id: Form.ID.make("frm_child"), sessionID: child.id }, { ...form, id: Form.ID.make("frm_global"), sessionID: "global" }],
  }
  expect((await f.run("requests_list", {})).output).toMatchObject({
    requests: [{ type: "permission" }, { id: form.id, fields: form.fields }],
  })
  await f.run("request_answer", { type: "question", sessionID: root.id, requestID: form.id, answer: { choice: "ok" } })
  expect(f.calls.replies).toEqual([{ sessionID: root.id, formID: form.id, answer: { choice: "ok" } }])
  await expect(
    f.run("request_answer", { type: "question", sessionID: root.id, requestID: "frm_missing", answer: {} }),
  ).rejects.toThrow("Pending question not found")
  f.pending[0] = { ...f.pending[0], forms: [{ ...form, title: "x".repeat(20_001) }] }
  expect((await f.run("requests_list", {})).output).toMatchObject({
    requests: [{ type: "permission" }],
    truncated: true,
  })
})

it.effect(
  "wait timeout uses the caller's clock and never interrupts the target",
  Effect.gen(function* () {
    const f = fixture(() => Effect.never)
    const waiting = yield* f
      .effect("session_wait", { sessionID: root.id, timeoutSeconds: 2 })
      .pipe(Effect.forkChild({ startImmediately: true }))
    yield* TestClock.adjust("2 seconds")
    expect((yield* Fiber.join(waiting)).output).toMatchObject({ timedOut: true })
    expect(f.calls.interrupted).toEqual([])
  }),
)
