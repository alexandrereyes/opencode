import { expect, test } from "bun:test"
import type { SessionNavigationInfo } from "./sidebar-model"
import { createRecentClock, createRecentOrder } from "./sidebar-order"

function row(id: string, updated: number, created = 1): SessionNavigationInfo {
  return {
    session: {
      id,
      title: id,
      projectID: "repo",
      location: { directory: "/repo" },
      time: { created, updated },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  }
}

test("cold snapshot uses updated/created even for active sessions; live metadata freezes", () => {
  const order = createRecentOrder(createRecentClock(() => 100))
  order.snapshot([row("a", 20), row("b", 0, 30)], new Set(["a"]), new Set())
  expect({ ...order.ranks }).toEqual({ a: 20, b: 30 })
  order.seed({ ...row("a", 80), messageAt: 90 })
  order.observe("a", true)
  order.observe("b", false)
  expect({ ...order.ranks }).toEqual({ a: 20, b: 30 })
})

test("first active and active→settled promote once, repeated phases do not", () => {
  const order = createRecentOrder(createRecentClock(() => 100))
  order.observe("a", false)
  expect(order.ranks.a).toBeUndefined()
  order.seed(row("a", 10))
  order.observe("a", true)
  expect(order.ranks.a).toBe(100)
  order.observe("a", true)
  order.seed(row("a", 500))
  expect(order.ranks.a).toBe(100)
  order.observe("a", false)
  expect(order.ranks.a).toBe(101)
  order.observe("a", false)
  expect(order.ranks.a).toBe(101)
  order.observe("a", true)
  expect(order.ranks.a).toBe(102)
})

test("reconnect raises baselines, shares missed-transition rank and never demotes", () => {
  const order = createRecentOrder(createRecentClock(() => 100))
  order.snapshot([row("a", 10), row("b", 20), row("c", 30)], new Set(), new Set())
  order.snapshot([row("b", 60), row("a", 50), row("c", 90)], new Set(["a", "b"]), new Set())
  expect({ ...order.ranks }).toEqual({ a: 100, b: 100, c: 90 })
  order.snapshot([row("a", 5), row("b", 5), row("c", 5)], new Set(["a", "b"]), new Set())
  expect({ ...order.ranks }).toEqual({ a: 100, b: 100, c: 90 })
  order.snapshot([row("a", 150), row("b", 5), row("c", 5)], new Set(["a", "b"]), new Set())
  expect(order.ranks.a).toBe(150) // a whole missed execution can have the same final phase
})

test("events during snapshot hydration win over stale phase, timestamp and deleted rows", () => {
  const order = createRecentOrder(createRecentClock(() => 100))
  order.snapshot([row("a", 10), row("b", 20)], new Set(), new Set())
  order.observe("a", true)
  order.remove("b")
  order.snapshot([row("a", 500), row("b", 600)], new Set(), new Set(["a", "b"]))
  expect({ ...order.ranks }).toEqual({ a: 100 })
  order.observe("a", true)
  expect(order.ranks.a).toBe(100)
  order.observe("a", false)
  expect(order.ranks.a).toBe(101)
})

test("early activity reconciliation does not repromote a missed terminal after a later live start", () => {
  const order = createRecentOrder(createRecentClock(() => 100))
  const rows = [row("a", 10), row("b", 20)]
  order.snapshot(rows, new Set(["a"]), new Set())
  const promoted = order.activity(new Set(), new Set())
  order.observe("b", true)
  order.snapshot(rows, new Set(), new Set(["b"]), promoted)
  expect({ ...order.ranks }).toEqual({ a: 100, b: 101 })
})

test("navigation baseline refresh retains the early snapshot cohort's shared rank", () => {
  const order = createRecentOrder(createRecentClock(() => 100))
  order.snapshot([row("a", 10), row("b", 20)], new Set(), new Set())
  const active = new Set(["a", "b"])
  const promoted = order.activity(active, new Set())
  expect({ ...order.ranks }).toEqual({ a: 100, b: 100 })
  order.snapshot([row("a", 10), row("b", 500)], active, new Set(), promoted)
  expect({ ...order.ranks }).toEqual({ a: 500, b: 500 })
  order.observe("a", false)
  expect(order.ranks.a).toBe(501)
})

test("removed and archived identities release phases and ranks; moves retain identity", () => {
  const order = createRecentOrder(createRecentClock(() => 100))
  order.snapshot([row("a", 10)], new Set(["a"]), new Set())
  const moved = row("a", 50)
  moved.session.location.directory = "/other"
  order.seed(moved)
  expect(order.ranks.a).toBe(10)
  order.seed({ session: { ...moved.session, time: { ...moved.session.time, archived: 60 } } })
  expect(order.ranks.a).toBeUndefined()
  order.snapshot([row("a", 70)], new Set(), new Set())
  expect(order.ranks.a).toBe(70)
  order.snapshot([], new Set(), new Set())
  expect(Object.keys(order.ranks)).toEqual([])
  order.seed(row("a", 5))
  order.observe("a", false)
  expect(order.ranks.a).toBe(5)
})

test("server identities are independent and promotions share a monotonic clock above baselines", () => {
  const clock = createRecentClock(() => 100)
  const local = createRecentOrder(clock)
  const remote = createRecentOrder(clock)
  local.snapshot([row("same", 500)], new Set(), new Set())
  remote.snapshot([row("same", 10)], new Set(), new Set())
  remote.observe("same", true)
  local.observe("same", true)
  expect(remote.ranks.same).toBe(501)
  expect(local.ranks.same).toBe(502)
  remote.remove("same")
  expect(local.ranks.same).toBe(502)
  const readded = createRecentOrder(clock)
  readded.snapshot([row("same", 10)], new Set(), new Set())
  expect(readded.ranks.same).toBe(10)
})
