import { expect, test } from "bun:test"
import { subscriptionPool } from "./subscription-pool"

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
  ).toMatchObject({ total: 2, measured: 2, remaining: 45, ready: 2 })
  expect(subscriptionPool([{ ...account, remaining: 0 }]).ready).toBe(1)
})

test("missing or stale measurements suppress the whole pool percentage", () => {
  for (const missing of [
    { ...account, remaining: null },
    { ...account, stale: true },
  ]) {
    expect(subscriptionPool([account, missing])).toMatchObject({ total: 2, measured: 1, remaining: null })
  }
  expect(subscriptionPool([])).toEqual({
    total: 0,
    measured: 0,
    ready: 0,
    remaining: null,
    observedAt: null,
    banked: null,
  })
})

test("cooldown and capacity affect availability, while quota and oldest observation describe the pool", () => {
  expect(
    subscriptionPool([
      { ...account, cooldownSeconds: 120 },
      { ...account, remaining: 85, hasCapacity: false, observedAt: "2026-09-10T08:01:00Z" },
    ]),
  ).toEqual({
    total: 2,
    measured: 2,
    ready: 0,
    remaining: 45,
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
