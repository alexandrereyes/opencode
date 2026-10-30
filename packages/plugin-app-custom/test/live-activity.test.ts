import { expect, test } from "bun:test"
import { Effect, Schema } from "effect"
import { body, fit, limits as pushLimits } from "../src/live-activity/lifecycle"
import { LiveActivity } from "../src/live-activity/rpc"
import { clip, describe as activity, limits, makeTracker } from "../src/live-activity/tracker"
import {
  T,
  T0,
  created,
  execution,
  fixture,
  ids,
  minute,
  permission,
  question,
  scene,
  session,
  tool,
  world,
  backgroundShellMessage,
  shellExited,
  shellNotice,
  shellNoticeMessage,
  shellStarted,
  type Scene,
} from "./fixture/live-activity"

const host = "MacBook Pro"
const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect)

test.each([
  ["working", "state-working"],
  ["one-question", "state-one-question"],
  ["two-questions", "state-two-questions"],
  ["mixed", "state-mixed"],
  ["failed-only", "state-failed-only"],
] satisfies [Scene, string][])("events folded into the %s situation produce %s.json", async (name, file) => {
  const tracker = await run(scene(name))
  const state = tracker.derive(T, host).state
  expect(state).toEqual(await fixture(file))
  // The normative fixtures also decode with the RPC schema.
  expect(Schema.decodeUnknownSync(LiveActivity.AgentsState)(await fixture(file))).toEqual(state)
})

test("the attributes fixture is a valid theme and the push fixtures decode their content-state", async () => {
  expect(Schema.decodeUnknownSync(LiveActivity.Attributes)(await fixture("attributes"))).toEqual(
    await fixture("attributes"),
  )
  for (const name of ["push-start", "push-update", "push-end"])
    Schema.decodeUnknownSync(LiveActivity.AgentsState)((await fixture(name)).aps["content-state"])
  const theme = (await fixture("attributes")).theme
  expect(() => Schema.decodeUnknownSync(LiveActivity.Theme)({ ...theme, accent: "#fff" })).toThrow()
  const { error: _, ...partial } = theme
  expect(() => Schema.decodeUnknownSync(LiveActivity.Theme)(partial)).toThrow()
})

test("status precedence: question beats permission, failed beats working, and child requests count for the root", async () => {
  const server = world()
  const tracker = makeTracker(server.ctx)
  await run(
    Effect.gen(function* () {
      for (const event of [
        created(ids.live, T - 10 * minute),
        execution("started", ids.live, T - 9 * minute),
        created("ses_child", T - 8 * minute, ids.live),
        execution("started", "ses_child", T - 8 * minute),
        created(ids.cache, T - 10 * minute),
        execution("started", ids.cache, T - 9 * minute),
      ])
        yield* tracker.apply(event, T)
      server.permissions.push(permission("per_1", ids.cache, T - 5 * minute, "edit", ["src/a.ts"]))
      server.forms.push(question("frm_1", ids.cache, T - 4 * minute, "Seguir?"))
      const request = permission("per_child", "ses_child", T - 3 * minute, "shell", ["rm -rf build"])
      server.permissions.push(request)
      yield* tracker.apply({ type: "permission.asked", data: request }, T)
    }),
  )
  const state = tracker.derive(T, host).state
  expect(state.counts).toEqual({ working: 0, question: 1, permission: 1, failed: 0, idle: 0, unread: 0 })
  expect(state.attention).toEqual([
    expect.objectContaining({ sessionID: ids.cache, kind: "question", since: T - 4 * minute, text: "Seguir?" }),
    expect.objectContaining({
      sessionID: ids.live,
      kind: "permission",
      since: T - 3 * minute,
      text: "shell · rm -rf build",
    }),
  ])
  expect(state.sessions.map((row) => [row.sessionID, row.status])).toEqual([
    [ids.cache, "question"],
    [ids.live, "permission"],
  ])
  expect(state.focus).toBeUndefined()
  expect(state.activeTotal).toBe(2)
  expect(state.attentionTotal).toBe(2)
})

test("a reply or cancellation clears its request although the server still lists it while publishing", async () => {
  const server = world()
  const tracker = makeTracker(server.ctx)
  const counts = () => tracker.derive(T, host).state.counts
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.cache, T - 10 * minute), T)
      yield* tracker.apply(execution("started", ids.cache, T - 9 * minute), T)
      const form = question("frm_1", ids.cache, T - 4 * minute, "Seguir?")
      server.forms.push(form)
      yield* tracker.apply({ type: "form.created", data: { form } }, T)
      expect(counts()).toMatchObject({ working: 0, question: 1 })
      // Core publishes `form.replied` before the form leaves the pending list.
      yield* tracker.apply({ type: "form.replied", data: { id: form.id } }, T)
      expect(counts()).toMatchObject({ working: 1, question: 0 })
      server.forms.splice(0)
      const request = permission("per_1", ids.cache, T - 3 * minute, "edit", ["src/a.ts"])
      server.permissions.push(request)
      yield* tracker.apply({ type: "permission.asked", data: request }, T)
      expect(counts()).toMatchObject({ working: 0, permission: 1 })
      yield* tracker.apply({ type: "permission.replied", data: { requestID: request.id } }, T)
      expect(counts()).toMatchObject({ working: 1, permission: 0 })
    }),
  )
})

