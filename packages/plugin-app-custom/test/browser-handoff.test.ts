import { describe, expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { Effect, Exit, Schema, Scope } from "effect"
import { Session } from "@opencode/schema/session"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { browseOwner, callTab, resultJson } from "../src/browser-handoff/calls"
import { detect, maxMessage, messages } from "../src/browser-handoff/detect"
import {
  afterOutcome,
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

test("browse's handoff and demonstrate calls wait on Alexandre, with the call's message and tab", () => {
  expect(detect("browse_handoff", { message: "Faça login no GitHub e clique em Continue", tab: 3 })).toEqual({
    message: "Faça login no GitHub e clique em Continue",
    tab: 3,
  })
  expect(detect("browse.demonstrate", { tab: 4 })).toEqual({ message: messages.demonstrate, tab: 4 })
  expect(detect("browse_handoff", { message: "  Diga\n  ok ", tab: 1 })?.message).toBe("Diga ok")
  expect(detect("browse_handoff", { message: "", tab: 1 })?.message).toBe(messages.handoff)
  expect(Array.from(detect("browse_handoff", { message: "a".repeat(300), tab: 1 })!.message)).toHaveLength(maxMessage)
  // Without a tab (browse refuses it at once) it waits on nothing the apps can show.
  expect(detect("browse_handoff", { message: "x" })).toEqual({ message: "x" })
  for (const tool of ["browse_click", "browse_execute", "browse_navigate", "handoff", "shell"])
    expect(detect(tool, { message: "x", tab: 1 })).toBeUndefined()
})

test("browse's owner of a session and the tab a call acts on", () => {
  // `mcp-` and the first 8 hex digits of the SHA-256 of the trimmed session ID, as browse's MCP server derives it.
  expect(browseOwner("ses_0123456789abcdefghijklmn")).toBe("mcp-666f6415")
  expect(browseOwner(" ses_0123456789abcdefghijklmn\n")).toBe("mcp-666f6415")
  expect(callTab("click", { tab: 7, x: 1, y: 2 })).toBe(7)
  expect(callTab("navigate", { url: "x" }, { url: "x", tab: 9 })).toBe(9)
  expect(callTab("navigate", { url: "x" }, `{\n  "url": "x",\n  "tab": 9\n}\nWarning: slow`)).toBe(9)
  expect(callTab("navigate", { tab: 3, url: "x" }, { tab: 9 })).toBe(3)
  expect(callTab("tabs", { action: "new" }, '{"tab":11}')).toBe(11)
  // Closing tabs names them but follows none; a result without a tab says nothing.
  expect(callTab("tabs", { action: "close", tab: 9 }, { closed: [9] })).toBeUndefined()
  expect(callTab("navigate", { url: "x" }, "browse failed")).toBeUndefined()
  expect(resultJson('{"a":1}\nNote: browse has an update')).toEqual({ a: 1 })
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

const call = (sessionID: string, id: string, message: string, tab = 3, tool = "browse_handoff") => ({
  tool,
  sessionID,
  messageID: "msg_1",
  id,
  input: { message, tab },
})

test("a handoff call waits only after the grace period; its end, by hook or by event, clears it once", async () => {
  const { registry, handoffs, announced, close, graceMs } = await location()
  const first = call(ids.live, "call_1", "Faça login")
  await run(handoffs.before(first))
  // Other browse tools and other tools are never recorded.
  await run(handoffs.before(call(ids.live, "call_2", "", 3, "browse_click")))
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
  const quick = call(ids.live, "call_4", "Rápido")
  await run(handoffs.before(quick))
  await run(handoffs.after({ ...quick, status: "error" }))
  await Bun.sleep(graceMs * 3)
  expect(registry.waiting()).toEqual([])
  expect(announced).toHaveLength(2)

  // An interruption skips `execute.after`: the session's end clears its calls.
  await run(handoffs.before(call(ids.cache, "call_5", "A")))
  await run(handoffs.before(call(ids.cache, "call_6", "", 3, "browse_demonstrate")))
  await Bun.sleep(graceMs * 3)
  expect(registry.waiting().map((entry) => entry.message)).toEqual(["A", messages.demonstrate])
  await run(handoffs.ended({ type: "session.execution.interrupted", data: { sessionID: ids.cache } }))
  expect(registry.waiting()).toEqual([])
  // Each waiting handoff that ends is announced on its own (with `ended`, see the resource tests below).
  expect(announced).toEqual([ids.live, ids.live, ids.cache, ids.cache, ids.cache, ids.cache])

  // Code Mode's execute ending (its program interrupted the pending call) clears only that tool part.
  await run(handoffs.before(call(ids.oauth, "call_7", "B")))
  await run(handoffs.before(call(ids.oauth, "call_8", "C")))
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
  const first = call(ids.live, "call_1", "Entrar")
  await run(a.handoffs.before(first))
  await Bun.sleep(a.graceMs * 3)
  await run(b.handoffs.ended({ type: "session.execution.failed", data: { sessionID: ids.live } }))
  await run(b.handoffs.after({ ...first, input: { ...first.input }, status: "completed" }))
  expect(registry.waiting()).toHaveLength(1)
  expect(b.announced).toEqual([])
  // Another hook replaced the input object: the same message and tab in the same tool part match.
  await run(a.handoffs.after({ ...first, input: { message: "Entrar", tab: 3 }, status: "completed" }))
  expect(registry.waiting()).toEqual([])
  expect(a.announced).toEqual([ids.live, ids.live])
  // The registry wakes its listeners on every change of the waiting list.
  let wakes = 0
  const stop = registry.listen(() => void wakes++)
  await run(a.handoffs.before(call(ids.live, "call_2", "x")))
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
        log.push(`open ${handoff.browse} ${handoff.tab} ${handoff.agent ?? "-"}`)
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

const owner = browseOwner(ids.live)
const browseCall = (id: string, tab?: number) => ({
  ...call(ids.live, id, "Entre com a senha"),
  input: { message: "Entre com a senha", ...(tab === undefined ? {} : { tab }) },
  agent: "build",
})
const failed = (id: string, tab: number, message: string) => ({
  ...browseCall(id, tab),
  status: "error" as const,
  error: { message },
})

test("a handoff waits on its session's browse resource, on its tab, and ends in the contract's order", async () => {
  const { registry, handoffs, log, endings, close } = await withResources({ openMs: 20 })
  const first = browseCall("call_1", 3)
  await run(handoffs.before(first))
  // Within the grace period nothing exists yet, not even the resource.
  expect(log).toEqual([])
  await Bun.sleep(120)
  const waiting = registry.waiting()
  expect(waiting.map((entry) => entry.resourceID)).toEqual([`chrome:browse:${owner}`])
  expect(wire(waiting[0]!).resourceID).toBe(`chrome:browse:${owner}`)
  // The resource exists before anyone hears the handoff waits, so every surface gets its `resourceID` at once.
  expect(log).toEqual([`open ${owner} 3 build`, `browser-handoffs.changed ${ids.live}`])

  await run(handoffs.after(failed("call_1", 3, '{"outcome":"timeout","tab":3}')))
  expect(registry.waiting()).toEqual([])
  // Its viewers end first, then the handoff's change with `ended`, then the resources' change.
  expect(log.slice(2)).toEqual([
    `end chrome:browse:${owner} timeout`,
    `browser-handoffs.changed ${ids.live} timeout`,
    `resources.changed chrome:browse:${owner}`,
  ])
  expect(endings.at(-1)).toEqual({
    sessionID: ids.live,
    ended: { id: waiting[0]!.id, resourceID: `chrome:browse:${owner}`, outcome: "timeout" },
  })
  expect(Schema.decodeUnknownSync(BrowserHandoffs.Changed)(endings.at(-1))).toEqual(endings.at(-1)!)
  await close()
})

test("each way a handoff ends has its outcome, and calls without a tab or a resource get none", async () => {
  const { registry, handoffs, log, endings, close } = await withResources()
  const outcome = async (id: string, finish: () => Promise<unknown>) => {
    await run(handoffs.before(browseCall(id, 5)))
    await Bun.sleep(100)
    expect(registry.waiting().at(-1)?.resourceID).toBe(`chrome:browse:${owner}`)
    await finish()
    return endings.at(-1)?.ended?.outcome
  }
  const result = { output: { outcome: "continued", tab: 5 } }
  expect(await outcome("c1", () => run(handoffs.after({ ...browseCall("c1", 5), status: "completed", result })))).toBe(
    "completed",
  )
  expect(await outcome("c2", () => run(handoffs.after(failed("c2", 5, '{"outcome":"closed","tab":5}'))))).toBe(
    "failed",
  )
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

  // No tab: it still waits and is still announced, without a resource.
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
  await run(refused.handoffs.before(browseCall("c7", 3)))
  await Bun.sleep(100)
  expect(refused.registry.waiting().map((entry) => entry.resourceID)).toEqual([undefined])
  await run(refused.handoffs.after({ ...browseCall("c7", 3), status: "completed" }))
  expect(refused.log).toEqual([
    `open ${owner} 3 build`,
    `browser-handoffs.changed ${ids.live}`,
    `browser-handoffs.changed ${ids.live} completed`,
  ])
  await refused.close()
})

test("a call that ends while its resource is being registered never waits and its resource goes quietly", async () => {
  const { registry, handoffs, log, close } = await withResources({ openMs: 80 })
  await run(handoffs.before(browseCall("call_1", 3)))
  await Bun.sleep(50)
  expect(log).toEqual([`open ${owner} 3 build`])
  await run(handoffs.after({ ...browseCall("call_1", 3), status: "completed" }))
  await Bun.sleep(120)
  expect(registry.waiting()).toEqual([])
  expect(log).toEqual([
    `open ${owner} 3 build`,
    `end chrome:browse:${owner} completed`,
    `resources.changed chrome:browse:${owner}`,
  ])
  await close()
})

test("the hub port registers the locked resource on the handoff's tab, refuses one an older hub returns without locks, and ends it", async () => {
  const calls: unknown[] = []
  const resource = (extra: object) => ({ id: `chrome:browse:${owner}`, kind: "chrome", ...extra }) as never
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
  const handoff = { id: "brw_1", sessionID: "ses_child", message: "Entre", since: 5, browse: owner, tab: 3, agent: "build" }
  const root = () => Effect.succeed("ses_root")
  const endpoint = async () => "http://127.0.0.1:19993"
  const locked = hubResources(hub({ capabilities, handoff: { id: "brw_1" } }), root, endpoint)
  expect(await run(locked.open(handoff))).toBe(`chrome:browse:${owner}`)
  expect(calls[0]).toEqual([
    "upsert",
    {
      kind: "chrome",
      meta: { kind: "chrome", cdp: "http://127.0.0.1:19993", browse: owner, targetID: "3" },
      purpose: "Entre",
      owner: { sessionID: "ses_child", rootSessionID: "ses_root", agent: "build" },
      used: true,
      capabilities: { navigation: false, tabs: false, focus: true },
      handoff: { id: "brw_1", sessionID: "ses_child", message: "Entre", since: 5 },
    },
  ])
  await run(locked.close(`chrome:browse:${owner}`, "cancelled"))
  await run(locked.announce(`chrome:browse:${owner}`))
  expect(calls.slice(1)).toEqual([
    ["finish", `chrome:browse:${owner}`, "handoff_cancelled"],
    ["announce", [`chrome:browse:${owner}`]],
  ])
  calls.length = 0
  // An older hub ignores `handoff` and `capabilities`: its resource would take navigation, so it is removed.
  expect(await run(hubResources(hub({}), root, endpoint).open(handoff))).toBeUndefined()
  expect(calls.at(-1)).toEqual(["remove", `chrome:browse:${owner}`])
  // A hub that fails leaves the handoff without a resource.
  const failing = hubResources(
    {
      ...hub({}),
      upsert: async () => {
        throw new Error("relay down")
      },
    },
    root,
    endpoint,
  )
  expect(await run(failing.open(handoff))).toBeUndefined()
})

/**
 * What browse 0.1.0 answers when a handoff does not end with Continue, as the MCP tool reports it (the error text is
 * the tool's own: its JSON, or the relay's message when it stopped the call). The outcome rule matches on them; the
 * second test finds the relay's own texts in an installed browse binary, so a browse that rewords one fails here
 * instead of silently turning an outcome into `failed`.
 */
const browseErrors: readonly { readonly text: string; readonly outcome: BrowserHandoffs.Outcome }[] = [
  { text: '{"outcome":"timeout","tab":1836872126}', outcome: "timeout" },
  { text: '{"outcome":"cancelled","tab":3}', outcome: "cancelled" },
  { text: '{"outcome":"closed","tab":3}', outcome: "failed" },
  { text: "The call was cancelled by its client.", outcome: "cancelled" },
  { text: "The client that called this (process 4242) exited, so it was stopped.", outcome: "cancelled" },
  {
    text: "The user dismissed the browser's debugging bar, which detached browse from their tabs, so this was stopped. Ask the user how to continue.",
    outcome: "cancelled",
  },
  { text: "The call was stopped.", outcome: "cancelled" },
  {
    text: "The browser isn't answering (asleep, frozen or very busy?). Wake it or wait a moment, then try again.",
    outcome: "failed",
  },
  { text: "Tab 3 isn't a browse tab you can use: browse didn't open it for you and the user didn't lend it.", outcome: "failed" },
  { text: "Relay closed", outcome: "failed" },
]

describe("browse's answers decide a handoff's outcome", () => {
  test("each real answer, as the MCP tool reports it, maps to its outcome", () => {
    const base = browseCall("x", 3)
    const outcome = (message: string) => afterOutcome({ ...base, status: "error", error: { message } })
    for (const item of browseErrors) {
      expect({ text: item.text, outcome: outcome(item.text) }).toEqual(item)
      // The MCP client may prefix it, and browse appends its warnings.
      expect(outcome(`Error: ${item.text}\nWarning: the tab was reloaded`)).toBe(item.outcome)
    }
    expect(afterOutcome({ ...base, status: "completed" })).toBe("completed")
    expect(afterOutcome({ ...base, status: "error" })).toBe("failed")
    expect(afterOutcome({ ...base, status: "error", error: { message: "The operation was aborted" } })).toBe(
      "cancelled",
    )
    expect(endedOutcome({ type: "session.archived", data: { sessionID: "s" } })).toBe("cancelled")
    expect(endedOutcome({ type: "session.deleted", data: { sessionID: "s" } })).toBe("cancelled")
    expect(endedOutcome({ type: "session.execution.failed", data: { sessionID: "s" } })).toBe("failed")
    expect(endedOutcome({ type: "session.tool.success", data: { sessionID: "s", id: "c" } })).toBe("completed")
  })

  const binary =
    process.env.OPENCODE_BROWSE_BINARY ??
    "/opt/homebrew/lib/node_modules/@opencode/browse/node_modules/@opencode/browse-darwin-arm64/bin/browse"
  test.skipIf(!existsSync(binary))("the relay's own texts are still in the installed browse binary", async () => {
    const text = new TextDecoder("latin1").decode(await Bun.file(binary).arrayBuffer())
    const texts = [
      "The call was cancelled by its client.",
      "exited, so it was stopped.",
      "so this was stopped.",
      "The call was stopped.",
      "continued",
      "timeout",
      "closed",
      "cancelled",
    ]
    expect(texts.filter((item) => !text.includes(item))).toEqual([])
  })
})
