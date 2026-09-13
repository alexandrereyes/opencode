import { expect, test } from "bun:test"
import {
  subscriptionAccounts,
  subscriptionCapacity,
  subscriptionPercentages,
  subscriptionPool,
} from "./subscription-pool"

const account = {
  id: "a",
  name: "A",
  plan: "pro",
  enabled: true,
  authenticated: true,
  cooldownSeconds: 0,
  stale: false,
  remaining: 5,
  hasCapacity: true,
  observedAt: "2026-09-10T08:00:00Z",
  resetAt: null,
  bankedResets: null,
}

test("averages only active authenticated Pro accounts without treating rounded quota as availability", () => {
  expect(
    subscriptionPool([
      account,
      { ...account, id: "b", remaining: 85 },
      { ...account, id: "plus", plan: "plus", remaining: 100 },
      { ...account, id: "disabled", enabled: false, remaining: 100 },
      { ...account, id: "unauthenticated", authenticated: false, remaining: 100 },
    ]),
  ).toMatchObject({ total: 2, measured: 2, availableRemaining: 45, ready: 2, balance: "known" })
  expect(subscriptionPool([{ ...account, remaining: 0 }]).ready).toBe(1)
})

test("reports remaining balance only across Pro accounts available now", () => {
  expect(
    subscriptionPool([
      { ...account, remaining: 0, hasCapacity: false },
      { ...account, id: "b", remaining: 59 },
    ]),
  ).toMatchObject({
    total: 2,
    measured: 2,
    ready: 1,
    availableRemaining: 59,
    balance: "known",
  })
})

test("missing or stale measurements suppress the whole pool percentage", () => {
  expect(subscriptionCapacity({ ...account, remaining: null })).toBe("available")
  expect(subscriptionCapacity({ ...account, remaining: null, hasCapacity: false })).toBe("unavailable")
  expect(subscriptionPool([account, { ...account, remaining: null }])).toMatchObject({
    total: 2,
    measured: 1,
    ready: 2,
    availableRemaining: null,
    balance: "unknown",
  })
  expect(subscriptionPool([account, { ...account, remaining: null, hasCapacity: false }])).toMatchObject({
    total: 2,
    measured: 1,
    ready: 1,
    availableRemaining: null,
    balance: "unknown",
  })
  expect(subscriptionCapacity({ ...account, stale: true })).toBe("unconfirmed")
  expect(subscriptionPool([account, { ...account, stale: true }])).toMatchObject({
    total: 2,
    measured: 1,
    ready: 1,
    availableRemaining: null,
    balance: "unknown",
  })
  expect(subscriptionCapacity({ ...account, hasCapacity: null })).toBe("unconfirmed")
  expect(subscriptionPool([account, { ...account, hasCapacity: null }])).toMatchObject({
    total: 2,
    measured: 2,
    ready: 1,
    availableRemaining: null,
    balance: "unknown",
  })
  expect(subscriptionPool([])).toEqual({
    total: 0,
    measured: 0,
    ready: 0,
    balance: "empty",
    availableRemaining: null,
    observedAt: null,
    banked: null,
  })
})

test("treats a snapshot from before a completed renewal as unconfirmed", () => {
  const renewing = {
    ...account,
    observedAt: "2026-09-10T08:00:00Z",
    resetAt: "2026-09-10T09:00:00Z",
  }
  expect(subscriptionCapacity(renewing, Date.parse("2026-09-10T10:00:00Z"))).toBe("unconfirmed")
  expect(subscriptionPool([renewing], Date.parse("2026-09-10T10:00:00Z"))).toMatchObject({
    measured: 0,
    ready: 0,
    balance: "unknown",
    availableRemaining: null,
  })
  expect(subscriptionCapacity(renewing, Date.parse("2026-09-10T08:30:00Z"))).toBe("available")
})

test("rounds remaining once and derives used as its complement", () => {
  expect(subscriptionPercentages(59.5)).toEqual({ remaining: 60, used: 40 })
})

test("orders available Pro accounts before other Pro, Plus, and other plans without dropping accounts", () => {
  const accounts = [
    { ...account, id: "other", plan: "team" },
    { ...account, id: "plus", plan: "plus" },
    { ...account, id: "stale", stale: true },
    { ...account, id: "available" },
    { ...account, id: "cooldown", cooldownSeconds: 120 },
    { ...account, id: "unknown", hasCapacity: null },
    { ...account, id: "exhausted", hasCapacity: false },
    { ...account, id: "available-second" },
  ]

  expect(subscriptionAccounts(accounts).map((item) => item.id)).toEqual([
    "available",
    "available-second",
    "stale",
    "cooldown",
    "unknown",
    "exhausted",
    "plus",
    "other",
  ])
  expect(accounts.map((item) => item.id)).toEqual([
    "other",
    "plus",
    "stale",
    "available",
    "cooldown",
    "unknown",
    "exhausted",
    "available-second",
  ])
})

test("cooldown and capacity remove known accounts from the available balance", () => {
  expect(
    subscriptionPool([
      { ...account, cooldownSeconds: 120 },
      { ...account, remaining: 85, hasCapacity: false, observedAt: "2026-09-10T08:01:00Z" },
    ]),
  ).toEqual({
    total: 2,
    measured: 2,
    ready: 0,
    balance: "unavailable",
    availableRemaining: null,
    observedAt: Date.parse(account.observedAt),
    banked: null,
  })
})

test("banked inventory totals the Pro pool and preserves unknown and non-expiring credits", () => {
  const first = {
    ...account,
    bankedResets: {
      available: 2,
      earliestExpiresAt: "2026-10-01T12:00:00Z",
      latestExpiresAt: "2026-10-02T12:00:00Z",
      nonExpiring: 0,
    },
  }
  const second = {
    ...account,
    remaining: 0,
    hasCapacity: false,
    bankedResets: {
      available: 3,
      earliestExpiresAt: "2026-10-03T12:00:00Z",
      latestExpiresAt: "2026-10-05T12:00:00Z",
      nonExpiring: 1,
    },
  }
  expect(subscriptionPool([first, second, { ...first, plan: "plus" }]).banked).toEqual({
    available: 5,
    earliest: Date.parse("2026-10-01T12:00:00Z"),
    latest: Date.parse("2026-10-05T12:00:00Z"),
    nonExpiring: 1,
  })
  expect(subscriptionPool([first, account]).banked).toBeNull()
})