test("failed lasts until a new execution, a view of that failure, archival, deletion or 24 hours", async () => {
  const tracker = makeTracker(world().ctx)
  const failedAt = T - 2 * minute
  const statusOf = (now: number) => tracker.derive(now, host).state.sessions.map((row) => [row.sessionID, row.status])
  await run(
    Effect.gen(function* () {
      for (const id of [ids.live, ids.cache, ids.oauth, ids.nav]) {
        yield* tracker.apply(created(id, T - 60 * minute), T)
        yield* tracker.apply(execution("started", id, T - 30 * minute), T)
        yield* tracker.apply(execution("failed", id, failedAt), T)
      }
      yield* tracker.apply(interruptedEvent(ids.deploy), T)
    }),
  )
  expect(tracker.derive(T, host).state.counts.failed).toBe(4)
  await run(
    Effect.gen(function* () {
      // A view of an older idle transition leaves the newer failure unread.
      yield* tracker.apply({ type: "session.viewed", created: T, data: { sessionID: ids.live, idle: failedAt - 1 } }, T)
      expect(tracker.derive(T, host).state.counts.failed).toBe(4)
      yield* tracker.apply({ type: "session.viewed", created: T, data: { sessionID: ids.live, idle: failedAt } }, T)
      yield* tracker.apply({ type: "session.archived", created: T, data: { sessionID: ids.cache } }, T)
      yield* tracker.apply({ type: "session.deleted", created: T, data: { sessionID: ids.oauth } }, T)
      yield* tracker.apply(execution("started", ids.nav, T), T)
    }),
  )
  expect(statusOf(T)).toEqual([[ids.nav, "working"]])
  await run(tracker.apply(execution("failed", ids.nav, T + minute), T + minute))
  expect(statusOf(T + 2 * minute)).toEqual([[ids.nav, "failed"]])
  expect(tracker.derive(T + 2 * minute, host).wakeAt).toBe(T + minute + limits.failedMs)
  // The failure expires; never viewed, the session is still unread, like the Sessões dot.
  expect(statusOf(T + minute + limits.failedMs)).toEqual([[ids.nav, "idle"]])
})

function interruptedEvent(sessionID: string) {
  return { type: "session.execution.interrupted" as const, created: T - minute, data: { sessionID, reason: "user" } }
}

test("a user interruption is neither failed nor idle; success stays idle for 30 minutes", async () => {
  const tracker = makeTracker(world().ctx)
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.deploy, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.deploy, T - 30 * minute), T)
      yield* tracker.apply(interruptedEvent(ids.deploy), T)
      yield* tracker.apply(created(ids.nav, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.nav, T - 30 * minute), T)
      yield* tracker.apply(execution("succeeded", ids.nav, T - minute), T)
    }),
  )
  const derived = tracker.derive(T, host)
  expect(derived.state.counts).toEqual({ working: 0, question: 0, permission: 0, failed: 0, idle: 1, unread: 1 })
  expect(derived.wakeAt).toBe(T - minute + limits.idleMs)
  expect(tracker.derive(T - minute + limits.idleMs, host).state.counts.idle).toBe(0)
})

test("focus stays on its session while it works, then moves to the most recent start", async () => {
  const tracker = makeTracker(world().ctx)
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.live, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.live, T - 10 * minute), T)
    }),
  )
  expect(tracker.derive(T, host).state.focus?.sessionID).toBe(ids.live)
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.cache, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.cache, T - 5 * minute), T)
      yield* tracker.apply(created(ids.oauth, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.oauth, T - minute), T)
    }),
  )
  // Newer executions do not steal the focus.
  expect(tracker.derive(T, host).state.focus?.sessionID).toBe(ids.live)
  await run(tracker.apply(execution("succeeded", ids.live, T), T))
  expect(tracker.derive(T, host).state.focus).toMatchObject({ sessionID: ids.oauth, startedAt: T - minute })
  // The new focus is now kept even though a later start happens.
  await run(tracker.apply(execution("started", ids.live, T + minute), T + minute))
  const state = tracker.derive(T + minute, host).state
  expect(state.focus?.sessionID).toBe(ids.oauth)
  expect(state.sessions.map((row) => row.sessionID)).toEqual([ids.oauth, ids.live, ids.cache])
})

