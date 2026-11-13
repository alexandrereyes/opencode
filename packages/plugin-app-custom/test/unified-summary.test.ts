import { expect, test } from "bun:test"
import { Clock, Effect, Exit, Option, Queue, Scope, Stream } from "effect"
import { TestClock } from "effect/testing"
import { mkdir, mkdtemp, realpath, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { it } from "../../core/test/lib/effect"
import type { Push, Result } from "../src/live-activity/apns"
import { makeHub, type Member } from "../src/live-activity/index"
import { body as rawBody, devicesKey, limits as pushLimits, push } from "../src/live-activity/lifecycle"
import { devicesKey as notificationDevicesKey } from "../src/notifications/index"
import {
  hubPassword,
  httpSend,
  limits,
  linkSettings,
  makeInbox,
  makePublisher,
  peersKey,
  type Send,
  type Sent,
} from "../src/live-activity/link"
import type { LiveActivity } from "../src/live-activity/rpc"
import type { Event } from "../src/live-activity/tracker"
import { decodeSummary, initials, join, settled, type Summary } from "../src/live-activity/unified"
import { T, created, execution, ids, minute, question, world } from "./fixture/live-activity"
import { storage } from "./fixture/storage"

async function fixture(name: string) {
  return JSON.parse(await Bun.file(new URL(`../docs/unified-summary/${name}.json`, import.meta.url)).text())
}
const summaryOf = async (name: string) => Option.getOrThrow(decodeSummary(await fixture(name)))
const linux = await summaryOf("summary-linux")
const mac = await summaryOf("summary-mac")
/** A server as the hub's inbox reports it: whole while it renews, only what waits there once it is offline. */
const peer = (summary: Summary, online = true) => ({
  instanceID: summary.instanceID,
  name: summary.name,
  summary: online ? summary : settled(summary),
  ...(online ? {} : { offline: true }),
})
const sessionIDs = (rows: readonly { readonly sessionID: string }[]) => rows.map((row) => row.sessionID)

test("the joined state adds the counts, interleaves the lists by the tracker's order and cuts them (contract fixture)", async () => {
  const state = join({ self: linux, peers: [peer(mac)] }).state
  expect(state.counts).toEqual({ working: 3, question: 2, permission: 1, failed: 2, idle: 1, unread: 2 })
  expect([state.activeTotal, state.attentionTotal]).toEqual([6, 3])
  // Oldest wait first, whatever the server; the writer's unread row and the peer's older failure fall off the cut.
  expect(sessionIDs(state.attention)).toEqual([ids.cache, "ses_01JZRELEASEPROD0000000013", ids.oauth])
  expect(sessionIDs(state.sessions)).toEqual([ids.cache, "ses_01JZRELEASEPROD0000000013", ids.oauth, ids.deploy])
  expect(sessionIDs(state.needs ?? [])).toEqual([ids.cache, "ses_01JZRELEASEPROD0000000013", ids.oauth])
  expect(state.sessions.map((row) => row.server)).toEqual([
    mac.instanceID,
    linux.instanceID,
    mac.instanceID,
    mac.instanceID,
  ])
  expect(state.focus).toMatchObject({ sessionID: "ses_01JZSWARMMIGRATION00000011", server: linux.instanceID })
  expect(state).toEqual(await fixture("state-joined"))
})

test("an offline server loses its work in progress and keeps what waits there, listed as offline (contract fixture)", async () => {
  const state = join({ self: linux, peers: [peer(mac, false)] }).state
  // The Mac's working session and focus left; its question, permission, failures and unread answer are still true.
  expect(state.counts).toEqual({ working: 2, question: 2, permission: 1, failed: 2, idle: 1, unread: 2 })
  expect(state.activeTotal).toBe(5)
  expect(settled(mac).state.focus).toBeUndefined()
  expect(sessionIDs(state.attention)).toEqual([ids.cache, "ses_01JZRELEASEPROD0000000013", ids.oauth])
  expect(state.host).toBe("Linux BRS · Mac de Alexandre offline")
  expect(state.servers).toEqual([
    { instanceID: linux.instanceID, name: "Linux BRS", short: "LB" },
    { instanceID: mac.instanceID, name: "Mac de Alexandre", short: "MA", offline: true },
  ])
  expect(state).toEqual(await fixture("state-peer-offline"))
  // Going away is urgent: the update goes out at once, also on a parked card.
  expect([...join({ self: linux, peers: [peer(mac, false)] }).marks.keys()]).toContain(`offline:${mac.instanceID}`)
  expect([...join({ self: linux, peers: [peer(mac)] }).marks.keys()].some((mark) => mark.startsWith("offline:"))).toBe(
    false,
  )
  // Nothing working is left of a settled summary, rows included.
  const busy = rows("mac", [
    ["fail", "failed", 5],
    ["busy", "working", 9],
  ])
  expect(sessionIDs(settled(busy).state.sessions)).toEqual(["fail"])
  expect(settled(busy).order).toEqual({ fail: 5 })
})

/** A summary with only rows, each `[sessionID, status, order]`; the first working row is its focus. */
function rows(instanceID: string, list: readonly (readonly [string, LiveActivity.RowStatus, number])[]): Summary {
  const ref = (sessionID: string) => ({ sessionID, title: sessionID, project: "p", directory: "/repo" })
  const focus = list.find((row) => row[1] === "working")
  return {
    protocol: 1,
    instanceID,
    name: instanceID,
    state: {
      v: 1,
      updatedAt: T,
      host: instanceID,
      counts: { working: 0, question: 0, permission: 0, failed: 0, idle: 0, unread: 0 },
      activeTotal: 0,
      ...(focus ? { focus: { ...ref(focus[0]), startedAt: T } } : {}),
      attention: [],
      attentionTotal: 0,
      sessions: list.map(([sessionID, status]) => ({ ...ref(sessionID), status })),
      needs: [],
    },
    order: Object.fromEntries(list.map(([sessionID, , at]) => [sessionID, at])),
    marks: list.map(([sessionID, status]) => `${status}:${sessionID}`),
  }
}

test("failures and unread go newest first, and the working rows open with the single focus, then by latest activity", () => {
  const self = rows("hub", [
    ["fail-old", "failed", 5],
    ["hub-focus", "working", 10],
    ["hub-busy", "working", 50],
  ])
  const other = rows("peer", [
    ["fail-new", "failed", 9],
    ["peer-focus", "working", 70],
    ["unread", "idle", 99],
  ])
  const state = join({ self, peers: [peer(other)] }).state
  expect(state.focus?.sessionID).toBe("hub-focus")
  // The peer's own focus is one more working row here: its newer activity puts it before `hub-busy`, never first.
  expect(sessionIDs(state.sessions)).toEqual(["fail-new", "fail-old", "hub-focus", "peer-focus"])
  // Without work on the writer, the peer's focus is the focus.
  const calm = rows("hub", [["fail-old", "failed", 5]])
  expect(join({ self: calm, peers: [peer(other)] }).state.focus).toMatchObject({
    sessionID: "peer-focus",
    server: "peer",
  })
})

test("a session with the same ID on both servers is two rows and two urgency keys; a peer that is this server adds nothing", () => {
  const self = rows("hub", [["ses_same", "failed", 5]])
  const twin = rows("peer", [["ses_same", "failed", 9]])
  const result = join({ self, peers: [peer(twin)] })
  expect(result.state.sessions.map((row) => [row.server, row.sessionID])).toEqual([
    ["peer", "ses_same"],
    ["hub", "ses_same"],
  ])
  expect([...result.marks.keys()]).toEqual(["hub/failed:ses_same", "peer/failed:ses_same"])
  // Its own socket configured as a peer: nothing is counted twice and it is not listed twice.
  const looped = join({ self: linux, peers: [peer(linux)] }).state
  expect(looped.counts).toEqual(linux.state.counts)
  expect(looped.servers).toHaveLength(1)
})

test("the joined state's push still fits in 4096 bytes and keeps the servers", () => {
  const long = (summary: Summary): Summary => ({
    ...summary,
    state: {
      ...summary.state,
      attention: summary.state.attention.map((item) => ({ ...item, text: "ç".repeat(120), title: "T".repeat(80) })),
      sessions: summary.state.sessions.map((item) => ({
        ...item,
        title: "T".repeat(80),
        directory: `/srv/${"d".repeat(200)}`,
      })),
      needs: (summary.state.needs ?? []).map((item) => ({ ...item, title: "T".repeat(80) })),
    },
  })
  const state = join({ self: long(linux), peers: [peer(long(mac))] }).state
  expect(Buffer.byteLength(JSON.stringify(rawBody({ event: "update", state, now: T })))).toBeGreaterThan(
    pushLimits.bodyBytes,
  )
  const body = push("aa11", "sandbox", 5, { event: "update", state, now: T }).body as {
    aps: { "content-state": LiveActivity.AgentsState }
  }
  expect(Buffer.byteLength(JSON.stringify(body))).toBeLessThanOrEqual(pushLimits.bodyBytes)
  expect(body.aps["content-state"].servers).toHaveLength(2)
  expect(body.aps["content-state"].sessions.every((row) => row.server !== undefined)).toBe(true)
  expect(body.aps["content-state"].counts).toEqual(state.counts)
})

test("the badge's initials follow the apps' rule", () => {
  expect(["Linux BRS", "Mac de Alexandre", "Mac", "MacBook Pro de Alexandre"].map(initials)).toEqual([
    "LB",
    "MA",
    "MA",
    "MP",
  ])
})

test("the link is off without its variables", () => {
  expect(linkSettings({})).toEqual({ hub: false })
  expect(linkSettings({ OPENCODE_HUB: "1" })).toEqual({ hub: true })
  expect(linkSettings({ OPENCODE_SUMMARY_HUB: " http://opencode-svc/ " })).toEqual({
    hub: false,
    target: "http://opencode-svc",
  })
})

const settle = Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 1)))
const settled5 = Effect.gen(function* () {
  for (let round = 0; round < 5; round++) yield* settle
})

