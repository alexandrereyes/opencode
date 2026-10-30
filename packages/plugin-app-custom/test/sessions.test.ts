import { expect, test } from "bun:test"
import { Clock, DateTime, Effect, Fiber, Schema } from "effect"
import { Agent } from "@opencode/schema/agent"
import { Model } from "@opencode/schema/model"
import { Provider } from "@opencode/schema/provider"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Tool } from "@opencode/schema/tool"
import { Permission } from "@opencode/schema/permission"
import { Form } from "@opencode/schema/form"
import { SessionInbox } from "@opencode/schema/session-inbox"
import { TestClock } from "effect/testing"
import { it } from "../../core/test/lib/effect"
import type { PendingSnapshot } from "@opencode/plugin/effect/request"
import { Preferences } from "../src/preferences/rpc"
import {
  AnswerInput,
  CreateInput,
  ListInput,
  MarkReadInput,
  RequestsInput,
  SendInput,
  Target,
  UpdateInput,
  WaitInput,
  ago,
  attention,
  modelRef,
  origin,
  registerTools,
  sessionTool,
  sessionToolNames,
} from "../src/sessions"
import type { SessionsContext } from "../src/sessions"
import { agentID } from "../src/master"

const now = 10 * 3_600_000
const fixedClock: Clock.Clock = {
  currentTimeMillisUnsafe: () => now,
  currentTimeMillis: Effect.succeed(now),
  monotonicTimeNanosUnsafe: () => BigInt(now) * 1_000_000n,
  monotonicTimeNanos: Effect.succeed(BigInt(now) * 1_000_000n),
  currentTimeNanosUnsafe: () => BigInt(now) * 1_000_000n,
  currentTimeNanos: Effect.succeed(BigInt(now) * 1_000_000n),
  sleep: () => Effect.void,
}

function session(id: string, extra: Record<string, unknown> = {}) {
  return Schema.decodeUnknownSync(Session.Info)({
    id,
    projectID: "prj_repo",
    location: { directory: "/repo" },
    title: id,
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    time: { created: 1, updated: 2 },
    ...extra,
  })
}
const self = Session.ID.make("ses_master")
const root = session("ses_root", { outcome: "succeeded", time: { created: 1, updated: 2, idle: now - 60_000 } })
const child = session("ses_child", { parentID: root.id, title: "Subagente" })
const master = session(self, { agent: agentID })
const other = session("ses_other", { title: "Outra sessão", time: { created: 1, updated: 3 } })
const worker = session("ses_worker", { parentID: other.id, title: "Subagente da outra", agent: "general" })

function catalogModel(providerID: string, id: string, variants: string[] = [], enabled = true) {
  return {
    ...Model.Info.default(Provider.ID.make(providerID), Model.ID.make(id)),
    variants: variants.map((id) => ({ id: Model.VariantID.make(id) })),
    enabled,
  }
}
const luna = Model.Ref.make({
  providerID: Provider.ID.make("llm-proxy"),
  id: Model.ID.make("gpt-6-luna"),
  variant: Model.VariantID.make("low"),
})

test("all master input schemas reject invalid boundary values", () => {
  for (const [schema, input] of [
    [ListInput, { limit: 51 }],
    [ListInput, { state: "all" }],
    [ListInput, { sinceHours: 0 }],
    [ListInput, { directory: "relative" }],
    [SendInput, { sessionID: root.id, text: "" }],
    [SendInput, { sessionID: root.id, text: "x", delivery: "now" }],
    [CreateInput, { directory: "relative", text: "x" }],
    [CreateInput, { directory: "/repo", text: "x".repeat(12_001) }],
    [CreateInput, { directory: "/repo", text: "x", worktree: { name: "~/Worktrees/x" } }],
    [UpdateInput, { sessionID: root.id, title: "" }],
    [MarkReadInput, { sessionIDs: [] }],
    [MarkReadInput, { all: false }],
    [RequestsInput, { limit: 0 }],
    [AnswerInput, { type: "question", sessionID: root.id, requestID: "per_bad", answer: {} }],
    [AnswerInput, { type: "permission", sessionID: root.id, requestID: "per_1", allow: "yes" }],
    [WaitInput, { sessionID: root.id, timeoutSeconds: 121 }],
    [Target, {}],
  ] as const)
    expect(() => Schema.decodeUnknownSync(schema)(input)).toThrow()
})