test("progress counts subagents of the current execution only; any outcome finishes one", async () => {
  const tracker = makeTracker(world().ctx)
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.live, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.live, T - 50 * minute), T)
      yield* tracker.apply(created("ses_old", T - 45 * minute, ids.live), T)
      yield* tracker.apply(execution("succeeded", ids.live, T - 40 * minute), T)
      yield* tracker.apply(execution("started", ids.live, T - 10 * minute), T)
    }),
  )
  expect(tracker.derive(T, host).state.focus?.progress).toBeUndefined()
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created("ses_a", T - 9 * minute, ids.live), T)
      yield* tracker.apply(execution("started", "ses_a", T - 9 * minute), T)
      yield* tracker.apply(created("ses_b", T - 8 * minute, ids.live), T)
      yield* tracker.apply(execution("started", "ses_b", T - 8 * minute), T)
      yield* tracker.apply(interruptedEvent("ses_b"), T)
    }),
  )
  expect(tracker.derive(T, host).state.focus?.progress).toEqual({ done: 1, total: 2, unit: "subagents" })
  expect(tracker.derive(T, host).state.sessions[0]?.progress).toEqual({ done: 1, total: 2, unit: "subagents" })
})

test("activity text follows the contract mapping", () => {
  expect(activity("edit", { path: "/a/b/ConversationStore.swift" })).toBe("Editando ConversationStore.swift")
  expect(activity("write", { path: "notes.md" })).toBe("Editando notes.md")
  expect(activity("patch", { patchText: "*** Begin Patch\n*** Update File: src/x/App.tsx\n@@\n" })).toBe(
    "Editando App.tsx",
  )
  expect(activity("read", { path: "src/index.ts" })).toBe("Lendo index.ts")
  expect(activity("shell", { command: "bun test --filter oauth && bun run typecheck --watch false" })).toBe(
    "Rodando bun test --filter oauth && bun run typec",
  )
  expect(activity("grep", { pattern: "TODO" })).toBe("Buscando TODO")
  expect(activity("glob", { pattern: "**/*.swift" })).toBe("Buscando **/*.swift")
  expect(activity("webfetch", { url: "https://x" })).toBe("Pesquisando na web")
  expect(activity("websearch", { query: "x" })).toBe("Pesquisando na web")
  expect(activity("subagent", { agent: "explore", prompt: "x" })).toBe("Delegando para explore")
  expect(activity("question", {})).toBeUndefined()
  expect(activity("edit", {})).toBeUndefined()
  expect(clip("x".repeat(70), limits.activity)).toHaveLength(60)
})

test("reasoning, text and unknown tools replace the focus activity; a new execution clears it", async () => {
  const tracker = makeTracker(world().ctx)
  const focusActivity = () => tracker.derive(T, host).state.focus?.activity
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.live, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.live, T - 10 * minute), T)
      yield* tracker.apply({ type: "session.reasoning.started", created: T, data: { sessionID: ids.live } }, T)
    }),
  )
  expect(focusActivity()).toBe("Pensando")
  await run(tracker.apply({ type: "session.text.started", created: T, data: { sessionID: ids.live } }, T))
  expect(focusActivity()).toBe("Escrevendo resposta")
  for (const event of tool(ids.live, T, "call_1", "grep", { pattern: "LiveActivity" }))
    await run(tracker.apply(event, T))
  expect(focusActivity()).toBe("Buscando LiveActivity")
  for (const event of tool(ids.live, T, "call_2", "mcp_server_tool", {})) await run(tracker.apply(event, T))
  expect(focusActivity()).toBeUndefined()
  await run(tracker.apply({ type: "session.text.started", created: T, data: { sessionID: ids.live } }, T))
  await run(tracker.apply(execution("started", ids.live, T), T))
  expect(focusActivity()).toBeUndefined()
})

test("rows are ordered by status, oldest waits first, and cut to four; titles and texts are clipped", async () => {
  const server = world()
  const tracker = makeTracker(server.ctx)
  const long = "Uma sessão com um título realmente muito longo que passa de oitenta caracteres no total"
  await run(
    Effect.gen(function* () {
      for (const [index, id] of ["ses_q1", "ses_q2", "ses_q3", "ses_q4", "ses_p1"].entries()) {
        yield* tracker.apply(created(id, T - 60 * minute), T)
        yield* tracker.apply(execution("started", id, T - 30 * minute), T)
        if (id === "ses_p1") server.permissions.push(permission("per_x", id, T - 50 * minute, "edit", ["a.ts"]))
        else server.forms.push(question(`frm_${index}`, id, T - (10 - index) * minute, "x".repeat(200)))
      }
      yield* tracker.apply({ type: "session.renamed", created: T, data: { sessionID: "ses_q1", title: long } }, T)
      yield* tracker.apply({ type: "form.created", data: { form: server.forms[0] } }, T)
    }),
  )
  const state = tracker.derive(T, host).state
  expect(state.sessions.map((row) => row.sessionID)).toEqual(["ses_q1", "ses_q2", "ses_q3", "ses_q4"])
  // Attention mixes kinds by age: the older permission comes first.
  expect(state.attention.map((item) => item.sessionID)).toEqual(["ses_p1", "ses_q1", "ses_q2"])
  expect(state.attentionTotal).toBe(5)
  expect(state.attention[1]?.text).toHaveLength(limits.text)
  expect(state.sessions[0]?.title).toHaveLength(limits.title)
  expect(state.sessions[0]?.title.endsWith("…")).toBe(true)
})