/** A parked summary: the Mac fixture with nothing working. */
const parked = settled(mac)

it.effect(
  "a working summary not renewed for 60 s leaves its server offline with only what waits there; a parked one never expires; a goodbye is offline at once",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const changes = { count: 0 }
      const inbox = makeInbox({ storage: storage(), changed: () => void changes.count++ })
      expect(inbox.current(T).peers).toEqual([])
      yield* inbox.accept(mac)
      expect(inbox.current(T)).toEqual({ peers: [peer(mac)], wakeAt: T + limits.staleMs })
      // A renewal that says the same moves nothing; it only pushes the deadline.
      yield* TestClock.adjust(limits.heartbeatMs)
      yield* inbox.accept(mac)
      expect(changes.count).toBe(1)
      const renewed = T + limits.heartbeatMs
      expect(inbox.current(renewed + limits.staleMs - 1).peers).toEqual([peer(mac)])
      expect(inbox.current(renewed + limits.staleMs)).toEqual({ peers: [peer(mac, false)] })
      // It answers again: whole, and the hub hears of it.
      yield* TestClock.adjust(limits.staleMs + minute)
      yield* inbox.accept(mac)
      expect(inbox.current(renewed + limits.staleMs + minute).peers).toEqual([peer(mac)])
      expect(changes.count).toBe(2)
      // Parked, it has nothing to renew: still in force a day later, and not offline.
      yield* inbox.accept(parked)
      expect(inbox.current(T + 86_400_000)).toEqual({
        peers: [{ instanceID: mac.instanceID, name: mac.name, summary: parked }],
      })
      yield* inbox.leave(mac.instanceID)
      expect(inbox.current(T + 86_400_000).peers).toEqual([peer(mac, false)])
      expect(changes.count).toBe(4)
    }),
)

