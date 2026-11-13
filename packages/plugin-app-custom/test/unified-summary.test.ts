import { expect, test } from "bun:test"
import { Effect, Exit, Option, Queue, Scope, Stream } from "effect"
import { TestClock } from "effect/testing"
import { mkdtemp, realpath, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { it } from "../../core/test/lib/effect"
import type { Push, Result } from "../src/live-activity/apns"
import { makeHub, type Member } from "../src/live-activity/index"
import { body as rawBody, limits as pushLimits, push } from "../src/live-activity/lifecycle"
import { limits, linkSettings, makePeers, readSocket, serveSummary } from "../src/live-activity/link"
import type { LiveActivity } from "../src/live-activity/rpc"
import type { Event } from "../src/live-activity/tracker"
import { decodeSummary, initials, join, type Summary } from "../src/live-activity/unified"
import { T, created, execution, ids, minute, question, world } from "./fixture/live-activity"
import { storage } from "./fixture/storage"

async function fixture(name: string) {
  return JSON.parse(await Bun.file(new URL(`../docs/unified-summary/${name}.json`, import.meta.url)).text())
}
const summaryOf = async (name: string) => Option.getOrThrow(decodeSummary(await fixture(name)))
const linux = await summaryOf("summary-linux")
const mac = await summaryOf("summary-mac")
const peer = (summary: Summary, online = true) => ({
  instanceID: summary.instanceID,
  name: summary.name,
  ...(online ? { summary } : {}),
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

test("a peer without a fresh summary leaves the state and stays listed as offline (contract fixture)", async () => {
  const state = join({ self: linux, peers: [peer(mac, false)] }).state
  expect(state.counts).toEqual(linux.state.counts)
  expect(state.sessions.every((row) => row.server === linux.instanceID)).toBe(true)
  expect(state.host).toBe("Linux BRS · Mac de Alexandre offline")
  expect(state.servers).toEqual([
    { instanceID: linux.instanceID, name: "Linux BRS", short: "LB" },
    { instanceID: mac.instanceID, name: "Mac de Alexandre", short: "MA", offline: true },
  ])
  expect(state).toEqual(await fixture("state-peer-offline"))
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
  expect(linkSettings({})).toEqual({ peers: [] })
  expect(
    linkSettings({ OPENCODE_SUMMARY_SOCKET: " /run/s.sock ", OPENCODE_SUMMARY_PEERS: "/a.sock, /b.sock,/a.sock" }),
  ).toEqual({
    serve: "/run/s.sock",
    peers: ["/a.sock", "/b.sock"],
  })
})

const settle = Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 1)))
const settled = Effect.gen(function* () {
  for (let round = 0; round < 5; round++) yield* settle
})

it.effect(
  "a peer that stops answering keeps its last summary for 60 seconds, then is offline until it answers again",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const shared = storage()
      const answer = { current: (): Promise<unknown> => Promise.resolve(mac) }
      const changes = { count: 0 }
      const peers = makePeers({
        sockets: ["/mac.sock"],
        storage: shared,
        read: () => answer.current(),
        changed: () => void changes.count++,
      })
      expect(peers.current(T).peers).toEqual([])
      yield* peers.poll("/mac.sock")
      expect(peers.current(T).peers).toEqual([peer(mac)])
      expect(changes.count).toBe(1)
      // The same summary again changes nothing for the hub.
      yield* peers.poll("/mac.sock")
      expect(changes.count).toBe(1)
      answer.current = () => Promise.reject(new Error("ENOENT"))
      yield* TestClock.adjust(limits.staleMs - 1)
      yield* peers.poll("/mac.sock")
      expect(peers.current(T + limits.staleMs - 1)).toEqual({ peers: [peer(mac)], wakeAt: T + limits.staleMs })
      expect(peers.current(T + limits.staleMs)).toEqual({ peers: [peer(mac, false)] })
      yield* TestClock.adjust(minute)
      answer.current = () => Promise.resolve(mac)
      yield* peers.poll("/mac.sock")
      expect(peers.current(T + limits.staleMs + minute).peers).toEqual([peer(mac)])
      expect(changes.count).toBe(2)
      // After a restart with the peer away, it is still known, as offline.
      const restarted = makePeers({
        sockets: ["/mac.sock"],
        storage: shared,
        read: () => Promise.reject(new Error("ENOENT")),
        changed: () => undefined,
      })
      yield* restarted.load
      yield* restarted.poll("/mac.sock")
      expect(restarted.current(T).peers).toEqual([peer(mac, false)])
    }),
)

for (const [what, body] of [
  ["another protocol version", { ...mac, protocol: 2 }],
  ["a summary this version cannot decode", { ...mac, state: { ...mac.state, counts: "many" } }],
  ["no JSON object", "<html>"],
] as const)
  it.effect(`a peer answering ${what} is never read, and replaces no summary already held`, () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const answer = { current: body as unknown }
      const peers = makePeers({
        sockets: ["/mac.sock"],
        storage: storage(),
        read: () => Promise.resolve(answer.current),
        changed: () => undefined,
      })
      yield* peers.poll("/mac.sock")
      expect(peers.current(T).peers).toEqual([])
      answer.current = mac
      yield* peers.poll("/mac.sock")
      answer.current = body
      yield* peers.poll("/mac.sock")
      expect(peers.current(T).peers).toEqual([peer(mac)])
      expect(peers.current(T + limits.staleMs).peers).toEqual([peer(mac, false)])
    }),
  )