test("the APNs body fits in 4096 bytes, trimming texts, rows, attention and then titles", () => {
  const ref = (index: number) => ({
    sessionID: `ses_${index}`.padEnd(30, "0"),
    title: "Título ".repeat(12).slice(0, 80),
    project: "projeto-com-nome-longo".repeat(2).slice(0, 40),
    directory: `/Users/alexandremartins/Worktrees/${"diretório-bem-comprido-".repeat(17)}${index}`,
  })
  const state: LiveActivity.AgentsState = {
    v: 1,
    updatedAt: T,
    host,
    counts: { working: 1, question: 3, permission: 0, failed: 0, idle: 0 },
    activeTotal: 4,
    focus: { ...ref(0), startedAt: T0, activity: "a".repeat(60), progress: { done: 1, total: 2, unit: "subagents" } },
    attention: [1, 2, 3].map((index) => ({
      ...ref(index),
      kind: "question" as const,
      since: T,
      text: "é".repeat(120),
    })),
    attentionTotal: 3,
    sessions: [1, 2, 3, 0].map((index) => ({ ...ref(index), status: "question" as const })),
  }
  const size = (value: LiveActivity.AgentsState) =>
    Buffer.byteLength(JSON.stringify(body({ event: "update", state: value, now: T })))
  expect(size(state)).toBeGreaterThan(pushLimits.bodyBytes)
  const fitted = fit({ event: "update", state, now: T })
  expect(size(fitted)).toBeLessThanOrEqual(pushLimits.bodyBytes)
  expect(fitted.attention.every((item) => item.text === undefined)).toBe(true)
  expect(fitted.sessions).toHaveLength(3)
  expect(fitted.attention).toHaveLength(2)
  expect(fitted.sessions[0]?.title.length).toBeLessThan(80)
  // A state that already fits is untouched.
  const small = { ...state, attention: state.attention.slice(0, 1), sessions: state.sessions.slice(0, 1) }
  const compact = { ...small, focus: undefined, attention: [{ ...small.attention[0], directory: "/a" }] }
  expect(fit({ event: "update", state: compact, now: T })).toEqual(compact)
})

test("rebuild restores running, waiting, failed and idle sessions without any event", async () => {
  const server = world()
  server.add(session(ids.live, { time: { created: T - 3_600_000, updated: T - minute, idle: T - 20 * minute } }))
  server.prompts.set(ids.live, T0)
  server.active.add(ids.live)
  server.add(
    session("ses_kid_1", {
      parentID: ids.live,
      time: { created: T0 + minute, updated: T0 + minute, idle: T0 + 2 * minute },
      outcome: "succeeded",
    }),
  )
  server.add(session("ses_kid_2", { parentID: ids.live, time: { created: T0 + 3 * minute, updated: T0 + 3 * minute } }))
  server.active.add("ses_kid_2")
  server.add(
    session("ses_kid_old", { parentID: ids.live, time: { created: T0 - 60 * minute, updated: T0 - 60 * minute } }),
  )
  server.add(
    session(ids.deploy, {
      outcome: "failed",
      time: { created: T - 7_200_000, updated: T - 5 * minute, idle: T - 5 * minute },
    }),
  )
  server.add(
    session(ids.nav, {
      outcome: "failed",
      time: { created: T - 7_200_000, updated: T - 5 * minute, idle: T - 5 * minute, viewed: T - 5 * minute },
    }),
  )
  server.add(
    session(ids.idleA, {
      outcome: "succeeded",
      time: { created: T - 7_200_000, updated: T - 9 * minute, idle: T - 9 * minute },
    }),
  )
  server.add(
    session(ids.idleB, {
      outcome: "succeeded",
      time: { created: T - 7_200_000, updated: T - 2 * 3_600_000, idle: T - 2 * 3_600_000 },
    }),
  )
  server.add(
    session(ids.cache, {
      outcome: "succeeded",
      time: { created: T - 7_200_000, updated: T - 2 * 3_600_000, idle: T - 2 * 3_600_000 },
    }),
  )
  server.forms.push(question("frm_old", ids.cache, T - 3 * 3_600_000, "Ainda quer isso?"))
  const tracker = makeTracker(server.ctx)
  await run(tracker.rebuild(T))
  const state = tracker.derive(T, host).state
  // idleB finished two hours ago: no longer idle, still unread.
  expect(state.counts).toEqual({ working: 1, question: 1, permission: 0, failed: 1, idle: 1, unread: 2 })
  expect(state.focus).toMatchObject({ sessionID: ids.live, startedAt: T0, progress: { done: 1, total: 2 } })
  expect(state.sessions.map((row) => [row.sessionID, row.status])).toEqual([
    [ids.cache, "question"],
    [ids.deploy, "failed"],
    [ids.live, "working"],
    [ids.idleA, "idle"],
  ])
  expect(state.attention[0]).toMatchObject({ sessionID: ids.cache, since: T - 3 * 3_600_000, text: "Ainda quer isso?" })
})

