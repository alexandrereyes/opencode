import { expect, test } from "bun:test"
import { Effect, Queue, Schema, Stream } from "effect"
import { TestClock } from "effect/testing"
import { it } from "../../core/test/lib/effect"
import type { Push } from "../src/live-activity/apns"
import { makeHub, type Member } from "../src/live-activity/index"
import { fit, limits as pushLimits, makeLifecycle, makeRegistry } from "../src/live-activity/lifecycle"
import { LiveActivity } from "../src/live-activity/rpc"
import { makeTracker, type Event } from "../src/live-activity/tracker"
import { current, latest, parse, summarize, type Todo } from "../src/progress/todos"
import {
  T,
  T0,
  created,
  execution,
  fixture,
  ids,
  minute,
  plan,
  scene,
  session,
  todoMessage,
  todowrite,
  userMessage,
  world,
} from "./fixture/live-activity"

const host = "MacBook Pro"
const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect)
const directory = "/Users/alexandremartins/Worktrees/opencode2-live-activity"

test("parse keeps items with content and reads an unknown status as pending, like the web", () => {
  expect(
    parse([
      { content: "Ler", status: "completed" },
      { content: "", status: "pending" },
      { status: "pending" },
      { content: "Testar", status: "blocked" },
      "texto",
      { content: "Revisar" },
    ]),
  ).toEqual([
    { content: "Ler", status: "completed" },
    { content: "Testar", status: "pending" },
    { content: "Revisar", status: "pending" },
  ])
  expect(parse(undefined)).toEqual([])
  expect(parse({ todos: [] })).toEqual([])
})

test("the number counts completed items, the ring counts cancelled ones too, and both use every item", () => {
  expect(summarize(parse(plan))).toEqual({
    done: 3,
    finished: 4,
    total: 7,
    current: "Atualizar a Live Activity e o relógio",
  })
})

test("the current item is the one in progress, else the next pending one, else the last completed one", () => {
  const items = (statuses: Todo["status"][]) => statuses.map((status, index) => ({ content: `${index}`, status }))
  expect(current(items(["completed", "pending", "in_progress", "pending"]))?.content).toBe("2")
  expect(current(items(["completed", "cancelled", "pending", "pending"]))?.content).toBe("2")
  expect(current(items(["completed", "completed", "cancelled"]))?.content).toBe("1")
  expect(current(items(["cancelled", "cancelled"]))?.content).toBe("0")
  expect(current([])).toBeUndefined()
})

test("an empty list or one with every item completed or cancelled shows nothing", () => {
  expect(summarize([])).toBeUndefined()
  expect(
    summarize([
      { content: "a", status: "completed" },
      { content: "b", status: "cancelled" },
    ]),
  ).toBeUndefined()
  expect(
    summarize([
      { content: "a", status: "cancelled" },
      { content: "b", status: "pending" },
    ]),
  ).toEqual({
    done: 0,
    finished: 1,
    total: 2,
    current: "b",
  })
})

test("latest takes the newest completed call before the revert boundary and ignores failed calls", () => {
  const older = todoMessage("msg_1", T - 5 * minute, [{ content: "Antes", status: "in_progress" }])
  const prompt = userMessage("msg_2", T - 4 * minute)
  const newer = todoMessage("msg_3", T - 3 * minute, [{ content: "Depois", status: "in_progress" }])
  const failed = todoMessage("msg_4", T - 2 * minute, [{ content: "Falhou", status: "pending" }], "error")
  const newestFirst = [failed, newer, prompt, older]
  expect(latest(newestFirst)).toEqual([{ content: "Depois", status: "in_progress" }])
  // The boundary message and everything after it are gone.
  expect(latest(newestFirst, "msg_2")).toEqual([{ content: "Antes", status: "in_progress" }])
  expect(latest(newestFirst, "msg_3")).toEqual([{ content: "Antes", status: "in_progress" }])
  // Not found among them: more messages are needed.
  expect(latest(newestFirst, "msg_0")).toBeUndefined()
  expect(latest([prompt])).toBeUndefined()
  // A cleared list is a list too: nothing shows.
  expect(latest([todoMessage("msg_5", T, [])])).toEqual([])
})

test("events folded into the progress situation produce state-progress.json", async () => {
  const tracker = await run(scene("progress"))
  const state = tracker.derive(T, host).state
  expect(state).toEqual(await fixture("state-progress"))
  expect(Schema.decodeUnknownSync(LiveActivity.AgentsState)(await fixture("state-progress"))).toEqual(state)
  expect(tracker.progress(ids.live)).toEqual({
    done: 3,
    finished: 4,
    total: 7,
    current: "Atualizar a Live Activity e o relógio",
    todos: parse(plan),
  })
})

test("without experimental.todo the row keeps its subagent count and nothing shows", async () => {
  const server = world()
  const tracker = await run(scene("progress", server))
  server.todo.clear()
  // The gate is read again when the session updates its list or starts working.
  await run(Effect.forEach(todowrite(ids.live, T, "call_again", plan), (event) => tracker.apply(event, T)))
  const state = tracker.derive(T, host).state
  expect(state.focus?.progress).toEqual({ done: 2, total: 3, unit: "subagents" })
  expect(tracker.progress(ids.live)).toBeUndefined()
})

