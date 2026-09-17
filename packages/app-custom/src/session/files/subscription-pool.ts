import type { Subscriptions } from "@opencode/plugin-app-custom/subscriptions/rpc"

type Account = Subscriptions.Account

export function subscriptionPlanSupported(plan: string | null) {
  return plan === "pro" || plan === "prolite" || plan === "plus"
}

export function subscriptionCapacity(account: Account, now = Date.now()) {
  if (!subscriptionPlanSupported(account.plan)) return "outside" as const
  if (account.stale || account.hasCapacity === null || renewalPassed(account, now)) return "unconfirmed" as const
  if (!account.hasCapacity) return "unavailable" as const
  return "available" as const
}

export function subscriptionPercentages(remaining: number) {
  const rounded = Math.round(remaining)
  return { remaining: rounded, used: 100 - rounded }
}

export function subscriptionAccounts(accounts: readonly Subscriptions.Account[], now = Date.now()) {
  const rank = (account: Account) => {
    if (!subscriptionPlanSupported(account.plan)) return 2
    if (
      account.enabled &&
      account.authenticated &&
      account.cooldownSeconds <= 0 &&
      subscriptionCapacity(account, now) === "available"
    )
      return 0
    return 1
  }
  const planRank = (account: Account) =>
    account.plan === "pro" ? 0 : account.plan === "prolite" ? 1 : account.plan === "plus" ? 2 : 3
  // Preserve source order among equally ranked accounts.
  return accounts.toSorted((a, b) => planRank(a) - planRank(b) || rank(a) - rank(b))
}

export function subscriptionPool(accounts: readonly Subscriptions.Account[], now = Date.now(), plan = "pro") {
  const members = accounts.filter((account) => account.plan === plan && account.enabled && account.authenticated)
  const measured = members.filter(
    (account) => !account.stale && account.remaining !== null && !renewalPassed(account, now),
  )
  const ready = members.filter(
    (account) =>
      !account.stale && account.hasCapacity === true && account.cooldownSeconds <= 0 && !renewalPassed(account, now),
  )
  const uncertain = members.some(
    (account) => account.remaining === null || subscriptionCapacity(account, now) === "unconfirmed",
  )
  const pace = members.flatMap((account) => {
    const value = subscriptionPace(account, now)
    return value === null ? [] : [value]
  })
  const observations = measured.flatMap((account) =>
    account.observedAt === null ? [] : [Date.parse(account.observedAt)],
  )
  const inventories = members.flatMap((account) => (account.bankedResets ? [account.bankedResets] : []))
  const first = inventories.flatMap((inventory) =>
    inventory.earliestExpiresAt ? [Date.parse(inventory.earliestExpiresAt)] : [],
  )
  const last = inventories.flatMap((inventory) =>
    inventory.latestExpiresAt ? [Date.parse(inventory.latestExpiresAt)] : [],
  )
  return {
    banked:
      members.length > 0 && inventories.length === members.length
        ? {
            available: inventories.reduce((sum, inventory) => sum + inventory.available, 0),
            nonExpiring: inventories.reduce((sum, inventory) => sum + inventory.nonExpiring, 0),
            earliest: first.length ? Math.min(...first) : null,
            latest: last.length ? Math.max(...last) : null,
          }
        : null,
    total: members.length,
    measured: measured.length,
    ready: ready.length,
    balance: members.length === 0 ? "empty" : uncertain ? "unknown" : ready.length === 0 ? "unavailable" : "known",
    availableRemaining:
      !uncertain && members.length > 0
        ? members.reduce((sum, account) => sum + (account.remaining ?? 0), 0) / members.length
        : null,
    fiveHourRemaining:
      members.length > 0 &&
      members.every((account) => !account.stale && account.fiveHourRemaining !== null && !renewalPassed(account, now))
        ? members.reduce((sum, account) => sum + (account.fiveHourRemaining ?? 0), 0) / members.length
        : null,
    expectedRemaining:
      !uncertain && members.length > 0 && pace.length === members.length
        ? pace.reduce((sum, value) => sum + value, 0) / pace.length
        : null,
    observedAt: observations.length > 0 && observations.length === measured.length ? Math.min(...observations) : null,
  }
}

export function subscriptionPace(account: Account, now = Date.now()) {
  if (account.remaining === null || subscriptionCapacity(account, now) === "unconfirmed") return null
  const remaining = account.resetAt === null ? NaN : Date.parse(account.resetAt) - now
  const week = 7 * 86_400_000
  return remaining > 0 && remaining <= week ? (remaining / week) * 100 : null
}

function renewalPassed(account: Account, now: number) {
  const observed = account.observedAt
  if (observed === null) return false
  return [account.fiveHourResetAt, account.resetAt].some(
    (reset) => reset !== null && Date.parse(observed) < Date.parse(reset) && Date.parse(reset) <= now,
  )
}