test("a parent waiting for background subagents is working until the last one ends (rev. 2026-10-27)", async () => {
  const tracker = makeTracker(world().ctx)
  const view = (now: number) => tracker.derive(now, host).state
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.live, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.live, T - 10 * minute), T)
      for (const child of ["ses_bg_a", "ses_bg_b"]) {
        yield* tracker.apply(created(child, T - 9 * minute, ids.live), T)
        yield* tracker.apply(execution("started", child, T - 9 * minute + 1), T)
      }
      // The turn that launched them ends; both keep running in the background.
      yield* tracker.apply(execution("succeeded", ids.live, T - 8 * minute), T)
    }),
  )
  expect(view(T).counts).toEqual({ working: 1, question: 0, permission: 0, failed: 0, idle: 0, unread: 0 })
  expect(view(T).activeTotal).toBe(1)
  expect(view(T).focus).toMatchObject({
    sessionID: ids.live,
    startedAt: T - 10 * minute,
    progress: { done: 0, total: 2, unit: "subagents" },
  })
  expect(view(T).sessions).toEqual([expect.objectContaining({ sessionID: ids.live, status: "working" })])
  await run(tracker.apply(execution("succeeded", "ses_bg_a", T - minute), T))
  expect(view(T).focus?.progress).toEqual({ done: 1, total: 2, unit: "subagents" })
  await run(tracker.apply(execution("failed", "ses_bg_b", T), T))
  // Nothing in the family runs any more: idle, and a subagent failure is not the parent's.
  expect(view(T).counts).toEqual({ working: 0, question: 0, permission: 0, failed: 0, idle: 1, unread: 1 })
  expect(view(T).focus).toBeUndefined()
  expect(view(T).sessions).toEqual([expect.objectContaining({ sessionID: ids.live, status: "idle" })])
})

test("a running grandchild rolls up to the top level and supplies the focus activity", async () => {
  const tracker = makeTracker(world().ctx)
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.live, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.live, T - 10 * minute), T)
      yield* tracker.apply(created("ses_child", T - 9 * minute, ids.live), T)
      yield* tracker.apply(execution("started", "ses_child", T - 9 * minute), T)
      yield* tracker.apply(created("ses_grandchild", T - 8 * minute, "ses_child"), T)
      yield* tracker.apply(execution("started", "ses_grandchild", T - 8 * minute), T)
      yield* tracker.apply(execution("succeeded", "ses_child", T - 7 * minute), T)
      yield* tracker.apply(execution("succeeded", ids.live, T - 6 * minute), T)
      for (const event of tool("ses_grandchild", T - minute, "call_read", "read", { path: "src/App.swift" }))
        yield* tracker.apply(event, T)
    }),
  )
  const state = tracker.derive(T, host).state
  expect(state.counts.working).toBe(1)
  expect(state.focus).toMatchObject({ sessionID: ids.live, startedAt: T - 10 * minute, activity: "Lendo App.swift" })
  // The parent runs again and acts later than the grandchild: its own activity wins.
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(execution("started", ids.live, T), T)
      yield* tracker.apply({ type: "session.reasoning.started", created: T + 1, data: { sessionID: ids.live } }, T)
    }),
  )
  expect(tracker.derive(T, host).state.focus).toMatchObject({ startedAt: T, activity: "Pensando" })
  // An executing child's activity wins over the parent's older one, and deleting it recomputes the family.
  for (const event of tool("ses_grandchild", T + 2, "call_grep", "grep", { pattern: "Island" }))
    await run(tracker.apply(event, T))
  expect(tracker.derive(T, host).state.focus?.activity).toBe("Buscando Island")
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(execution("succeeded", ids.live, T + minute), T)
      yield* tracker.apply({ type: "session.deleted", created: T + minute, data: { sessionID: "ses_grandchild" } }, T)
    }),
  )
  expect(tracker.derive(T + minute, host).state.counts).toEqual({
    working: 0,
    question: 0,
    permission: 0,
    failed: 0,
    idle: 1,
    unread: 1,
  })
})