test("the list shows only while the session itself executes and still has an open item", async () => {
  const server = world()
  server.todo.add(directory)
  const tracker = makeTracker(server.ctx)
  const apply = (events: Event[]) =>
    run(Effect.forEach(events, (event) => tracker.apply(event, "created" in event ? event.created : T)))
  await apply([
    created(ids.live, T0),
    execution("started", ids.live, T0),
    created("ses_child_1", T0 + minute, ids.live),
    execution("started", "ses_child_1", T0 + minute),
    ...todowrite(ids.live, T0 + 2 * minute, "call_1", plan),
  ])
  expect(tracker.derive(T, host).state.sessions[0]?.progress).toMatchObject({ done: 3, total: 7, unit: "todos" })
  // A subagent has its own list, which never changes its top-level session's.
  await apply(todowrite("ses_child_1", T0 + 3 * minute, "call_child", [{ content: "Filho", status: "pending" }]))
  expect(tracker.progress(ids.live)?.current).toBe("Atualizar a Live Activity e o relógio")
  expect(tracker.progress("ses_child_1")).toMatchObject({ done: 0, total: 1, current: "Filho" })
  expect(tracker.derive(T, host).state.focus?.progress?.current).toBe("Atualizar a Live Activity e o relógio")
  // A call that never succeeds changes nothing.
  await apply([
    {
      type: "session.tool.input.started",
      created: T0 + 4 * minute,
      data: { sessionID: ids.live, id: "call_2", name: "todowrite" },
    },
    {
      type: "session.tool.called",
      created: T0 + 4 * minute,
      data: { sessionID: ids.live, id: "call_2", input: { todos: [] } },
    },
  ])
  expect(tracker.progress(ids.live)?.done).toBe(3)
  // Its own run ended while the subagent still works: back to the subagent count.
  await apply([execution("succeeded", ids.live, T0 + 5 * minute)])
  expect(tracker.derive(T, host).state.sessions[0]).toMatchObject({
    status: "working",
    progress: { done: 0, total: 1, unit: "subagents" },
  })
  expect(tracker.progress(ids.live)).toBeUndefined()
  // Every item finished: nothing shows although it works again.
  await apply([
    execution("started", ids.live, T0 + 6 * minute),
    ...todowrite(ids.live, T0 + 7 * minute, "call_3", [
      { content: "a", status: "completed" },
      { content: "b", status: "cancelled" },
    ]),
  ])
  expect(tracker.progress(ids.live)).toBeUndefined()
})

test("a resumed session reads its list from the transcript, and a revert reads it again before the boundary", async () => {
  const server = world()
  server.todo.add(directory)
  server.add(session(ids.live))
  server.transcripts.set(ids.live, [
    todoMessage("msg_1", T - 9 * minute, [{ content: "Primeiro plano", status: "in_progress" }]),
    userMessage("msg_2", T - 8 * minute),
    todoMessage("msg_3", T - 7 * minute, plan),
  ])
  const tracker = makeTracker(server.ctx)
  await run(tracker.rebuild(T - 6 * minute))
  // Not running at the rebuild: nothing read yet.
  expect(tracker.progress(ids.live)).toBeUndefined()
  await run(tracker.apply(execution("started", ids.live, T - 5 * minute), T - 5 * minute))
  expect(tracker.progress(ids.live)?.done).toBe(3)
  server.add(session(ids.live, { revert: { messageID: "msg_2" } }))
  await run(tracker.apply({ type: "session.revert.staged", created: T, data: { sessionID: ids.live } }, T))
  expect(tracker.progress(ids.live)?.current).toBe("Primeiro plano")
  server.add(session(ids.live))
  await run(tracker.apply({ type: "session.revert.cleared", created: T, data: { sessionID: ids.live } }, T))
  expect(tracker.progress(ids.live)?.total).toBe(7)
})

test("an imported or forked session reads the list its history brought on its first run", async () => {
  const server = world()
  server.todo.add(directory)
  server.add(session(ids.live))
  server.transcripts.set(ids.live, [userMessage("msg_1", T0 - minute), todoMessage("msg_2", T0, plan)])
  const tracker = makeTracker(server.ctx)
  await run(tracker.apply(created(ids.live, T0), T0))
  expect(tracker.progress(ids.live)).toBeUndefined()
  await run(tracker.apply(execution("started", ids.live, T0 + minute), T0 + minute))
  expect(tracker.progress(ids.live)).toMatchObject({
    done: 3,
    total: 7,
    current: "Atualizar a Live Activity e o relógio",
  })
})

test("a rebuild reads the list of every running top-level session", async () => {
  const server = world()
  server.todo.add(directory)
  server.add(session(ids.live))
  server.active.add(ids.live)
  server.transcripts.set(ids.live, [todoMessage("msg_1", T - minute, plan)])
  const tracker = makeTracker(server.ctx)
  await run(tracker.rebuild(T))
  expect(tracker.derive(T, host).state.focus?.progress).toEqual({
    done: 3,
    total: 7,
    unit: "todos",
    current: "Atualizar a Live Activity e o relógio",
  })
})