it.effect("a hub restart keeps a parked server's summary, written only when what waits there changes", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const shared = storage()
    const writes = { count: 0 }
    const counted = {
      get: shared.get,
      update: ((key, update) => {
        writes.count++
        return shared.update(key, update)
      }) as typeof shared.update,
    }
    const inbox = makeInbox({ storage: counted, changed: () => undefined })
    yield* inbox.accept(mac)
    // Work moving (another activity time) is no reason to write.
    yield* inbox.accept({
      ...mac,
      state: { ...mac.state, updatedAt: T + 1, focus: { ...mac.state.focus!, activity: "Pensando" } },
    })
    expect(writes.count).toBe(1)
    yield* inbox.accept({ ...mac, marks: mac.marks.slice(1) })
    expect(writes.count).toBe(2)
    expect(shared.values.get(peersKey)).toHaveLength(1)
    const restarted = makeInbox({ storage: shared, changed: () => undefined })
    yield* restarted.load
    // The server may have stopped working meanwhile; its next send says so. Until then, what waited there shows.
    const [restored] = restarted.current(T + minute).peers
    expect(restored?.offline).toBeUndefined()
    expect(restored?.summary?.state.counts).toMatchObject({ working: 0, question: 1, failed: 2 })
    expect(restored?.summary?.marks).toEqual(mac.marks.slice(1))
    // A server silent for 30 days is forgotten.
    yield* TestClock.adjust(limits.forgetMs)
    const later = makeInbox({ storage: shared, changed: () => undefined })
    yield* later.load
    expect(later.current(T + limits.forgetMs).peers).toEqual([])
  }),
)