test("rebuild with only subagents running maps them to their top-level sessions", async () => {
  const server = world()
  // Scroll em iOS e Android: idle top level (in the scan) with two background subagents.
  server.add(
    session(ids.live, {
      outcome: "succeeded",
      time: { created: T - 3_600_000, updated: T - 8 * minute, idle: T - 8 * minute },
    }),
  )
  server.prompts.set(ids.live, T - 20 * minute)
  for (const [index, id] of ["ses_kid_a", "ses_kid_b"].entries()) {
    server.add(session(id, { parentID: ids.live, time: { created: T - 15 * minute + index, updated: T - minute } }))
    server.prompts.set(id, T - 15 * minute + index)
    server.active.add(id)
  }
  // An old, read top level outside the 24-hour scan whose grandchild still runs; only `get` can find it.
  server.add(
    session(ids.deploy, {
      outcome: "succeeded",
      time: {
        created: T - 3 * 86_400_000,
        updated: T - 2 * 86_400_000,
        idle: T - 2 * 86_400_000,
        viewed: T - 2 * 86_400_000,
      },
    }),
  )
  server.add(session("ses_deploy_child", { parentID: ids.deploy, time: { created: T - 30 * minute, updated: T } }))
  server.add(
    session("ses_deploy_grandchild", { parentID: "ses_deploy_child", time: { created: T - 25 * minute, updated: T } }),
  )
  server.prompts.set("ses_deploy_grandchild", T - 25 * minute)
  server.active.add("ses_deploy_grandchild")
  const tracker = makeTracker(server.ctx)
  await run(tracker.rebuild(T))
  const state = tracker.derive(T, host).state
  expect(state.counts).toEqual({ working: 2, question: 0, permission: 0, failed: 0, idle: 0, unread: 0 })
  expect(state.activeTotal).toBe(2)
  expect(state.sessions.map((row) => [row.sessionID, row.status])).toEqual([
    [ids.live, "working"],
    [ids.deploy, "working"],
  ])
  // The parent's turn starts at its latest prompt; progress counts the subagents of that turn.
  expect(state.focus).toMatchObject({
    sessionID: ids.live,
    startedAt: T - 20 * minute,
    progress: { done: 0, total: 2, unit: "subagents" },
  })
  expect(server.reads).toEqual(expect.arrayContaining(["ses_deploy_child", ids.deploy]))
  // Without any known turn of its own, the top level starts with its earliest executing descendant.
  server.prompts.delete(ids.live)
  const fallback = makeTracker(server.ctx)
  await run(fallback.rebuild(T))
  expect(fallback.derive(T, host).state.focus).toMatchObject({ sessionID: ids.live, startedAt: T - 15 * minute })
})

test("each attention session maps to its oldest pending request of that kind, subagents included (watch only)", async () => {
  const server = world()
  const tracker = makeTracker(server.ctx)
  await run(
    Effect.gen(function* () {
      for (const event of [
        created(ids.live, T - 60 * minute),
        execution("started", ids.live, T - 30 * minute),
        created("ses_child", T - 20 * minute, ids.live),
        execution("started", "ses_child", T - 20 * minute),
        created(ids.cache, T - 60 * minute),
        execution("started", ids.cache, T - 30 * minute),
      ])
        yield* tracker.apply(event, T)
      server.permissions.push(permission("per_child", "ses_child", T - 10 * minute, "bash", ["ls"]))
      server.forms.push(question("frm_root", ids.live, T - 3 * minute, "Seguir?"))
      server.forms.push(question("frm_child", "ses_child", T - 5 * minute, "Qual banco?"))
      server.permissions.push(permission("per_cache", ids.cache, T - 2 * minute, "edit", ["a.ts"]))
      yield* tracker.apply({ type: "form.created", data: {} }, T)
    }),
  )
  const derived = tracker.derive(T, host)
  // A question outranks the older permission; the subagent's question is the oldest one.
  expect([...derived.requests]).toEqual([
    [ids.live, "frm_child"],
    [ids.cache, "per_cache"],
  ])
  expect(derived.state.attention.map((item) => [item.sessionID, item.kind])).toEqual([
    [ids.live, "question"],
    [ids.cache, "permission"],
  ])
  expect(JSON.stringify(derived.state)).not.toContain("requestID")
})