test("unread and failed follow the app lists: a finished or failed run not opened since", () => {
  const idle = 100
  const viewed = (value: number) => value
  const at = (extra: Record<string, unknown>) => attention({ session: session("ses_x", extra) })
  expect(at({ outcome: "succeeded", time: { created: 1, updated: 2, idle } })).toEqual({ unreadAt: 100, failed: false })
  expect(at({ outcome: "failed", time: { created: 1, updated: 2, idle } })).toEqual({ unreadAt: 100, failed: true })
  expect(at({ outcome: "succeeded", time: { created: 1, updated: 2, idle, viewed: viewed(100) } })).toEqual({
    unreadAt: undefined,
    failed: false,
  })
  expect(at({ outcome: "interrupted", time: { created: 1, updated: 2, idle } })).toEqual({
    unreadAt: undefined,
    failed: false,
  })
  expect(ago(now, now - 30_000)).toBe("agora")
  expect(ago(now, now - 5 * 60_000)).toBe("há 5 min")
  expect(ago(now, now - 3 * 3_600_000)).toBe("há 3 h")
  expect(ago(now, now - 49 * 3_600_000)).toBe("há 2 dias")
})

test("model references from the models tool may carry the provider in the ID", () => {
  expect(modelRef({ ...luna, id: Model.ID.make("llm-proxy/gpt-6-luna") })).toEqual(luna)
  expect(modelRef(luna)).toEqual(luna)
})

type Calls = {
  prompts: Array<Parameters<SessionsContext["session"]["prompt"]>[0]>
  creates: Array<Parameters<SessionsContext["session"]["create"]>[0]>
  replies: unknown[]
  interrupted: string[]
  viewed: Array<{ sessionID: string; idle: number }>
  archived: string[]
  updates: unknown[]
  intents: unknown[]
  worktrees: unknown[]
  moves: unknown[]
  branches: unknown[]
  removed: string[]
  claims: unknown[]
}

const profile: Preferences.Profile = {
  version: 1,
  revision: 1,
  imported: true,
  data: {
    projects: {},
    sidebarOrder: [],
    pinnedSessions: [JSON.stringify(["http://other", root.id])],
    // Left by older app builds; ignored now that "Avisar ao terminar" replaced muting.
    mutedSessions: [JSON.stringify(["http://localhost:4096", "ses_read"])],
    notifySessions: [JSON.stringify(["http://localhost:4096", "ses_failed"])],
    models: { user: [], variant: {} },
    settings: {
      followUpBehavior: "steer",
      autoApprove: false,
      autoSave: true,
      notifications: { agent: true, permissions: true, errors: false },
    },
  },
}