/** A publisher over a mutable summary and a recorded, scriptable hub. */
function publishing(initial: Summary) {
  const local = { current: initial }
  const calls: { at: number; method: string; input: unknown }[] = []
  const answer = { current: { ok: true } as Sent }
  const clock = { now: T }
  const send: Send = (method, input) => {
    calls.push({ at: clock.now, method, input })
    return Promise.resolve(answer.current)
  }
  const publisher = makePublisher({ read: (now) => Effect.sync(() => ((clock.now = now), local.current)), send })
  const advance = (ms: number) =>
    Effect.gen(function* () {
      yield* TestClock.adjust(ms)
      yield* settled5
    })
  return { local, calls, answer, publisher, advance }
}

it.effect(
  "the summary is sent when the server starts and when it changes; renewed every 15 s only while something works",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const f = publishing(parked)
      yield* f.publisher.run.pipe(Effect.forkScoped({ startImmediately: true }))
      yield* settled5
      expect(f.calls.map((call) => [call.at - T, call.method])).toEqual([[0, "publish"]])
      expect(f.calls[0]?.input).toEqual(parked)
      // Parked: an hour without a single send.
      yield* f.advance(3_600_000)
      expect(f.calls).toHaveLength(1)
      // Work starts: sent at once, then renewed every 15 s.
      const start = T + 3_600_000
      f.local.current = mac
      f.publisher.changed()
      yield* settled5
      yield* f.advance(limits.heartbeatMs * 2)
      expect(f.calls.slice(1).map((call) => call.at - start)).toEqual([0, limits.heartbeatMs, limits.heartbeatMs * 2])
      // Two changes inside a second cost one more send, a second after the last.
      f.local.current = { ...mac, marks: [] }
      f.publisher.changed()
      yield* settled5
      f.local.current = { ...mac, marks: ["x"] }
      f.publisher.changed()
      yield* settled5
      expect(f.calls).toHaveLength(4)
      yield* f.advance(limits.minMs)
      expect(f.calls).toHaveLength(5)
      expect((f.calls[4]?.input as Summary).marks).toEqual(["x"])
      // Work ends: the parked summary goes out once and the renewals stop.
      f.local.current = parked
      f.publisher.changed()
      yield* f.advance(limits.minMs)
      yield* f.advance(3_600_000)
      expect(f.calls).toHaveLength(6)
      // Stopping says goodbye once the hub ever heard from this server.
      yield* f.publisher.leave
      expect(f.calls.at(-1)).toMatchObject({ method: "leave", input: { protocol: 1, instanceID: mac.instanceID } })
    }),
)

it.effect(
  "a hub that is away is tried again after 2, 5 and then every 15 s, and gets the summary as soon as it is back",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const f = publishing(parked)
      f.answer.current = { ok: false, reason: "unreachable" }
      yield* f.publisher.run.pipe(Effect.forkScoped({ startImmediately: true }))
      yield* settled5
      yield* f.advance(2_000)
      yield* f.advance(5_000)
      yield* f.advance(15_000)
      yield* f.advance(15_000)
      expect(f.calls.map((call) => call.at - T)).toEqual([0, 2_000, 7_000, 22_000, 37_000])
      // Never having reached the hub, there is no goodbye to say.
      yield* f.publisher.leave
      expect(f.calls).toHaveLength(5)
      f.answer.current = { ok: true }
      yield* f.advance(15_000)
      expect(f.calls).toHaveLength(6)
      // Delivered: parked again, nothing more is sent.
      yield* f.advance(3_600_000)
      expect(f.calls).toHaveLength(6)
    }),
)