test("the socket serves GET /summary only, an absent socket fails the read, and a live socket is never taken over", async () => {
  const dir = await mkdtemp(path.join(await realpath(os.tmpdir()), "summary-"))
  const socket = path.join(dir, "run", "summary.sock")
  const scope = Effect.runSync(Scope.make())
  try {
    await expect(readSocket(socket)).rejects.toBeDefined()
    await Effect.runPromise(serveSummary({ socket, read: () => mac }).pipe(Scope.provide(scope)))
    expect(Option.getOrThrow(decodeSummary(await readSocket(socket)))).toEqual(mac)
    expect((await Bun.file(socket).stat()).mode & 0o777).toBe(0o600)
    const other = await fetch("http://summary/api/session", { unix: socket })
    expect(other.status).toBe(404)
    expect((await fetch("http://summary/summary", { unix: socket, method: "POST" })).status).toBe(404)
    // A second server given the same path (a sandbox with production's environment) leaves the first one serving.
    const second = Effect.runSync(Scope.make())
    await Effect.runPromise(serveSummary({ socket, read: () => linux }).pipe(Scope.provide(second)))
    await Effect.runPromise(Scope.close(second, Exit.void))
    expect(Option.getOrThrow(decodeSummary(await readSocket(socket))).instanceID).toBe(mac.instanceID)
    await Effect.runPromise(Scope.close(scope, Exit.void))
    await expect(readSocket(socket)).rejects.toBeDefined()
  } finally {
    await Effect.runPromise(Scope.close(scope, Exit.void))
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

/** A hub named Linux BRS over an in-memory server, a fake APNs and, with `read`, one peer socket. */
function hubWith(read?: () => Promise<unknown>) {
  const server = world()
  const shared = storage()
  const pushes: Push[] = []
  const emitted: { state: LiveActivity.AgentsState | null; unified?: LiveActivity.AgentsState }[] = []
  const hub = makeHub({
    host: Effect.succeed("Linux BRS"),
    apns: Effect.succeed({
      send: (item: Push) => Effect.sync((): Result => (pushes.push(item), { status: "sent" })),
      close: Effect.void,
    }),
    ...(read ? { link: { peers: ["/mac.sock"], read } } : {}),
  })
  const join = (queue: Queue.Queue<Event>) => {
    const member: Member = {
      ctx: { ...server.ctx, storage: shared, events: Stream.fromQueue(queue) },
      emit: (state, unified) => Effect.sync(() => void emitted.push({ state, ...(unified ? { unified } : {}) })),
    }
    return hub.join(member)
  }
  const to = (token: string) => pushes.filter((item) => item.token === token)
  return { server, shared, pushes, emitted, hub, join, to }
}

it.effect(
  "the Todos activity gets both servers' sessions, loses the peer's 60 s after it stops answering and gets them back; the other device keeps this server's own state",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const answer = { current: (): Promise<unknown> => Promise.resolve(mac) }
      const f = hubWith(() => answer.current())
      const queue = yield* Queue.unbounded<Event>()
      yield* f.join(queue)
      expect(yield* f.hub.handlers.register(everywhere)).toEqual({ push: "configured", scope: "all" })
      expect(yield* f.hub.handlers.register(single)).toEqual({ push: "configured" })
      yield* f.hub.handlers.activity({ deviceID: everywhere.deviceID, activityID: "act-todos", pushToken: "aa00" })
      yield* f.hub.handlers.activity({ deviceID: single.deviceID, activityID: "act-linux", pushToken: "bb00" })
      yield* Queue.offerAll(queue, [created(ids.live, T), execution("started", ids.live, T)])
      yield* settled
      yield* TestClock.adjust(pushLimits.coalesceMs)
      yield* settled
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

      // The Mac sleeps: its part stays until its last summary is 60 s old, then leaves at once (urgent).
      answer.current = () => Promise.reject(new Error("ECONNREFUSED"))
      const before = f.to("aa00").length
      yield* TestClock.adjust(limits.staleMs + limits.pollMs)
      yield* settled
      const alone = bodyOf(f.to("aa00").at(-1)!).aps["content-state"]
      expect(f.to("aa00").length).toBeGreaterThan(before)
      expect(alone.counts).toMatchObject({ working: 1, question: 0, permission: 0, failed: 0 })
      expect(alone.host).toBe("Linux BRS · Mac de Alexandre offline")
      expect(alone.servers?.map((item) => item.offline)).toEqual([undefined, true])
      expect(f.to("aa00").at(-1)?.priority).toBe(10)

      answer.current = () => Promise.resolve(mac)
      yield* TestClock.adjust(limits.pollMs)
      yield* settled
      yield* TestClock.adjust(pushLimits.coalesceMs)
      yield* settled
      const back = bodyOf(f.to("aa00").at(-1)!).aps["content-state"]
      expect(back.counts).toMatchObject({ working: 2, question: 1, failed: 2 })
      expect(back.servers?.some((item) => item.offline)).toBe(false)

      // A question of this server alerts once, through each device's own card: the joined one and the server's.
      f.server.forms.push(question("frm_1", ids.live, T + 2 * minute, "Publicar agora?"))
      yield* Queue.offer(queue, { type: "form.created", data: { form: f.server.forms[0]! } } as Event)
      yield* settled
      const alerts = f.pushes.filter((item) => bodyOf(item).aps.alert)
      expect(alerts.map((item) => [item.token, bodyOf(item).aps["content-state"].servers?.length])).toEqual([
        ["aa00", 2],
        ["bb00", undefined],
      ])
      // The other device never received a state with the peer's sessions.
      expect(f.to("bb00").every((item) => bodyOf(item).aps["content-state"].counts.failed === 0)).toBe(true)
    }),
)

it.effect("push-to-start follows the joined state: the peer's work starts the Todos activity and no other", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const calm: Summary = {
      ...mac,
      state: {
        ...linux.state,
        counts: { ...linux.state.counts, working: 0, question: 0 },
        activeTotal: 0,
        attention: [],
        attentionTotal: 0,
        sessions: [],
        needs: [],
      },
      order: {},
      marks: [],
    }
    const answer = { current: calm as unknown }
    const f = hubWith(() => Promise.resolve(answer.current))
    yield* f.join(yield* Queue.unbounded<Event>())
    yield* f.hub.handlers.register(everywhere)
    yield* f.hub.handlers.register(single)
    yield* settled
    expect(f.pushes).toEqual([])
    answer.current = mac
    yield* TestClock.adjust(limits.pollMs)
    yield* settled
    expect(f.pushes.map((item) => [item.token, bodyOf(item).aps.event])).toEqual([["a11", "start"]])
    const start = f.pushes[0]!.body as Body & { aps: { attributes: { serverKey: string } } }
    expect(start.aps.attributes.serverKey).toBe("todos")
    expect(start.aps["content-state"].servers).toHaveLength(2)
    expect(start.aps["content-state"].activeTotal).toBe(3)
  }),
)