test("an idle session with a background shell is working until the shell ends (rev. 2026-10-28)", async () => {
  const tracker = makeTracker(world().ctx)
  const view = (now: number) => tracker.derive(now, host).state
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.live, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.live, T - 10 * minute), T)
      yield* tracker.apply(shellStarted(ids.live, "sh_tests", T - 9 * minute, "bun test --filter oauth"), T)
      // The turn that moved the command to the background ends; the job keeps running.
      yield* tracker.apply(execution("succeeded", ids.live, T - 8 * minute), T)
    }),
  )
  expect(view(T).counts).toEqual({ working: 1, question: 0, permission: 0, failed: 0, idle: 0, unread: 0 })
  expect(view(T).focus).toMatchObject({
    sessionID: ids.live,
    startedAt: T - 10 * minute,
    activity: "Rodando bun test --filter oauth",
  })
  // A background shell of a subagent rolls up the same way.
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.cache, T - 60 * minute), T)
      yield* tracker.apply(created("ses_cache_child", T - 30 * minute, ids.cache), T)
      yield* tracker.apply(shellStarted("ses_cache_child", "sh_dev", T - 20 * minute, "bun run dev"), T)
    }),
  )
  expect(view(T).counts.working).toBe(2)
  expect(view(T).sessions.find((row) => row.sessionID === ids.cache)).toMatchObject({ status: "working" })
  // The job ends: nothing runs, so the session is idle until its completion notice wakes it again.
  await run(tracker.apply(shellExited("sh_tests", T - minute), T))
  expect(view(T).sessions.find((row) => row.sessionID === ids.live)).toMatchObject({ status: "idle" })
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(shellNotice(ids.live, "sh_tests", T), T)
      yield* tracker.apply(execution("started", ids.live, T), T)
    }),
  )
  expect(view(T).sessions.find((row) => row.sessionID === ids.live)).toMatchObject({ status: "working" })
  await run(tracker.apply(execution("succeeded", ids.live, T + minute), T))
  expect(view(T + minute).sessions.find((row) => row.sessionID === ids.live)).toMatchObject({ status: "idle" })
  // A completion notice alone also settles a shell whose exit was missed.
  await run(tracker.apply(shellNotice("ses_cache_child", "sh_dev", T + minute), T))
  expect(view(T + minute).counts.working).toBe(0)
})

test("rebuild finds unfinished background shells in the transcripts", async () => {
  const server = world()
  server.add(
    session(ids.live, {
      outcome: "succeeded",
      time: { created: T - 3_600_000, updated: T - 5 * minute, idle: T - 5 * minute },
    }),
  )
  server.prompts.set(ids.live, T - 12 * minute)
  // Newest first, as `message.list` returns them: sh_old finished (its notice is there), sh_watch did not.
  server.transcripts.set(ids.live, [
    shellNoticeMessage("msg_notice", "sh_old", T - 6 * minute),
    backgroundShellMessage("msg_watch", "sh_watch", T - 10 * minute, "bun test --watch"),
    backgroundShellMessage("msg_old", "sh_old", T - 11 * minute, "bun run build"),
  ])
  server.add(
    session(ids.nav, {
      outcome: "succeeded",
      time: { created: T - 3_600_000, updated: T - 5 * minute, idle: T - 5 * minute },
    }),
  )
  server.transcripts.set(ids.nav, [
    shellNoticeMessage("msg_nav_notice", "sh_nav", T - 6 * minute),
    backgroundShellMessage("msg_nav", "sh_nav", T - 20 * minute, "bun run lint"),
  ])
  const tracker = makeTracker(server.ctx)
  await run(tracker.rebuild(T))
  const state = tracker.derive(T, host).state
  expect(state.counts).toEqual({ working: 1, question: 0, permission: 0, failed: 0, idle: 1, unread: 1 })
  // The waiting turn started at the latest prompt.
  expect(state.focus).toMatchObject({
    sessionID: ids.live,
    startedAt: T - 12 * minute,
    activity: "Rodando bun test --watch",
  })
  await run(tracker.apply(shellExited("sh_watch", T), T))
  expect(tracker.derive(T, host).state.counts).toEqual({
    working: 0,
    question: 0,
    permission: 0,
    failed: 0,
    idle: 2,
    unread: 2,
  })
})

test("unread follows the Sessões dot: newer output than the viewed watermark (rev. 2026-10-28)", async () => {
  const server = world()
  const tracker = makeTracker(server.ctx)
  const view = (now = T) => tracker.derive(now, host).state
  const rows = (now = T) => view(now).sessions.map((row) => [row.sessionID, row.status])
  await run(
    Effect.gen(function* () {
      for (const [id, end] of [
        [ids.live, T - 5 * minute],
        [ids.nav, T - 3 * minute],
        [ids.cache, T - 2 * 60 * minute],
      ] as const) {
        yield* tracker.apply(created(id, end - 30 * minute), T)
        yield* tracker.apply(execution("started", id, end - 10 * minute), T)
        yield* tracker.apply(execution("succeeded", id, end), T)
      }
      // Interrupted without a newer success: nothing new to read.
      yield* tracker.apply(created(ids.deploy, T - 60 * minute), T)
      yield* tracker.apply(execution("started", ids.deploy, T - 10 * minute), T)
      yield* tracker.apply(interruptedEvent(ids.deploy), T)
    }),
  )
  // Idle keeps its 30-minute meaning; unread has no window, and only unread sessions are rows, newest first.
  expect(view().counts).toMatchObject({ idle: 2, unread: 3 })
  expect(rows()).toEqual([
    [ids.nav, "idle"],
    [ids.live, "idle"],
    [ids.cache, "idle"],
  ])
  await run(
    Effect.gen(function* () {
      // A stale view (an older idle watermark) leaves it unread; viewing the latest output reads it.
      yield* tracker.apply(
        { type: "session.viewed", created: T, data: { sessionID: ids.nav, idle: T - 10 * minute } },
        T,
      )
      yield* tracker.apply(
        { type: "session.viewed", created: T, data: { sessionID: ids.live, idle: T - 5 * minute } },
        T,
      )
    }),
  )
  expect(view().counts).toMatchObject({ idle: 2, unread: 2 })
  expect(rows()).toEqual([
    [ids.nav, "idle"],
    [ids.cache, "idle"],
  ])
  // "Avisar ao terminar" (which replaced muting) never hides an unread session.
  server.watched.add(ids.cache)
  await run(tracker.apply({ type: "preferences.updated" }, T))
  expect(view().counts).toMatchObject({ unread: 2 })
  expect(rows()).toEqual([
    [ids.nav, "idle"],
    [ids.cache, "idle"],
  ])
  // A new execution makes it working; its end is unread again even though it was viewed before.
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(execution("started", ids.live, T), T)
      yield* tracker.apply(execution("succeeded", ids.live, T + minute), T)
    }),
  )
  expect(view(T + minute).counts).toMatchObject({ unread: 3 })
  // An interruption after an unread success keeps the session unread.
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(execution("started", ids.nav, T + minute), T)
      yield* tracker.apply(
        {
          type: "session.execution.interrupted",
          created: T + 2 * minute,
          data: { sessionID: ids.nav, reason: "user" },
        },
        T,
      )
    }),
  )
  expect(view(T + 2 * minute).sessions.map((row) => row.sessionID)).toContain(ids.nav)
  // Unread sessions do not keep the activity alive: nothing active, nothing failed.
  expect(view(T + 2 * minute).activeTotal).toBe(0)
})