test("the call is the hub's RPC with the client's Basic credential; a wrong password, a refusal and an absent hub are told apart without leaking the password", async () => {
  const seen: { path: string; authorization: string | null; body: unknown }[] = []
  const reply = { current: () => Response.json({ output: { protocol: 1 } }) }
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch: async (request) => {
      seen.push({
        path: new URL(request.url).pathname,
        authorization: request.headers.get("authorization"),
        body: await request.json(),
      })
      return reply.current()
    },
  })
  const target = `http://127.0.0.1:${server.port}`
  try {
    const send = httpSend(target, () => Promise.resolve("s3nha-do-hub"))
    expect(await send("publish", mac)).toEqual({ ok: true, output: { protocol: 1 } })
    expect(seen[0]).toEqual({
      path: "/api/rpc/custom.summary/publish",
      authorization: `Basic ${Buffer.from("opencode:s3nha-do-hub").toString("base64")}`,
      body: { input: mac },
    })
    reply.current = () => new Response("Unauthorized", { status: 401 })
    const refused = await send("publish", mac)
    expect(refused).toEqual({ ok: false, reason: "unauthorized (the hub refused the password)" })
    reply.current = () =>
      Response.json(
        { _tag: "RpcError", type: "protocol_mismatch", message: "…", data: { expected: 2 } },
        { status: 400 },
      )
    expect(await send("publish", mac)).toEqual({ ok: false, reason: "protocol_mismatch (HTTP 400)" })
    expect(await httpSend(target, () => Promise.resolve(undefined))("publish", mac)).toEqual({
      ok: false,
      reason: "no password for the hub",
    })
  } finally {
    await server.stop(true)
  }
  expect(await httpSend(target, () => Promise.resolve("s3nha-do-hub"))("publish", mac)).toEqual({
    ok: false,
    reason: "unreachable",
  })
})

