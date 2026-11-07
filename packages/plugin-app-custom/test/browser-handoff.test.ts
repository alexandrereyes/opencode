import { expect, test } from "bun:test"
import { Effect, Exit, Schema, Scope } from "effect"
import { Session } from "@opencode/schema/session"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { detect, handoffMessage, maxMessage, messages } from "../src/browser-handoff/detect"
import { makeHandoffs } from "../src/browser-handoff/index"
import { makeRegistry, wire } from "../src/browser-handoff/registry"
import { BrowserHandoffs } from "../src/browser-handoff/rpc"
import { LiveActivity } from "../src/live-activity/rpc"
import { makeTracker } from "../src/live-activity/tracker"
import { makeRegistry as makeActivities } from "../src/live-activity/lifecycle"
import { makeNotificationRegistry, makeNotifier } from "../src/notifications/index"
import type { Push } from "../src/live-activity/apns"
import { list } from "../src/navigation"
import { snapshot } from "../src/session-family"
import { Family } from "../src/session-family/rpc"
import { T, created, execution, ids, minute, question, world } from "./fixture/live-activity"
import { storage } from "./fixture/storage"

const host = "MacBook Pro"
const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect)

test("the message is the first handoff() or demonstrate() literal; other code cannot hand off", () => {
  expect(handoffMessage(`await handoff("Faça login no GitHub e clique em Continue")`)).toBe(
    "Faça login no GitHub e clique em Continue",
  )
  expect(handoffMessage(`await handoff('Aprove o 2FA', { timeoutMs: 600_000, start: () => go() })`)).toBe(
    "Aprove o 2FA",
  )
  expect(handoffMessage("await handoff(`Resolva o captcha em ${origin}`)")).toBe("Resolva o captcha em …")
  expect(handoffMessage(`await handoff("Diga \\"ok\\"\\nentão siga")`)).toBe('Diga "ok" então siga')
  expect(handoffMessage(`await handoff()`)).toBe(messages.handoff)
  expect(handoffMessage(`await handoff(message)`)).toBe(messages.handoff)
  expect(handoffMessage(`await demonstrate()`)).toBe(messages.demonstrate)
  expect(handoffMessage(`await handoff(\n  "Confirme o pagamento"\n)`)).toBe("Confirme o pagamento")
  expect(Array.from(handoffMessage(`handoff("${"a".repeat(300)}")`) ?? "")).toHaveLength(maxMessage)
  // Code that only mentions it, or calls something else, is no handoff.
  expect(handoffMessage(`await page.goto("https://example.com"); return page.title()`)).toBeUndefined()
  expect(handoffMessage(`// handoff("só um comentário")\nreturn 1`)).toBeUndefined()
  expect(handoffMessage(`/* handoff("bloco") */ return 1`)).toBeUndefined()
  expect(handoffMessage(`const handoffs = 1; return handoffs`)).toBeUndefined()
  expect(handoffMessage(`await page.goto("https://a.b/c"); await handoff("Entre")`)).toBe("Entre")
  // Only browse's execute, as Code Mode's inner call or its dotted path.
  expect(detect("browse_execute", { code: `await handoff("x")` })).toBe("x")
  expect(detect("browse.execute", { code: `await handoff("x")` })).toBe("x")
  expect(detect("shell", { command: `handoff("x")` })).toBeUndefined()
  expect(detect("browse_status", { code: `handoff("x")` })).toBeUndefined()
  expect(detect("browse_execute", undefined)).toBeUndefined()
})

/** One Location's handoffs over a shared registry, with a short grace period on the real clock. */
async function location(registry = makeRegistry(), graceMs = 30) {
  const scope = await run(Scope.make())
  const announced: string[] = []
  const handoffs = makeHandoffs({
    registry,
    scope,
    graceMs,
    now: () => T,
    announce: (sessionID) => Effect.sync(() => void announced.push(sessionID)),
  })
  return { registry, handoffs, announced, close: () => run(Scope.close(scope, Exit.void)), graceMs }
}

const call = (sessionID: string, id: string, code: string) => ({
  tool: "browse_execute",
  sessionID,
  messageID: "msg_1",
  id,
  input: { code },
})

