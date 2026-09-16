import { expect, test } from "bun:test"
import {
  subscriptionAccounts,
  subscriptionCapacity,
  subscriptionPercentages,
  subscriptionPace,
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
  fiveHourRemaining: null,
  fiveHourResetAt: null,
  remaining: 5,
  hasCapacity: true,
  observedAt: "2026-09-10T08:00:00Z",
  resetAt: null,
  bankedResets: null,
}

test("averages only active authenticated Pro 20x accounts without treating rounded quota as availability", () => {
  expect(
    subscriptionPool([
      account,
      { ...account, id: "b", remaining: 85 },
      { ...account, id: "plus", plan: "plus", remaining: 100 },
      { ...account, id: "prolite", plan: "prolite", remaining: 100 },
      { ...account, id: "disabled", enabled: false, remaining: 100 },
      { ...account, id: "unauthenticated", authenticated: false, remaining: 100 },
    ]),
  ).toMatchObject({ total: 2, measured: 2, availableRemaining: 45, ready: 2, balance: "known" })
  expect(subscriptionPool([{ ...account, remaining: 0 }]).ready).toBe(1)
})

test("keeps exhausted accounts in the combined quota denominator", () => {
  expect(
    subscriptionPool([
      { ...account, remaining: 0, hasCapacity: false },
      { ...account, id: "b", remaining: 59 },
    ]),
  ).toMatchObject({
    total: 2,
    measured: 2,
    ready: 1,
    availableRemaining: 29.5,
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
    expectedRemaining: null,
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

test("applies completed five-hour renewal boundaries to every supported tier", () => {
  const now = Date.parse("2026-09-10T10:00:00Z")
  expect(
    subscriptionCapacity(
      { ...account, plan: "plus", fiveHourResetAt: "2026-09-10T09:00:00Z" },
      now,
    ),
  ).toBe("unconfirmed")
  expect(subscriptionCapacity({ ...account, plan: "prolite" }, now)).toBe("available")
  expect(subscriptionCapacity({ ...account, plan: "team" }, now)).toBe("outside")
})

test("rounds remaining once and derives used as its complement", () => {
  expect(subscriptionPercentages(59.5)).toEqual({ remaining: 60, used: 40 })
})

test("orders Pro 20x, Pro 5x, then Plus with available accounts first within each plan", () => {
  const accounts = [
    { ...account, id: "other", plan: "team" },
    { ...account, id: "plus", plan: "plus" },
    { ...account, id: "prolite", plan: "prolite" },
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
    "prolite",
    "plus",
    "other",
  ])
  expect(accounts.map((item) => item.id)).toEqual([
    "other",
    "plus",
    "prolite",
    "stale",
    "available",
    "cooldown",
    "unknown",
    "exhausted",
    "available-second",
  ])
})

test("cooldown and capacity do not remove known quota from the combined balance", () => {
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
    availableRemaining: 45,
    expectedRemaining: null,
    observedAt: Date.parse(account.observedAt),
    banked: null,
  })
})

test("pace averages weekly time remaining across all pool members", () => {
  const now = Date.parse("2026-09-10T12:00:00Z")
  const halfway = { ...account, resetAt: "2026-09-14T00:00:00Z" }
  const full = { ...account, resetAt: "2026-09-17T12:00:00Z" }
  expect(subscriptionPace(halfway, now)).toBe(50)
  expect(subscriptionPace(full, now)).toBe(100)
  expect(subscriptionPace({ ...halfway, cooldownSeconds: 60 }, now)).toBe(50)
  expect(subscriptionPace({ ...halfway, stale: true }, now)).toBeNull()
  expect(subscriptionPool([
    halfway,
    full,
    { ...halfway, plan: "plus" },
    { ...halfway, enabled: false },
    { ...halfway, authenticated: false },
    { ...halfway, cooldownSeconds: 60 },
    { ...halfway, hasCapacity: false },
  ], now).expectedRemaining).toBe(62.5)
  expect(subscriptionPool([halfway], now).expectedRemaining).toBe(50)
})

test("pace is omitted for unknown balance or missing, expired, and out-of-window reset times", () => {
  const now = Date.parse("2026-09-10T12:00:00Z")
  const valid = { ...account, resetAt: "2026-09-14T00:00:00Z" }
  for (const resetAt of [null, "invalid", "2026-09-10T12:00:00Z", "2026-09-18T12:00:00Z"]) {
    expect(subscriptionPool([valid, { ...account, resetAt }], now).expectedRemaining).toBeNull()
  }
  expect(subscriptionPool([{ ...valid, stale: true }], now).expectedRemaining).toBeNull()
  expect(subscriptionPool([{ ...valid, remaining: null }], now).expectedRemaining).toBeNull()
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