test("the hub's password: the explicit variable, else this server's own from the service config, else its runtime file", async () => {
  const dir = await mkdtemp(path.join(await realpath(os.tmpdir()), "summary-"))
  try {
    const config = path.join(dir, "config")
    await mkdir(config)
    const env = { OPENCODE_CONFIG_DIR: config, OPENCODE_CUSTOM_HOME: dir }
    expect(await hubPassword(env)).toBeUndefined()
    await Bun.write(path.join(dir, "password"), "do-runtime\n")
    expect(await hubPassword(env)).toBe("do-runtime")
    await Bun.write(path.join(config, "service-custom.json"), JSON.stringify({ password: "do-servico" }))
    expect(await hubPassword(env)).toBe("do-servico")
    expect(await hubPassword({ ...env, OPENCODE_SUMMARY_HUB_PASSWORD: "do-hub" })).toBe("do-hub")
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

const theme = {
  background: "#120f0eff",
  surface: "#161313ff",
  border: "#2e2e2dff",
  textStrong: "#e4e0d6ff",
  text: "#c9c5baff",
  textSecondary: "#a29f94ff",
  textWeak: "#6b6861ff",
  primary: "#da7c47ff",
  success: "#83b35fff",
  warning: "#c67f13ff",
  error: "#dc6e5eff",
  accent: "#9988e5ff",
}
const everywhere: LiveActivity.RegisterInput = {
  deviceID: "iphone-todos",
  serverKey: "todos",
  environment: "sandbox",
  theme,
  pushToStartToken: "a11",
  scope: "all",
}
const single: LiveActivity.RegisterInput = {
  deviceID: "ipad-linux",
  serverKey: "linux",
  environment: "sandbox",
  theme,
  pushToStartToken: "b22",
}
type Body = { aps: { event: string; alert?: { title: string }; "content-state": LiveActivity.AgentsState } }
const bodyOf = (item: Push) => item.body as Body

/** The RPC's error factory, as the host gives it to a handler. */
const context = { error: (type: string, message: string, data: unknown) => ({ type, message, data }) } as never
const outcome = <A, E>(effect: Effect.Effect<A, E>) =>
  effect.pipe(
    Effect.map((value) => ({ ok: value })),
    Effect.catch((error) => Effect.succeed({ error: (error as { type: string }).type })),
  )

/** A server over an in-memory world and a fake APNs; `link` makes it the hub or points it at one. */
function serverWith(name: string, link?: { hub: boolean; target?: string; send?: Send }) {
  const server = world()
  const shared = storage()
  const pushes: Push[] = []
  const emitted: { state: LiveActivity.AgentsState | null; unified?: LiveActivity.AgentsState }[] = []
  const hub = makeHub({
    host: Effect.succeed(name),
    apns: Effect.succeed({
      send: (item: Push) => Effect.sync((): Result => (pushes.push(item), { status: "sent" })),
      close: Effect.void,
    }),
    ...(link ? { link } : {}),
  })
  const join = (queue: Queue.Queue<Event>) => {
    const member: Member = {
      ctx: { ...server.ctx, storage: shared, events: Stream.fromQueue(queue) },
      emit: (state, unified) => Effect.sync(() => void emitted.push({ state, ...(unified ? { unified } : {}) })),
    }
    return hub.join(member)
  }
  const to = (token: string) => pushes.filter((item) => item.token === token)
  const publish = (input: unknown) => outcome(hub.summaries.publish(input as Record<string, unknown>, context))
  return { server, shared, pushes, emitted, hub, join, to, publish }
}

/** The HTTP call replaced by the hub's handlers in memory, on the test's clock. */
function linkTo(hubServer: ReturnType<typeof serverWith>, clock: Clock.Clock, sent: unknown[] = []): Send {
  return (method, input) => {
    if (method === "publish") sent.push(input)
    const call: Effect.Effect<unknown, unknown> =
      method === "publish"
        ? hubServer.hub.summaries.publish(input as Record<string, unknown>, context)
        : hubServer.hub.summaries.leave(input as { protocol: number; instanceID: string }, context)
    return Effect.runPromise(
      call.pipe(
        Effect.map((output): Sent => ({ ok: true, output })),
        Effect.catch((error) => Effect.succeed<Sent>({ ok: false, reason: (error as { type: string }).type })),
        Effect.provideService(Clock.Clock, clock),
      ),
    )
  }
}

for (const [what, order, expected] of [
  ["registered on the hub's Todos scope after this server", ["mac", "todos"], { mac: [], hub: ["iphone-todos"] }],
  ["registered on this server after the hub's Todos scope", ["todos", "mac"], { mac: ["iphone-todos"], hub: [] }],
  // An app from before the scopes registers on every server, with no scope: both stay.
  ["registered on both servers without a scope", ["mac", "hub"], { mac: ["iphone-todos"], hub: ["iphone-todos"] }],
] satisfies [string, string[], { mac: string[]; hub: string[] }][])
  it.effect(`a device ${what} keeps only its newest registration, and its notifications everywhere`, () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const hubServer = serverWith("Linux BRS", { hub: true })
      yield* hubServer.join(yield* Queue.unbounded<Event>())
      const macServer = serverWith("Mac de Alexandre", {
        hub: false,
        target: "http://hub.invalid",
        send: linkTo(hubServer, yield* Clock.Clock),
      })
      const queue = yield* Queue.unbounded<Event>()
      yield* macServer.join(queue)
      yield* macServer.hub.notifications.register({
        deviceID: everywhere.deviceID,
        serverKey: "mac",
        environment: "sandbox",
        token: "cc33",
      })
      const { scope: _, ...local } = { ...everywhere, serverKey: "mac" }
      for (const where of order) {
        // The servers cannot reach each other's registrations but through the summary: no unregister is called.
        if (where === "mac") yield* macServer.hub.handlers.register(local)
        if (where === "todos") yield* hubServer.hub.handlers.register(everywhere)
        if (where === "hub") yield* hubServer.hub.handlers.register(local)
        yield* TestClock.adjust(minute)
        yield* settled5
      }
      // A registration on the hub tells the other server nothing by itself: it learns with its next summary, here
      // one sent because a session started.
      yield* Queue.offerAll(queue, [created(ids.live, T), execution("started", ids.live, T)])
      yield* settled5
      yield* TestClock.adjust(limits.minMs)
      yield* settled5
      const devices = (server: ReturnType<typeof serverWith>) =>
        ((server.shared.values.get(devicesKey) ?? []) as { deviceID: string }[]).map((device) => device.deviceID)
      expect({ mac: devices(macServer), hub: devices(hubServer) }).toEqual(expected)
      expect(macServer.shared.values.get(notificationDevicesKey)).toHaveLength(1)
    }),
  )

it.effect(
  "only the hub accepts summaries, and only this protocol's: the rest is refused by name and joins nothing",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const plain = serverWith("Mac")
      yield* plain.join(yield* Queue.unbounded<Event>())
      expect(yield* plain.publish(mac)).toEqual({ error: "not_hub" })
      expect(yield* outcome(plain.hub.summaries.leave({ protocol: 1, instanceID: mac.instanceID }, context))).toEqual({
        error: "not_hub",
      })
      const f = serverWith("Linux BRS", { hub: true })
      yield* f.join(yield* Queue.unbounded<Event>())
      expect(yield* f.publish({ ...mac, protocol: 2 })).toEqual({ error: "protocol_mismatch" })
      expect(yield* f.publish({ ...mac, state: { ...mac.state, counts: "many" } })).toEqual({
        error: "invalid_summary",
      })
      expect(yield* f.publish({ protocol: 1 })).toEqual({ error: "invalid_summary" })
      expect((yield* f.hub.handlers.snapshot()).unified?.servers).toHaveLength(1)
      expect(yield* f.publish(mac)).toEqual({ ok: { protocol: 1 } })
      expect((yield* f.hub.handlers.snapshot()).unified?.servers).toHaveLength(2)
    }),
)