test("the hub asks the session's own Location whether experimental.todo is on", async () => {
  const server = world()
  const other = "/Users/alexandremartins/Dev/core-infra"
  const queue = await run(Queue.unbounded<Event>())
  const hub = makeHub({ host: Effect.succeed(host), apns: Effect.succeed(undefined) })
  const shared = { get: () => Effect.succeed(undefined), update: () => Effect.succeed(undefined as never) }
  const member = (location: string, enabled: boolean): Member => ({
    ctx: { ...server.ctx, storage: shared, events: Stream.fromQueue(queue) },
    emit: () => Effect.void,
    todo: { directory: location, enabled: Effect.succeed(enabled) },
  })
  await run(
    Effect.scoped(
      Effect.gen(function* () {
        yield* hub.join(member(directory, true))
        yield* hub.join(member(other, false))
        yield* Queue.offerAll(queue, [
          created(ids.live, T0),
          execution("started", ids.live, T0),
          ...todowrite(ids.live, T0 + minute, "call_1", plan),
          created(ids.deploy, T0),
          execution("started", ids.deploy, T0),
          ...todowrite(ids.deploy, T0 + minute, "call_2", plan),
        ])
        for (let round = 0; round < 10; round++) yield* Effect.promise(() => Bun.sleep(1))
        expect(hub.progress(ids.live)?.total).toBe(7)
        expect(hub.progress(ids.deploy)).toBeUndefined()
      }),
    ),
  )
})

test("a push that does not fit drops the rows' current item before any row or title", async () => {
  const state = (await fixture("state-progress")) as LiveActivity.AgentsState
  const long = "x".repeat(60)
  const heavy: LiveActivity.AgentsState = {
    ...state,
    sessions: Array.from({ length: 4 }, (_, index) => ({
      ...state.sessions[0]!,
      sessionID: `ses_${index}`,
      title: "t".repeat(80),
      progress: { done: 3, total: 7, unit: "todos" as const, current: long },
    })),
    attention: Array.from({ length: 3 }, (_, index) => ({
      sessionID: `ses_a${index}`,
      title: "a".repeat(80),
      project: "p".repeat(40),
      directory: "/".repeat(400),
      kind: "question" as const,
      since: T,
      text: "q".repeat(120),
    })),
    focus: { ...state.focus!, progress: { done: 3, total: 7, unit: "todos", current: long } },
  }
  const trimmed = fit({ event: "update", state: heavy, now: T })
  expect(trimmed.focus?.progress?.current).toBe(long)
  expect(trimmed.sessions.every((row) => row.progress?.current === undefined)).toBe(true)
  expect(trimmed.sessions).toHaveLength(4)
})

it.effect("Progresso changes ride the routine updates: at most one push per 10 seconds, priority 5", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const values = new Map<string, Schema.Json>()
    const registry = makeRegistry({
      get: (key) => Effect.sync(() => values.get(key)),
      update: (key, update) =>
        Effect.sync(() => {
          const [next, result] = update(values.get(key))
          values.set(key, next)
          return result
        }),
    })
    const pushes: Push[] = []
    const lifecycle = makeLifecycle({
      registry,
      send: (push) => Effect.sync(() => (pushes.push(push), { status: "sent" as const })),
    })
    const server = world()
    const tracker = yield* scene("progress", server)
    const evaluate = (now: number) =>
      lifecycle.evaluate(tracker.derive(now, host), now).pipe(
        Effect.tap((plan) => plan.deliver),
        Effect.map((plan) => plan.wakeAt),
      )
    yield* registry.register(
      {
        deviceID: "iphone",
        serverKey: "mac",
        environment: "sandbox",
        theme: (yield* Effect.promise(() => fixture("attributes"))).theme,
        pushToStartToken: "aa",
      },
      T - minute,
    )
    yield* registry.activity({ deviceID: "iphone", activityID: "act", pushToken: "bb" }, T - minute)
    yield* evaluate(T)
    expect(pushes).toHaveLength(1)
    // Three list updates within the slot: one push at its end, with the last list.
    for (const [offset, done] of [
      [1000, 4],
      [3000, 5],
      [6000, 6],
    ] as const) {
      const todos = plan.map((item, index) => ({
        ...item,
        status: index < done ? "completed" : index === done ? "in_progress" : item.status,
      }))
      yield* Effect.forEach(todowrite(ids.live, T + offset, `call_${offset}`, todos), (event) =>
        tracker.apply(event, T + offset),
      )
      expect(yield* evaluate(T + offset)).toBe(T + pushLimits.coalesceMs)
    }
    expect(pushes).toHaveLength(1)
    yield* evaluate(T + pushLimits.coalesceMs)
    expect(pushes.map((push) => push.priority)).toEqual([5, 5])
    expect(pushes[1]?.body).toHaveProperty(["aps", "content-state", "focus", "progress", "done"], 6)
  }),
)