test("a handoff call waits only after the grace period; its end, by hook or by event, clears it once", async () => {
  const { registry, handoffs, announced, close, graceMs } = await location()
  const first = call(ids.live, "call_1", `await handoff("Faça login")`)
  await run(handoffs.before(first))
  // Other browse code and other tools are never recorded.
  await run(handoffs.before(call(ids.live, "call_2", `return page.title()`)))
  await run(handoffs.before({ ...first, tool: "shell", id: "call_3" }))
  expect(registry.waiting()).toEqual([])
  await Bun.sleep(graceMs * 3)
  expect(registry.waiting().map(wire)).toEqual([
    {
      id: expect.stringMatching(/^brw_/),
      sessionID: ids.live,
      callID: "call_1",
      messageID: "msg_1",
      message: "Faça login",
      since: T,
    },
  ])
  expect(Schema.decodeUnknownSync(BrowserHandoffs.Handoff)(wire(registry.waiting()[0]!))).toBeDefined()
  expect(announced).toEqual([ids.live])
  // The call ends: `execute.after` gets the same input object.
  await run(handoffs.after({ ...first, status: "completed" }))
  expect(registry.waiting()).toEqual([])
  expect(announced).toEqual([ids.live, ids.live])

  // A call that ends inside the grace period never shows nor announces.
  const quick = call(ids.live, "call_4", `await handoff("Rápido")`)
  await run(handoffs.before(quick))
  await run(handoffs.after({ ...quick, status: "error" }))
  await Bun.sleep(graceMs * 3)
  expect(registry.waiting()).toEqual([])
  expect(announced).toHaveLength(2)

  // An interruption skips `execute.after`: the session's end clears its calls.
  await run(handoffs.before(call(ids.cache, "call_5", `await handoff("A")`)))
  await run(handoffs.before(call(ids.cache, "call_6", `await demonstrate()`)))
  await Bun.sleep(graceMs * 3)
  expect(registry.waiting().map((entry) => entry.message)).toEqual(["A", messages.demonstrate])
  await run(handoffs.ended({ type: "session.execution.interrupted", data: { sessionID: ids.cache } }))
  expect(registry.waiting()).toEqual([])
  expect(announced).toEqual([ids.live, ids.live, ids.cache, ids.cache, ids.cache])

  // Code Mode's execute ending (its program interrupted the pending call) clears only that tool part.
  await run(handoffs.before(call(ids.oauth, "call_7", `await handoff("B")`)))
  await run(handoffs.before(call(ids.oauth, "call_8", `await handoff("C")`)))
  await Bun.sleep(graceMs * 3)
  await run(handoffs.ended({ type: "session.tool.success", data: { sessionID: ids.oauth, id: "call_7" } }))
  expect(registry.waiting().map((entry) => entry.callID)).toEqual(["call_8"])
  await run(handoffs.ended({ type: "session.deleted", data: { sessionID: ids.oauth } }))
  expect(registry.waiting()).toEqual([])
  await close()
})

test("a replaced input still ends its call; another Location never settles or announces it", async () => {
  const registry = makeRegistry()
  const a = await location(registry)
  const b = await location(registry)
  const first = call(ids.live, "call_1", `await handoff("Entrar")`)
  await run(a.handoffs.before(first))
  await Bun.sleep(a.graceMs * 3)
  await run(b.handoffs.ended({ type: "session.execution.failed", data: { sessionID: ids.live } }))
  await run(b.handoffs.after({ ...first, input: { ...first.input }, status: "completed" }))
  expect(registry.waiting()).toHaveLength(1)
  expect(b.announced).toEqual([])
  // Another hook replaced the input object: the same code in the same tool part matches.
  await run(a.handoffs.after({ ...first, input: { code: first.input.code }, status: "completed" }))
  expect(registry.waiting()).toEqual([])
  expect(a.announced).toEqual([ids.live, ids.live])
  // The registry wakes its listeners on every change of the waiting list.
  let wakes = 0
  const stop = registry.listen(() => void wakes++)
  await run(a.handoffs.before(call(ids.live, "call_2", `await handoff("x")`)))
  await Bun.sleep(a.graceMs * 3)
  await run(a.handoffs.ended({ type: "session.execution.succeeded", data: { sessionID: ids.live } }))
  stop()
  expect(wakes).toBe(2)
  await a.close()
  await b.close()
})

test("the Live Activity rolls a handoff up to its root as attention of kind browser, after questions and permissions", async () => {
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
    }),
  )
  expect(tracker.derive(T, host).state.counts).toEqual({
    working: 2,
    question: 0,
    permission: 0,
    failed: 0,
    idle: 0,
    unread: 0,
  })
  server.handoffs.push({ id: "brw_1", sessionID: "ses_child", since: T - 2 * minute, message: "Faça login no GitHub" })
  await run(tracker.refreshHandoffs())
  const derived = tracker.derive(T, host)
  const state = derived.state
  expect(Schema.decodeUnknownSync(LiveActivity.AgentsState)(state)).toEqual(state)
  expect(state.counts).toEqual({ working: 1, question: 0, permission: 0, failed: 0, idle: 0, unread: 0, browser: 1 })
  expect(state.activeTotal).toBe(2)
  expect(state.attentionTotal).toBe(1)
  expect(state.attention).toEqual([
    expect.objectContaining({
      sessionID: ids.live,
      kind: "browser",
      since: T - 2 * minute,
      text: "Faça login no GitHub",
    }),
  ])
  expect(state.sessions.map((row) => [row.sessionID, row.status])).toEqual([
    [ids.live, "browser"],
    [ids.cache, "working"],
  ])
  expect(state.needs).toEqual([
    expect.objectContaining({ sessionID: ids.live, kind: "browser", since: T - 2 * minute }),
  ])
  expect(derived.marks.get(`browser:${ids.live}`)?.title).toBe("Navegador aguardando")
  expect(derived.pending).toEqual([expect.objectContaining({ id: "brw_1", kind: "browser" })])
  // The watch answers questions and permissions only: no request to open for a handoff.
  expect(derived.requests.has(ids.live)).toBe(false)
  // A question of the same family outranks the handoff.
  const form = question("frm_1", ids.live, T - minute, "Seguir?")
  server.forms.push(form)
  await run(tracker.apply({ type: "form.created", data: { form } }, T))
  const asked = tracker.derive(T, host).state
  expect(asked.sessions[0]).toMatchObject({ sessionID: ids.live, status: "question" })
  expect(asked.counts.browser).toBeUndefined()
  expect(tracker.derive(T, host).requests.get(ids.live)).toBe("frm_1")
})