it.effect(
  "the Todos activity gets both servers' sessions, loses the other's work 60 s after its last renewal and gets it back; the other device keeps this server's own state",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const f = serverWith("Linux BRS", { hub: true })
      const queue = yield* Queue.unbounded<Event>()
      yield* f.join(queue)
      expect(yield* f.hub.handlers.register(everywhere)).toEqual({ push: "configured", scope: "all" })
      expect(yield* f.hub.handlers.register(single)).toEqual({ push: "configured" })
      yield* f.hub.handlers.activity({ deviceID: everywhere.deviceID, activityID: "act-todos", pushToken: "aa00" })
      yield* f.hub.handlers.activity({ deviceID: single.deviceID, activityID: "act-linux", pushToken: "bb00" })
      yield* f.publish(mac)
      yield* Queue.offerAll(queue, [created(ids.live, T), execution("started", ids.live, T)])
      yield* settled5
      yield* TestClock.adjust(pushLimits.coalesceMs)
      yield* settled5
      const both = bodyOf(f.to("aa00").at(-1)!).aps["content-state"]
      // One working session here plus the Mac fixture's: 1 working, 1 question, 1 permission, 2 failed.
      expect(both.counts).toMatchObject({ working: 2, question: 1, permission: 1, failed: 2 })
      expect(both.servers?.map((item) => [item.short, item.offline])).toEqual([
        ["LB", undefined],
        ["MA", undefined],
      ])
      expect(new Set(both.sessions.map((row) => row.server))).toEqual(new Set([mac.instanceID]))
      expect(both.focus).toMatchObject({ sessionID: ids.live, server: both.servers?.[0]?.instanceID })
      const own = bodyOf(f.to("bb00").at(-1)!).aps["content-state"]
      expect(own.counts).toMatchObject({ working: 1, question: 0, failed: 0 })
      expect(own.servers).toBeUndefined()
      expect(own.host).toBe("Linux BRS")
      // `snapshot` and `changed` carry both: the server's own state as always, and the joined one beside it.
      const snapshot = yield* f.hub.handlers.snapshot()
      expect(snapshot.state?.servers).toBeUndefined()
      expect(snapshot.unified?.counts).toEqual(both.counts)
      expect(f.emitted.at(-1)?.unified?.servers).toHaveLength(2)

      // The Mac sleeps while working: 60 s after its last renewal its work leaves, what waited there stays.
      const before = f.to("aa00").length
      yield* TestClock.adjust(limits.staleMs)
      yield* settled5
      const away = bodyOf(f.to("aa00").at(-1)!).aps["content-state"]
      expect(f.to("aa00").length).toBeGreaterThan(before)
      expect(away.counts).toMatchObject({ working: 1, question: 1, permission: 1, failed: 2 })
      expect(away.host).toBe("Linux BRS · Mac de Alexandre offline")
      expect(away.servers?.map((item) => item.offline)).toEqual([undefined, true])
      expect(f.to("aa00").at(-1)?.priority).toBe(10)

      yield* f.publish(mac)
      yield* settled5
      yield* TestClock.adjust(pushLimits.coalesceMs)
      yield* settled5
      const back = bodyOf(f.to("aa00").at(-1)!).aps["content-state"]
      expect(back.counts).toMatchObject({ working: 2, question: 1, failed: 2 })
      expect(back.servers?.some((item) => item.offline)).toBe(false)

      // A question of this server alerts once, through each device's own card: the joined one and the server's.
      f.server.forms.push(question("frm_1", ids.live, T + 2 * minute, "Publicar agora?"))
      yield* Queue.offer(queue, { type: "form.created", data: { form: f.server.forms[0]! } } as Event)
      yield* settled5
      const alerts = f.pushes.filter((item) => bodyOf(item).aps.alert)
      expect(alerts.map((item) => [item.token, bodyOf(item).aps["content-state"].servers?.length])).toEqual([
        ["aa00", 2],
        ["bb00", undefined],
      ])
      // The other device never received a state with the other server's sessions.
      expect(f.to("bb00").every((item) => bodyOf(item).aps["content-state"].counts.failed === 0)).toBe(true)
    }),
)