it.effect("without peers a server ignores the scope: its own state, no confirmation, nothing joined", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const f = hubWith()
    const queue = yield* Queue.unbounded<Event>()
    yield* f.join(queue)
    expect(yield* f.hub.handlers.register(everywhere)).toEqual({ push: "configured" })
    yield* f.hub.handlers.activity({ deviceID: everywhere.deviceID, activityID: "act-todos", pushToken: "aa00" })
    yield* Queue.offerAll(queue, [created(ids.live, T), execution("started", ids.live, T)])
    yield* settled
    yield* TestClock.adjust(pushLimits.coalesceMs)
    yield* settled
    const state = bodyOf(f.to("aa00").at(-1)!).aps["content-state"]
    expect(state.host).toBe("Linux BRS")
    expect(state.servers).toBeUndefined()
    expect(state.focus?.server).toBeUndefined()
    expect(yield* f.hub.handlers.snapshot()).not.toHaveProperty("unified")
    expect(f.emitted.every((item) => item.unified === undefined)).toBe(true)
  }),
)

it.effect("the summary a server publishes is its own even while it joins its peers' (no loop)", () =>
  Effect.gen(function* () {
    const dir = yield* Effect.promise(async () => mkdtemp(path.join(await realpath(os.tmpdir()), "summary-")))
    yield* Effect.addFinalizer(() => Effect.promise(() => rm(dir, { recursive: true, force: true })))
    const socket = path.join(dir, "summary.sock")
    const server = world()
    const hub = makeHub({
      host: Effect.succeed("Linux BRS"),
      apns: Effect.succeed(undefined),
      link: { serve: socket, peers: ["/mac.sock"], read: () => Promise.resolve(mac) },
    })
    const queue = yield* Queue.unbounded<Event>()
    yield* hub.join({
      ctx: { ...server.ctx, storage: storage(), events: Stream.fromQueue(queue) },
      emit: () => Effect.void,
    })
    yield* Queue.offerAll(queue, [created(ids.live, Date.now()), execution("started", ids.live, Date.now())])
    // The socket opens after real file-system work; the peers are read right after it.
    const published = Option.getOrThrow(
      decodeSummary(
        yield* Effect.promise(async () => {
          for (let round = 0; round < 200; round++) {
            const body = await readSocket(socket).catch(() => undefined)
            if (body) return body
            await new Promise((resolve) => setTimeout(resolve, 10))
          }
        }),
      ),
    )
    yield* settled
    expect((yield* hub.handlers.snapshot()).unified?.counts.failed).toBe(2)
    expect(published.name).toBe("Linux BRS")
    expect(published.state.counts).toMatchObject({ working: 1, failed: 0, question: 0 })
    expect(published.state.servers).toBeUndefined()
    expect(published.order).toEqual({ [ids.live]: expect.any(Number) })
  }),
)