function fixture(
  input: {
    wait?: SessionsContext["session"]["wait"]
    rows?: Session.Info[]
    active?: string[]
    messages?: Record<string, unknown[]>
    worktreeFails?: boolean
    branchFails?: boolean
    profile?: Preferences.Profile
  } = {},
) {
  const rows = [...(input.rows ?? [master, root, child])]
  const calls: Calls = {
    prompts: [],
    creates: [],
    replies: [],
    interrupted: [],
    viewed: [],
    archived: [],
    updates: [],
    intents: [],
    worktrees: [],
    moves: [],
    branches: [],
    removed: [],
    claims: [],
  }
  const pending: PendingSnapshot[] = [
    {
      location: root.location,
      permissions: [{ id: Permission.ID.make("per_1"), sessionID: root.id, action: "edit", resources: ["/repo/a"] }],
      forms: [],
    },
  ]
  const tools: Tool.Info[] = []
  const decodeMessages = Schema.decodeUnknownSync(Schema.Array(SessionMessage.Info))
  const ctx: SessionsContext = {
    session: {
      get: ({ sessionID }) => {
        const found = rows.find((row) => row.id === sessionID)
        return found ? Effect.succeed(found) : Effect.fail(new Error(`missing ${sessionID}`))
      },
      scan: (scan) =>
        Effect.succeed({
          data: rows
            .filter((row) => !scan?.sessionID || row.id === scan.sessionID)
            .filter((row) => scan?.parentID === undefined || (row.parentID ?? null) === scan.parentID)
            .map((session) => ({ session, messageAt: DateTime.toEpochMillis(session.time.updated) })),
        }),
      active: () => Effect.succeed(Object.fromEntries((input.active ?? []).map((id) => [id, { type: "running" }]))),
      create: (create) => {
        calls.creates.push(create)
        const created = session(create?.id ?? "ses_created", { location: create?.location })
        rows.push(created)
        return Effect.succeed(created)
      },
      remove: ({ sessionID }) => {
        calls.removed.push(sessionID)
        return Effect.void
      },
      prompt: (prompt) => {
        calls.prompts.push(prompt)
        return Effect.succeed(
          Schema.decodeUnknownSync(SessionInbox.User)({
            id: "msg_admitted",
            sessionID: prompt.sessionID,
            type: "user",
            payload: { text: prompt.text },
            delivery: prompt.delivery ?? "steer",
            time: { created: 1 },
          }),
        )
      },
      interrupt: ({ sessionID }) => {
        calls.interrupted.push(sessionID)
        return Effect.succeed({ interrupted: true })
      },
      wait: input.wait ?? (() => Effect.void),
      form: {
        reply: (reply) => {
          calls.replies.push(reply)
          return Effect.void
        },
      },
      view: (view) => {
        calls.viewed.push({ sessionID: view.sessionID, idle: DateTime.toEpochMillis(view.idle) })
        return Effect.void
      },
      update: (update) => {
        if (update.archived) calls.archived.push(update.sessionID)
        if (!update.archived) calls.updates.push(update)
        return Effect.void
      },
      move: (move) => {
        calls.moves.push(move)
        return Effect.void
      },
      switchModel: (change) => {
        calls.updates.push(change)
        return Effect.void
      },
      switchAgent: (change) => {
        calls.updates.push(change)
        return Effect.void
      },
      family: ({ sessionID }) => {
        const members = rows.filter((row) => row.parentID === sessionID)
        return Effect.succeed({
          count: members.length,
          cost: members.length * 0.5,
          data: [],
          active: members.filter((row) => (input.active ?? []).includes(row.id)),
        })
      },
    },
    request: { pending: () => Effect.succeed(pending) },
    message: {
      list: ({ sessionID }) => Effect.succeed({ data: decodeMessages(input.messages?.[sessionID] ?? []), cursor: {} }),
    },
    permission: {
      reply: (reply) => {
        calls.replies.push(reply)
        return Effect.void
      },
    },
    vcs: { get: () => Effect.fail(new Error("No VCS")) },
    worktree: {
      create: (create) => {
        calls.worktrees.push(create)
        return input.worktreeFails
          ? Effect.fail(new Error("git failed"))
          : Effect.succeed({ directory: AbsolutePath.make(`/worktrees/${create.name ?? "random"}`) })
      },
      remove: (remove) => {
        calls.worktrees.push({ removed: remove.directory })
        return Effect.void
      },
    },
    model: {
      list: () =>
        Effect.succeed({
          location: { directory: AbsolutePath.make("/repo") },
          data: [catalogModel("llm-proxy", "gpt-6-luna", ["low", "high"])],
        }),
    },
    agent: {
      list: () =>
        Effect.succeed({
          location: { directory: AbsolutePath.make("/repo") },
          data: [
            Agent.Info.default(Agent.ID.make("build")),
            { ...Agent.Info.default(Agent.ID.make("explore")), mode: "subagent" as const },
          ],
        }),
    },
    preferences: {
      get: () => Effect.succeed(input.profile ?? profile),
      mutate: (intent) => {
        calls.intents.push(intent)
        return Effect.void
      },
    },
    git: {
      createBranch: (directory, branch) => {
        calls.branches.push({ directory, branch })
        return input.branchFails ? Effect.fail(new Error(`branch ${branch} exists`)) : Effect.void
      },
    },
    chats: {
      root: () => Effect.succeed("/chats"),
      allocate: () => Effect.succeed({ id: "chat_1", directory: AbsolutePath.make("/chats/2026/session-1") }),
      claim: (claim) => {
        calls.claims.push(claim)
        return Effect.void
      },
      confirm: (confirm) => {
        calls.claims.push(confirm)
        return Effect.void
      },
    },
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
  const effect = (name: string, value: unknown, as: { agent?: Agent.ID; sessionID?: Session.ID } = {}) => {
    const tool = tools.find((tool) => tool.name === name)
    if (!tool) throw new Error(name)
    return tool.execute(value, {
      agent: as.agent ?? agentID,
      sessionID: as.sessionID ?? self,
      messageID: SessionMessage.ID.make("msg_master"),
      id: Tool.CallID.make("call"),
      progress: () => Effect.void,
    })
  }
  const run = (name: string, value: unknown, as?: { agent?: Agent.ID; sessionID?: Session.ID }) =>
    Effect.runPromise(effect(name, value, as).pipe(Effect.provideService(Clock.Clock, fixedClock)))
  return { calls, pending, run, tools, effect, ctx }
}

test("every tool is an ordinary Code Mode tool of the sessions namespace, and only read is pinned", () => {
  const f = fixture()
  expect(Object.fromEntries(f.tools.map((tool) => [tool.name, tool.options]))).toEqual(
    Object.fromEntries(
      sessionToolNames.map((name) => [
        name,
        { namespace: "sessions", codemode: true, ...(name === "read" ? { pinned: true } : {}) },
      ]),
    ),
  )
})

test("session tools are recognized by their current, ID and former names, never by a bare native name", () => {
  expect(["sessions.read", "sessions_read", "opencode.session_read", "session_read"].map(sessionTool)).toEqual([
    "read",
    "read",
    "read",
    "read",
  ])
  expect(["sessions.list", "sessions_list", "mestra.sessions_list"].map(sessionTool)).toEqual(["list", "list", "list"])
  expect(sessionTool("mestra.request_answer")).toBe("answer")
  expect(sessionTool("sessions.mark_read")).toBe("mark_read")
  expect(["read", "search", "execute", "sessions.unknown", "opencode.session_rename"].map(sessionTool)).toEqual([
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
  ])
})

test("another agent's session controls everything but itself and the Mestra, and its messages name it", async () => {
  const f = fixture({ rows: [master, root, child, other, worker] })
  const build = { agent: Agent.ID.make("build"), sessionID: root.id }
  const ids = async (as: typeof build) =>
    ((await f.run("list", {}, as)).output as { sessions: Array<{ id: string }> }).sessions.map((row) => row.id)
  // The caller is left out of its lists, as the Mestra is; Mestra sessions and subagents never appear.
  expect(await ids(build)).toEqual([other.id])
  await f.run("send", { sessionID: other.id, text: "Continue" }, build)
  expect(f.calls.prompts[0]).toMatchObject({
    sessionID: other.id,
    metadata: { "custom.sender": { sessionID: root.id, agent: "build" } },
  })
  expect(f.calls.prompts[0]?.metadata).not.toHaveProperty("custom.master")
  await expect(f.run("send", { sessionID: root.id, text: "x" }, build)).rejects.toThrow("calling session")
  await expect(f.run("send", { sessionID: self, text: "x" }, build)).rejects.toThrow("Mestra session")
  const chat = await f.run("create", { text: "Pesquise" }, build)
  expect(chat.output).toMatchObject({ directory: "/chats/2026/session-1" })
  expect(f.calls.prompts[1]).toMatchObject({ metadata: { "custom.sender": { sessionID: root.id, agent: "build" } } })

  // A subagent acts for its top-level session: that whole family is the caller.
  const subagent = { agent: Agent.ID.make("general"), sessionID: worker.id }
  f.pending.push({
    location: other.location,
    permissions: [{ id: Permission.ID.make("per_own"), sessionID: worker.id, action: "edit", resources: ["/repo/b"] }],
    forms: [],
  })
  const listed = await ids(subagent)
  expect(listed).toContain(root.id)
  expect(listed).not.toContain(other.id)
  for (const name of ["interrupt", "wait", "status"])
    await expect(f.run(name, { sessionID: other.id }, subagent)).rejects.toThrow("calling session")
  expect((await f.run("archive", { sessionIDs: [other.id] }, subagent)).output).toMatchObject({
    archived: [],
    skipped: [{ sessionID: other.id, reason: expect.stringContaining("calling session") }],
  })
  await expect(
    f.run("answer", { type: "permission", sessionID: worker.id, requestID: "per_own", allow: true }, subagent),
  ).rejects.toThrow("calling session")
  await f.run("answer", { type: "permission", sessionID: root.id, requestID: "per_1", allow: false }, subagent)
  expect(f.calls.replies).toEqual([{ sessionID: root.id, requestID: "per_1", decision: "reject" }])
  expect(f.calls.interrupted).toEqual([])
  expect(f.calls.archived).toEqual([])
})

test("list aggregates subagent requests and work, unread, failed, marks and counts, and filters", async () => {
  const failed = session("ses_failed", {
    outcome: "failed",
    title: "Migrar banco",
    time: { created: 1, updated: 3, idle: now - 120_000 },
  })
  const read = session("ses_read", {
    outcome: "succeeded",
    projectID: "prj_other",
    location: { directory: "/other" },
    title: "Ajustar ícone",
    time: { created: 1, updated: 4, idle: 5, viewed: 5 },
  })
  const archived = session("ses_archived", { time: { created: 1, updated: 2, archived: 3 } })
  const f = fixture({ rows: [master, root, child, failed, read, archived], active: [child.id] })
  f.pending[0] = {
    ...f.pending[0],
    permissions: [{ id: Permission.ID.make("per_child"), sessionID: child.id, action: "edit", resources: [] }],
  }
  const listed = await f.run("list", {})
  expect(listed.output).toMatchObject({
    counts: { total: 3, needsYou: 1, running: 0, unread: 2, failed: 1, cost: 0.5 },
    truncated: false,
  })
  const byID = new Map(
    (listed.output as { sessions: Array<{ id: string }> }).sessions.map((row) => [row.id, row] as const),
  )
  expect(byID.get(root.id)).toMatchObject({
    state: "needs-you",
    unread: true,
    pending: { questions: 0, permissions: 1 },
    subagentsRunning: 1,
    pinned: true,
    project: "repo",
    lastActivityAgo: "há 10 h",
    cost: 0.5,
  })
  expect(byID.get(failed.id)).toMatchObject({ state: "idle", unread: true, failed: true, notify: true })
  expect(byID.get(read.id)).toMatchObject({ unread: false, project: "other" })
  expect(byID.get(read.id)).not.toHaveProperty("muted")
  expect(byID.get(root.id)).not.toHaveProperty("notify")
  expect(byID.has(self)).toBe(false)
  expect(byID.has(child.id)).toBe(false)
  expect(byID.has(archived.id)).toBe(false)
  const filtered = async (value: unknown) =>
    ((await f.run("list", value)).output as { sessions: Array<{ id: string }> }).sessions.map((row) => row.id)
  expect(await filtered({ unread: true, failed: false })).toEqual([root.id])
  expect(await filtered({ query: "MIGRAR" })).toEqual([failed.id])
  expect(await filtered({ project: "other" })).toEqual([read.id])
  expect(await filtered({ state: "needs-you" })).toEqual([root.id])
  expect(await filtered({ archived: true })).toEqual([archived.id])
  expect(await filtered({ directory: "/other" })).toEqual([read.id])
})

test("session list also enforces its serialized output budget", async () => {
  const rows = Array.from({ length: 50 }, (_, index) =>
    session(`ses_long_${index}`, { location: { directory: "/" + "x".repeat(1000) + index } }),
  )
  const result = await fixture({ rows: [master, ...rows] }).run("list", { limit: 50 })
  expect(result.output).toMatchObject({ truncated: true })
  expect(String(result.content).length).toBeLessThan(20_300)
})

test("projects group sessions by project and chats into one entry", async () => {
  const chat = session("ses_chat", { projectID: "prj_chat", location: { directory: "/chats/2026/session-1" } })
  const worktree = session("ses_worktree", { location: { directory: "/worktrees/repo-x" } })
  const second = session("ses_second")
  const result = await fixture({ rows: [master, root, second, worktree, chat] }).run("projects", {})
  expect(result.output).toMatchObject({
    projects: expect.arrayContaining([
      expect.objectContaining({ id: "prj_repo", name: "repo", directory: "/repo", worktrees: ["/worktrees/repo-x"] }),
      expect.objectContaining({ id: "chats", name: "Conversas", worktrees: [] }),
    ]),
  })
})

const assistant = (id: string, sessionID: string, text: string, extra: unknown[] = []) => ({
  id,
  sessionID,
  type: "assistant",
  agent: "build",
  model: { id: "gpt-6-luna", providerID: "llm-proxy" },
  content: [{ type: "text", text }, ...extra],
  time: { created: 2, completed: 3 },
})

test("status reports last reply, run error, changed files and subagents with total cost", async () => {
  const f = fixture({
    active: [child.id],
    messages: {
      [root.id]: [
        {
          id: "msg_idle",
          sessionID: root.id,
          type: "idle",
          outcome: "failed",
          error: { type: "x", message: "Sem cota" },
          time: { created: 4 },
        },
        assistant("msg_reply", root.id, "Corrigi o login.", [
          {
            type: "tool",
            id: "call_1",
            name: "patch",
            state: {
              status: "completed",
              input: {},
              content: [{ type: "text", text: "ok" }],
              metadata: { files: [{ file: "src/auth.ts" }] },
            },
            time: { created: 2 },
          },
        ]),
      ],
    },
  })
  expect((await f.run("status", { sessionID: root.id })).output).toMatchObject({
    id: root.id,
    pending: { permissions: 1, questions: 0 },
    lastReply: "Corrigi o login.",
    error: "Sem cota",
    filesChanged: ["src/auth.ts"],
    subagents: { total: 1, running: [{ sessionID: child.id, title: "Subagente" }] },
    cost: 0.5,
  })
})

test("search finds words in titles and in message text, ignoring accents", async () => {
  const f = fixture({
    messages: { [root.id]: [assistant("msg_a", root.id, "Configurei o webhook do Stripe e a validação.")] },
  })
  const found = await f.run("search", { query: "VALIDACAO stripe" })
  expect(found.output).toMatchObject({
    results: [{ sessionID: root.id, matches: [{ where: "resposta", snippet: expect.stringContaining("webhook") }] }],
  })
  expect((await f.run("search", { query: "ses_root" })).output).toMatchObject({
    results: [{ sessionID: root.id, matches: [{ where: "título" }] }],
  })
  expect((await f.run("search", { query: "inexistente" })).output).toMatchObject({ results: [] })
})

test("requests include subagent questions and permissions, which can be answered through their root", async () => {
  const f = fixture()
  const form: Form.Info = {
    id: Form.ID.make("frm_question"),
    sessionID: child.id,
    title: "Qual título?",
    metadata: { kind: "question" },
    fields: [{ key: "choice", type: "string" as const, options: [{ value: "ok", label: "OK", description: "x" }] }],
  }
  f.pending[0] = {
    ...f.pending[0],
    forms: [form, { ...form, id: Form.ID.make("frm_global"), sessionID: "global" }],
  }
  expect((await f.run("requests", {})).output).toMatchObject({
    requests: [
      { type: "permission", sessionID: root.id, session: root.id },
      {
        type: "question",
        sessionID: child.id,
        session: root.id,
        subagent: { sessionID: child.id, title: "Subagente" },
        fields: [{ key: "choice", options: [{ value: "ok", label: "OK" }] }],
      },
    ],
    truncated: false,
  })
  await f.run("answer", { type: "question", sessionID: child.id, requestID: form.id, answer: { choice: "ok" } })
  expect(f.calls.replies).toEqual([{ sessionID: child.id, formID: form.id, answer: { choice: "ok" } }])
  await expect(
    f.run("answer", { type: "question", sessionID: root.id, requestID: "frm_missing", answer: {} }),
  ).rejects.toThrow("Pending question not found")
})

test("send/create carry origin metadata, preserve queue, never create children and validate model and agent", async () => {
  const f = fixture()
  await f.run("send", { sessionID: root.id, text: "Explique", delivery: "queue" })
  const created = await f.run("create", {
    directory: "/repo",
    text: "Comece",
    model: { providerID: "llm-proxy", id: "llm-proxy/gpt-6-luna", variant: "high" },
  })
  const fromMestra = { "custom.master": { sessionID: self } }
  expect(origin({ agent: agentID, sessionID: self })).toEqual(fromMestra)
  expect(f.calls.prompts[0]).toMatchObject({ delivery: "queue", metadata: fromMestra })
  expect(f.calls.prompts[1]).toMatchObject({ text: "Comece", metadata: fromMestra })
  expect(f.calls.creates[0]).not.toHaveProperty("parentID")
  expect(f.calls.creates[0]).toMatchObject({
    location: { directory: "/repo" },
    model: { providerID: "llm-proxy", id: "gpt-6-luna", variant: "high" },
  })
  expect(created.output).toMatchObject({ directory: "/repo" })
  await expect(
    f.run("create", { directory: "/repo", text: "x", model: { providerID: "llm-proxy", id: "gpt-9" } }),
  ).rejects.toThrow("is not available")
  await expect(f.run("create", { directory: "/repo", text: "x", agent: "explore" })).rejects.toThrow(
    "cannot run a session here",
  )
  await expect(f.run("create", { directory: "/repo", text: "x", agent: agentID })).rejects.toThrow("master accessory")
})

test("create opens a standalone chat without directory, and a worktree with its branch before the first message", async () => {
  const f = fixture()
  const chat = await f.run("create", { text: "Pesquise" })
  expect(chat.output).toMatchObject({ directory: "/chats/2026/session-1" })
  expect(f.calls.claims).toHaveLength(2)
  const created = await f.run("create", {
    directory: "/repo",
    text: "Planeje",
    worktree: { branch: "feature/csv" },
  })
  expect(f.calls.worktrees[0]).toMatchObject({ projectID: "prj_repo", from: "/repo", name: "repo-feature-csv" })
  expect(f.calls.branches).toEqual([{ directory: "/worktrees/repo-feature-csv", branch: "feature/csv" }])
  expect(f.calls.moves[0]).toMatchObject({ directory: "/worktrees/repo-feature-csv" })
  expect(created.output).toMatchObject({ worktree: "/worktrees/repo-feature-csv", branch: "feature/csv" })
  const failing = fixture({ worktreeFails: true })
  await expect(failing.run("create", { directory: "/repo", text: "x", worktree: { name: "x" } })).rejects.toThrow(
    "the session was not created",
  )
  expect(failing.calls.removed).toHaveLength(1)
  expect(failing.calls.prompts).toEqual([])
  const branchless = fixture({ branchFails: true })
  await expect(
    branchless.run("create", { directory: "/repo", text: "x", worktree: { branch: "taken" } }),
  ).rejects.toThrow("branch taken exists")
  expect(branchless.calls.worktrees).toContainEqual({ removed: "/worktrees/repo-taken" })
  expect(branchless.calls.removed).toHaveLength(1)
  expect(branchless.calls.prompts).toEqual([])
})

test("update renames, switches model and agent, and pins or unpins across server keys", async () => {
  const f = fixture()
  const result = await f.run("update", {
    sessionID: root.id,
    title: "Login com hash",
    model: { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" },
    agent: "build",
    pinned: false,
    notify: true,
  })
  expect(result.output).toEqual({ sessionID: root.id, changed: ["title", "model", "agent", "pinned", "notify"] })
  expect(f.calls.updates).toEqual([
    { sessionID: root.id, title: "Login com hash" },
    { sessionID: root.id, model: luna },
    { sessionID: root.id, agent: "build" },
  ])
  expect(f.calls.intents).toEqual([
    { type: "sidebar.pin", session: JSON.stringify(["http://other", root.id]), pinned: false },
    { type: "sidebar.notify", session: JSON.stringify(["http://localhost:4096", root.id]), notify: true },
  ])
  // Turning it off removes every server key of that session.
  const off = fixture({
    profile: { ...profile, data: { ...profile.data, notifySessions: [JSON.stringify(["http://other", root.id])] } },
  })
  await off.run("update", { sessionID: root.id, notify: false })
  expect(off.calls.intents).toEqual([
    { type: "sidebar.notify", session: JSON.stringify(["http://other", root.id]), notify: false },
  ])
})

test("mark read views unread or failed sessions at their idle time; archive goes through the native archive", async () => {
  const failed = session("ses_failed", { outcome: "failed", time: { created: 1, updated: 3, idle: 50 } })
  const read = session("ses_read", { outcome: "succeeded", time: { created: 1, updated: 3, idle: 50, viewed: 50 } })
  const f = fixture({ rows: [master, root, failed, read] })
  expect((await f.run("mark_read", { all: true })).output).toMatchObject({
    marked: [{ sessionID: failed.id }, { sessionID: root.id }],
    skipped: [],
  })
  expect(f.calls.viewed).toEqual([
    { sessionID: failed.id, idle: 50 },
    { sessionID: root.id, idle: now - 60_000 },
  ])
  expect((await f.run("mark_read", { sessionIDs: [read.id] })).output).toMatchObject({
    marked: [],
    skipped: [{ sessionID: read.id, reason: "already read" }],
  })
  await expect(f.run("mark_read", {})).rejects.toThrow("either sessionIDs or all")
  expect((await f.run("mark_read", { sessionIDs: [self, read.id] })).output).toMatchObject({
    skipped: [{ sessionID: self, reason: expect.stringContaining("calling session") }, { sessionID: read.id }],
  })
  expect((await f.run("archive", { sessionIDs: [failed.id, self] })).output).toMatchObject({
    archived: [{ sessionID: failed.id, title: failed.id }],
    skipped: [{ sessionID: self }],
  })
  // Stopped before its subagents are archived and again right before it is archived.
  expect(f.calls.interrupted).toEqual([failed.id, failed.id])
  expect(f.calls.archived).toEqual([failed.id])
})

test("control rejects children, self and archived sessions before side effects, with the reason", async () => {
  const archived = session("ses_archived", { time: { created: 1, updated: 2, archived: 3 } })
  const earlier = session("ses_earlier_master", { agent: agentID })
  const f = fixture({ rows: [master, earlier, root, child, archived] })
  for (const name of ["status", "send", "interrupt", "wait", "update"]) {
    await expect(f.run(name, { sessionID: self, text: "x" })).rejects.toThrow("calling session")
    await expect(f.run(name, { sessionID: earlier.id, text: "x" })).rejects.toThrow("Mestra session")
    await expect(f.run(name, { sessionID: child.id, text: "x" })).rejects.toThrow("subagent")
    await expect(f.run(name, { sessionID: archived.id, text: "x" })).rejects.toThrow("archived")
  }
  await f.run("interrupt", { sessionID: root.id })
  for (const allow of [true, false])
    await f.run("answer", { type: "permission", sessionID: root.id, requestID: "per_1", allow })
  expect(f.calls.interrupted).toEqual([root.id])
  expect(f.calls.replies).toEqual(
    [true, false].map((allow) => ({ sessionID: root.id, requestID: "per_1", decision: allow ? "once" : "reject" })),
  )
  expect(f.calls.prompts).toEqual([])
})

it.effect(
  "wait timeout uses the caller's clock and never interrupts the target",
  Effect.gen(function* () {
    const f = fixture({ wait: () => Effect.never })
    const waiting = yield* f
      .effect("wait", { sessionID: root.id, timeoutSeconds: 2 })
      .pipe(Effect.forkChild({ startImmediately: true }))
    yield* TestClock.adjust("2 seconds")
    expect((yield* Fiber.join(waiting)).output).toMatchObject({ timedOut: true, session: { id: root.id } })
    expect(f.calls.interrupted).toEqual([])
  }),
)
