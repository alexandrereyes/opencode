import { expect, test } from "bun:test"
import { Effect, Exit, Schema, Scope } from "effect"
import { Session } from "@opencode/schema/session"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { detect, handoffMessage, maxMessage, messages } from "../src/browser-handoff/detect"
import {
  afterOutcome,
  browseSession,
  capabilities,
  endedOutcome,
  hubResources,
  makeHandoffs,
  type HandoffResources,
} from "../src/browser-handoff/index"
import { makeRegistry, wire } from "../src/browser-handoff/registry"
import { BrowserHandoffs } from "../src/browser-handoff/rpc"
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
  // Each waiting handoff that ends is announced on its own (with `ended`, see the resource tests below).
  expect(announced).toEqual([ids.live, ids.live, ids.cache, ids.cache, ids.cache, ids.cache])

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

test("a handoff ranks after questions, marks the activity urgent and gives the watch no request", async () => {
  // Its place in the state is the normative `state-browser.json` (live-activity.test.ts).
  const server = world()
  const tracker = makeTracker(server.ctx)
  await run(
    Effect.gen(function* () {
      yield* tracker.apply(created(ids.live, T - 10 * minute), T)
      yield* tracker.apply(execution("started", ids.live, T - 9 * minute), T)
    }),
  )
  server.handoffs.push({ id: "brw_1", sessionID: ids.live, since: T - 2 * minute, message: "Faça login" })
  const waiting = tracker.derive(T, host)
  expect(waiting.marks.get(`browser:${ids.live}`)?.title).toBe("Navegador aguardando")
  expect(waiting.pending).toEqual([expect.objectContaining({ id: "brw_1", kind: "browser" })])
  expect(waiting.requests.has(ids.live)).toBe(false)
  const form = question("frm_1", ids.live, T - minute, "Seguir?")
  server.forms.push(form)
  await run(tracker.apply({ type: "form.created", data: { form } }, T))
  const asked = tracker.derive(T, host)
  expect(asked.state.sessions[0]).toMatchObject({ sessionID: ids.live, status: "question" })
  expect(asked.state.counts.browser).toBeUndefined()
  expect(asked.requests.get(ids.live)).toBe("frm_1")
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

/** A Location whose handoffs get resources from a fake hub that logs every step in order. */
async function withResources(options: { readonly openMs?: number; readonly refuse?: boolean } = {}) {
  const registry = makeRegistry()
  const scope = await run(Scope.make())
  const log: string[] = []
  const endings: BrowserHandoffs.Changed[] = []
  const resources: HandoffResources = {
    open: (handoff) =>
      Effect.promise(async () => {
        log.push(`open ${handoff.browse} ${handoff.agent ?? "-"}`)
        await Bun.sleep(options.openMs ?? 0)
        return options.refuse ? undefined : `chrome:browse:${handoff.browse}`
      }),
    close: (resourceID, outcome) => Effect.sync(() => void log.push(`end ${resourceID} ${outcome}`)),
    announce: (resourceID) => Effect.sync(() => void log.push(`resources.changed ${resourceID}`)),
  }
  const handoffs = makeHandoffs({
    registry,
    scope,
    graceMs: 30,
    now: () => T,
    resources,
    announce: (sessionID, ended) =>
      Effect.sync(() => {
        log.push(`browser-handoffs.changed ${sessionID}${ended ? ` ${ended.outcome}` : ""}`)
        endings.push({ sessionID, ...(ended ? { ended } : {}) })
      }),
  })
  return { registry, handoffs, log, endings, close: () => run(Scope.close(scope, Exit.void)) }
}

const browseCall = (id: string, session?: string, sessionID = ids.live) => ({
  ...call(sessionID, id, `await handoff("Entre com a senha")`),
  input: { code: `await handoff("Entre com a senha")`, ...(session ? { session } : {}) },
  agent: "build",
})

test("a handoff that names its browse session waits with its resource and ends in the contract's order", async () => {
  const { registry, handoffs, log, endings, close } = await withResources({ openMs: 20 })
  const first = browseCall("call_1", "login")
  await run(handoffs.before(first))
  // Within the grace period nothing exists yet, not even the resource.
  expect(log).toEqual([])
  await Bun.sleep(120)
  const waiting = registry.waiting()
  expect(waiting.map((entry) => entry.resourceID)).toEqual(["chrome:browse:login"])
  expect(wire(waiting[0]!).resourceID).toBe("chrome:browse:login")
  // The resource exists before anyone hears the handoff waits, so every surface gets its `resourceID` at once.
  expect(log).toEqual(["open login build", `browser-handoffs.changed ${ids.live}`])

  await run(
    handoffs.after({
      ...first,
      status: "error",
      error: { message: "Handoff timed out after 100ms waiting for the user: Entre com a senha" },
    }),
  )
  expect(registry.waiting()).toEqual([])
  // Its viewers end first, then the handoff's change with `ended`, then the resources' change.
  expect(log.slice(2)).toEqual([
    "end chrome:browse:login timeout",
    `browser-handoffs.changed ${ids.live} timeout`,
    "resources.changed chrome:browse:login",
  ])
  expect(endings.at(-1)).toEqual({
    sessionID: ids.live,
    ended: { id: waiting[0]!.id, resourceID: "chrome:browse:login", outcome: "timeout" },
  })
  expect(Schema.decodeUnknownSync(BrowserHandoffs.Changed)(endings.at(-1))).toEqual(endings.at(-1)!)
  await close()
})

test("each way a handoff ends has its outcome, and calls without a session or a relay get no resource", async () => {
  const { registry, handoffs, log, endings, close } = await withResources()
  const outcome = async (id: string, finish: () => Promise<unknown>) => {
    await run(handoffs.before(browseCall(id, `s-${id}`)))
    await Bun.sleep(100)
    expect(registry.waiting().at(-1)?.resourceID).toBe(`chrome:browse:s-${id}`)
    await finish()
    return endings.at(-1)?.ended?.outcome
  }
  expect(await outcome("c1", () => run(handoffs.after({ ...browseCall("c1", "s-c1"), status: "completed" })))).toBe(
    "completed",
  )
  expect(
    await outcome("c2", () =>
      run(handoffs.after({ ...browseCall("c2", "s-c2"), status: "error", error: { message: "Tab closed" } })),
    ),
  ).toBe("failed")
  expect(
    await outcome("c3", () =>
      run(handoffs.ended({ type: "session.execution.interrupted", data: { sessionID: ids.live } })),
    ),
  ).toBe("cancelled")
  expect(
    await outcome("c4", () =>
      run(handoffs.ended({ type: "session.tool.failed", data: { sessionID: ids.live, id: "c4" } })),
    ),
  ).toBe("cancelled")
  expect(await outcome("c5", () => run(handoffs.unload))).toBe("cancelled")

  // No `session`: it still waits and is still announced, without a resource.
  log.length = 0
  await run(handoffs.before(browseCall("c6")))
  await Bun.sleep(100)
  expect(registry.waiting().map((entry) => entry.resourceID)).toEqual([undefined])
  await run(handoffs.after({ ...browseCall("c6"), status: "completed" }))
  expect(log).toEqual([`browser-handoffs.changed ${ids.live}`, `browser-handoffs.changed ${ids.live} completed`])
  expect(endings.at(-1)?.ended).toEqual({ id: expect.any(String), outcome: "completed" })
  await close()

  // The relay (or an older hub) gives none: the same, and nothing to end.
  const refused = await withResources({ refuse: true })
  await run(refused.handoffs.before(browseCall("c7", "login")))
  await Bun.sleep(100)
  expect(refused.registry.waiting().map((entry) => entry.resourceID)).toEqual([undefined])
  await run(refused.handoffs.after({ ...browseCall("c7", "login"), status: "completed" }))
  expect(refused.log).toEqual([
    "open login build",
    `browser-handoffs.changed ${ids.live}`,
    `browser-handoffs.changed ${ids.live} completed`,
  ])
  await refused.close()
})

test("a call that ends while its resource is being registered never waits and its resource goes quietly", async () => {
  const { registry, handoffs, log, close } = await withResources({ openMs: 80 })
  await run(handoffs.before(browseCall("call_1", "login")))
  await Bun.sleep(50)
  expect(log).toEqual(["open login build"])
  await run(handoffs.after({ ...browseCall("call_1", "login"), status: "completed" }))
  await Bun.sleep(120)
  expect(registry.waiting()).toEqual([])
  expect(log).toEqual([
    "open login build",
    "end chrome:browse:login completed",
    "resources.changed chrome:browse:login",
  ])
  await close()
})

test("outcomes, the browse session and the hub port", async () => {
  const base = browseCall("x", "login")
  expect(afterOutcome({ ...base, status: "completed" })).toBe("completed")
  expect(afterOutcome({ ...base, status: "error", error: { message: "Handoff timed out after 5000ms waiting" } })).toBe(
    "timeout",
  )
  expect(afterOutcome({ ...base, status: "error", error: { message: "The operation was aborted" } })).toBe("cancelled")
  expect(afterOutcome({ ...base, status: "error", error: { message: "Target closed" } })).toBe("failed")
  expect(afterOutcome({ ...base, status: "error" })).toBe("failed")
  expect(endedOutcome({ type: "session.archived", data: { sessionID: "s" } })).toBe("cancelled")
  expect(endedOutcome({ type: "session.deleted", data: { sessionID: "s" } })).toBe("cancelled")
  expect(endedOutcome({ type: "session.execution.failed", data: { sessionID: "s" } })).toBe("failed")
  expect(endedOutcome({ type: "session.tool.success", data: { sessionID: "s", id: "c" } })).toBe("completed")
  expect(browseSession({ code: "x", session: "login" })).toBe("login")
  expect(browseSession({ code: "x", session: "" })).toBeUndefined()
  expect(browseSession({ code: "x" })).toBeUndefined()
})

test("the hub port registers the locked resource, refuses one an older hub returns without locks, and ends it", async () => {
  const calls: unknown[] = []
  const resource = (extra: object) => ({ id: "chrome:browse:login", kind: "chrome", ...extra }) as never
  const hub = (answer: object) => ({
    upsert: async (input: unknown) => {
      calls.push(["upsert", input])
      return resource(answer)
    },
    remove: async (id: string) => {
      calls.push(["remove", id])
      return {}
    },
    finish: async (id: string, reason: string) => void calls.push(["finish", id, reason]),
    announce: async (ids: readonly string[]) => void calls.push(["announce", ids]),
  })
  const handoff = { id: "brw_1", sessionID: "ses_child", message: "Entre", since: 5, browse: "login", agent: "build" }
  const root = () => Effect.succeed("ses_root")
  const locked = hubResources(hub({ capabilities, handoff: { id: "brw_1" } }), root)
  expect(await run(locked.open(handoff))).toBe("chrome:browse:login")
  expect(calls[0]).toEqual([
    "upsert",
    {
      kind: "chrome",
      meta: { kind: "chrome", cdp: "http://127.0.0.1:19988", browse: "login" },
      purpose: "Entre",
      owner: { sessionID: "ses_child", rootSessionID: "ses_root", agent: "build" },
      used: true,
      capabilities: { navigation: false, tabs: false, focus: true },
      handoff: { id: "brw_1", sessionID: "ses_child", message: "Entre", since: 5 },
    },
  ])
  await run(locked.close("chrome:browse:login", "cancelled"))
  await run(locked.announce("chrome:browse:login"))
  expect(calls.slice(1)).toEqual([
    ["finish", "chrome:browse:login", "handoff_cancelled"],
    ["announce", ["chrome:browse:login"]],
  ])
  calls.length = 0
  // An older hub ignores `handoff` and `capabilities`: its resource would take navigation, so it is removed.
  expect(await run(hubResources(hub({}), root).open(handoff))).toBeUndefined()
  expect(calls.at(-1)).toEqual(["remove", "chrome:browse:login"])
  // A hub that fails leaves the handoff without a resource.
  const failing = hubResources(
    {
      ...hub({}),
      upsert: async () => {
        throw new Error("relay down")
      },
    },
    root,
  )
  expect(await run(failing.open(handoff))).toBeUndefined()
})