it.effect(
  "push-to-start follows the joined state: the other server's work starts the Todos activity and no other",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const f = serverWith("Linux BRS", { hub: true })
      yield* f.join(yield* Queue.unbounded<Event>())
      yield* f.hub.handlers.register(everywhere)
      yield* f.hub.handlers.register(single)
      const calm: Summary = {
        ...parked,
        state: {
          ...parked.state,
          counts: { ...parked.state.counts, question: 0, permission: 0 },
          activeTotal: 0,
          attention: [],
          attentionTotal: 0,
        },
      }
      yield* f.publish(calm)
      yield* settled5
      expect(f.pushes).toEqual([])
      yield* f.publish(mac)
      yield* settled5
      expect(f.pushes.map((item) => [item.token, bodyOf(item).aps.event])).toEqual([["a11", "start"]])
      const start = f.pushes[0]!.body as Body & { aps: { attributes: { serverKey: string } } }
      expect(start.aps.attributes.serverKey).toBe("todos")
      expect(start.aps["content-state"].servers).toHaveLength(2)
      expect(start.aps["content-state"].activeTotal).toBe(3)
    }),
)

it.effect("a server that is not the hub ignores the scope: its own state, no confirmation, nothing joined", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const f = serverWith("Linux BRS")
    const queue = yield* Queue.unbounded<Event>()
    yield* f.join(queue)
    expect(yield* f.hub.handlers.register(everywhere)).toEqual({ push: "configured" })
    yield* f.hub.handlers.activity({ deviceID: everywhere.deviceID, activityID: "act-todos", pushToken: "aa00" })
    yield* Queue.offerAll(queue, [created(ids.live, T), execution("started", ids.live, T)])
    yield* settled5
    yield* TestClock.adjust(pushLimits.coalesceMs)
    yield* settled5
    const state = bodyOf(f.to("aa00").at(-1)!).aps["content-state"]
    expect(state.host).toBe("Linux BRS")
    expect(state.servers).toBeUndefined()
    expect(state.focus?.server).toBeUndefined()
    expect(yield* f.hub.handlers.snapshot()).not.toHaveProperty("unified")
    expect(f.emitted.every((item) => item.unified === undefined)).toBe(true)
  }),
)

it.effect(
  "two servers linked: the sender's events reach the hub's joined state, what it sends is its own state (no loop), and stopping it says goodbye",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const linuxServer = serverWith("Linux BRS", { hub: true })
      yield* linuxServer.join(yield* Queue.unbounded<Event>())
      yield* linuxServer.publish(linux)
      const sent: unknown[] = []
      // The sender is itself a hub here, holding another server's summary: it must still send only its own.
      const send = linkTo(linuxServer, yield* Clock.Clock, sent)
      const macServer = serverWith("Mac de Alexandre", { hub: true, target: "http://hub.invalid", send })
      const queue = yield* Queue.unbounded<Event>()
      const scope = yield* Scope.make()
      yield* macServer.join(queue).pipe(Scope.provide(scope))
      yield* macServer.publish(linux)
      yield* settled5
      // Sent on start, with nothing to show yet.
      expect(sent).toHaveLength(1)
      yield* Queue.offerAll(queue, [created(ids.live, T), execution("started", ids.live, T)])
      yield* settled5
      yield* TestClock.adjust(limits.minMs)
      yield* settled5
      const published = Option.getOrThrow(decodeSummary(sent.at(-1)))
      expect(published.name).toBe("Mac de Alexandre")
      expect(published.state.counts).toMatchObject({ working: 1, question: 0 })
      expect(published.state.servers).toBeUndefined()
      expect(published.order).toEqual({ [ids.live]: expect.any(Number) })
      const unified = (yield* linuxServer.hub.handlers.snapshot()).unified
      expect(unified?.servers?.map((item) => [item.name, item.offline])).toContainEqual(["Mac de Alexandre", undefined])
      expect(unified?.sessions.some((row) => row.sessionID === ids.live && row.server === published.instanceID)).toBe(
        true,
      )
      // The Mac's server stops: the hub hears it and drops the Mac's work at once.
      yield* Scope.close(scope, Exit.void)
      yield* settled5
      const after = (yield* linuxServer.hub.handlers.snapshot()).unified
      expect(after?.servers?.find((item) => item.name === "Mac de Alexandre")?.offline).toBe(true)
      expect(after?.sessions.some((row) => row.sessionID === ids.live)).toBe(false)
    }),
)