test("a waiting handoff alerts once, collapsed per session, without a request to open", async () => {
  const server = world()
  const tracker = makeTracker(server.ctx)
  const shared = storage()
  const registry = makeNotificationRegistry(shared)
  const pushes: Push[] = []
  const notifier = makeNotifier({
    registry,
    activities: makeActivities(shared),
    send: (push) => Effect.sync(() => (pushes.push(push), { status: "sent" as const })),
  })
  const step = (at: number) =>
    Effect.gen(function* () {
      yield* tracker.refreshHandoffs()
      const derived = tracker.derive(at, host)
      const plan = yield* notifier.evaluate(derived, at, derived.state)
      yield* plan.deliver
    })
  await run(
    Effect.gen(function* () {
      yield* registry.register(
        { deviceID: "iphone", serverKey: "mac-principal", environment: "production", token: "aa11" },
        T,
      )
      yield* tracker.apply(created(ids.live, T - minute), T)
      yield* tracker.apply(execution("started", ids.live, T), T)
      yield* step(T)
      server.handoffs.push({ id: "brw_1", sessionID: ids.live, since: T, message: "Faça login no GitHub" })
      yield* step(T + 3_000)
      yield* step(T + 60_000)
    }),
  )
  expect(pushes).toHaveLength(1)
  expect(pushes[0]?.collapseID).toBe(`attention:${ids.live}`)
  const body = pushes[0]?.body as { aps: { alert: { body: string } }; opencode: Record<string, unknown> }
  expect(body.aps.alert.body).toBe("Navegador: Faça login no GitHub")
  expect(body.opencode).toMatchObject({ kind: "session.attention", sessionID: ids.live, attention: "browser" })
  expect("requestID" in body.opencode).toBe(false)
})

const decodeSession = Schema.decodeUnknownSync(Session.Info)
const info = (id: string, parentID?: string) =>
  decodeSession({
    id,
    ...(parentID ? { parentID } : {}),
    projectID: Project.ID.global,
    location: { directory: AbsolutePath.make("/repo") },
    title: id,
    time: { created: 1, updated: 2 },
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  })

test("Sessões and the session family carry the waiting handoffs", async () => {
  const root = info("ses_root")
  const child = info("ses_child", root.id)
  const other = info("ses_other")
  const handoffs: BrowserHandoffs.Handoff[] = [
    { id: "brw_1", sessionID: child.id, callID: "call_1", messageID: "msg_1", message: "Antigo", since: 10 },
    { id: "brw_2", sessionID: child.id, callID: "call_2", messageID: "msg_2", message: "Novo", since: 20 },
    { id: "brw_3", sessionID: root.id, callID: "call_3", messageID: "msg_3", message: "Raiz", since: 30 },
    { id: "brw_4", sessionID: other.id, callID: "call_4", messageID: "msg_4", message: "Outra", since: 5 },
  ]
  const page = await run(
    list(
      {
        scan: () => Effect.succeed({ data: [{ session: root }, { session: child }] }),
        pending: () => Effect.succeed([]),
        background: () => Effect.succeed([]),
        active: () => Effect.succeed({}),
        handoffs: () => handoffs,
      },
      {},
    ),
  )
  expect(page.data.map((row) => [row.session.id, row.browserAt, row.browserCount, row.browserText])).toEqual([
    [root.id, 30, 1, "Raiz"],
    [child.id, 20, 2, "Novo"],
  ])
  const family = await run(
    snapshot(
      {
        family: () => Effect.succeed({ count: 1, cost: 0, data: [], active: [child] }),
        get: ({ sessionID }) => {
          const found = [root, child, other].find((session) => session.id === sessionID)
          return found ? Effect.succeed(found) : Effect.fail(new Error("missing"))
        },
        pending: () => Effect.succeed([]),
        handoffs: () => handoffs,
      },
      root.id,
    ),
  )
  // The root's own first, then its descendants, oldest first; another family's never.
  expect(family.browser?.map((item) => item.id)).toEqual(["brw_3", "brw_1", "brw_2"])
  expect(Schema.decodeUnknownSync(Family.Snapshot)(family).browser?.[0]?.message).toBe("Raiz")
  const none = await run(
    snapshot(
      {
        family: () => Effect.succeed({ count: 0, cost: 0, data: [], active: [] }),
        get: () => Effect.succeed(root),
        pending: () => Effect.succeed([]),
        handoffs: () => [],
      },
      root.id,
    ),
  )
  expect("browser" in none).toBe(false)
})