test("rebuild keeps unread sessions of any age and drops read ones", async () => {
  const server = world()
  const old = { created: T - 5 * 86_400_000, updated: T - 3 * 86_400_000, idle: T - 3 * 86_400_000 }
  server.add(session(ids.live, { outcome: "succeeded", time: old }))
  server.add(session(ids.nav, { outcome: "succeeded", time: { ...old, viewed: old.idle } }))
  server.add(session(ids.cache, { outcome: "interrupted", time: old }))
  server.add(session(ids.oauth, { outcome: "succeeded", time: old }))
  const tracker = makeTracker(server.ctx)
  await run(tracker.rebuild(T))
  const state = tracker.derive(T, host).state
  expect(state.counts).toEqual({ working: 0, question: 0, permission: 0, failed: 0, idle: 0, unread: 2 })
  expect(state.sessions.map((row) => row.sessionID).toSorted()).toEqual([ids.live, ids.oauth].toSorted())
  expect([...tracker.sessions.keys()]).toEqual([ids.live, ids.oauth])
})

test("needs list what Sessões lists in Precisa de você: working outranks a failure, the Sessão mestra is never unread (rev. 2026-10-29)", async () => {
  const server = world()
  const tracker = makeTracker(server.ctx)
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.cache, T - 30 * minute), T)
      yield* tracker.apply(execution("started", ids.cache, T - 9 * minute), T)
      const form = question("frm_1", ids.cache, T - 4 * minute, "Seguir?")
      server.forms.push(form)
      yield* tracker.apply({ type: "form.created", data: { form } }, T)
      for (const [id, outcome, end] of [
        [ids.oauth, "failed", T - 6 * minute],
        [ids.nav, "succeeded", T - 3 * minute],
        [ids.live, "succeeded", T - minute],
      ] as const) {
        yield* tracker.apply(created(id, end - 30 * minute), T)
        yield* tracker.apply(execution("started", id, end - 10 * minute), T)
        yield* tracker.apply(execution(outcome, id, end), T)
      }
      // A failure whose background shell still runs stays working, like its Sessões row.
      yield* tracker.apply(created(ids.deploy, T - 30 * minute), T)
      yield* tracker.apply(execution("started", ids.deploy, T - 20 * minute), T)
      yield* tracker.apply(shellStarted(ids.deploy, "sh_dev", T - 15 * minute, "bun run dev"), T)
      yield* tracker.apply(execution("failed", ids.deploy, T - 2 * minute), T)
      server.settings.master = ids.live
      yield* tracker.apply({ type: "preferences.updated" }, T)
    }),
  )
  const state = tracker.derive(T, host).state
  expect(state.counts).toEqual({ working: 1, question: 1, permission: 0, failed: 1, idle: 2, unread: 1 })
  expect(state.needs?.map((need) => [need.sessionID, need.kind, need.since])).toEqual([
    [ids.cache, "question", T - 4 * minute],
    [ids.oauth, "failed", T - 6 * minute],
    [ids.nav, "unread", T - 3 * minute],
  ])
  expect(state.sessions.find((row) => row.sessionID === ids.deploy)?.status).toBe("working")
  expect(state.sessions.some((row) => row.sessionID === ids.live)).toBe(false)
  expect(Schema.decodeUnknownSync(LiveActivity.AgentsState)(state)).toEqual(state)
})
