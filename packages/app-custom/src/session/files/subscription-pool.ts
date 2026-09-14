import type { Subscriptions } from "@opencode/plugin-app-custom/subscriptions/rpc"

type Account = Subscriptions.Account

export function subscriptionPlanSupported(plan: string | null) {
  return plan === "pro" || plan === "prolite" || plan === "plus"
}

export function subscriptionCapacity(account: Account, now = Date.now()) {
  if (!subscriptionPlanSupported(account.plan)) return "outside" as const
  if (account.stale || account.hasCapacity === null || renewalPassed(account, now))
    return "unconfirmed" as const
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
  // Preserve source order among equally ranked accounts.
  return accounts.toSorted((a, b) => rank(a) - rank(b))
}

export function subscriptionPool(accounts: readonly Subscriptions.Account[], now = Date.now()) {
  const members = accounts.filter(
    (account) => subscriptionPlanSupported(account.plan) && account.enabled && account.authenticated,
  )
  const pro = members.filter((account) => account.plan === "pro")
  const measured = members.filter(
    (account) => !account.stale && account.hasCapacity !== null && !renewalPassed(account, now),
  )
  const ready = members.filter(
    (account) =>
      !account.stale && account.hasCapacity === true && account.cooldownSeconds <= 0 && !renewalPassed(account, now),
  )
  const uncertain = members.some((account) => subscriptionCapacity(account, now) === "unconfirmed")
  const observations = measured.flatMap((account) =>
    account.observedAt === null ? [] : [Date.parse(account.observedAt)],
  )
  const inventories = pro.flatMap((account) => (account.bankedResets ? [account.bankedResets] : []))
  const first = inventories.flatMap((inventory) =>
    inventory.earliestExpiresAt ? [Date.parse(inventory.earliestExpiresAt)] : [],
  )
  const last = inventories.flatMap((inventory) =>
    inventory.latestExpiresAt ? [Date.parse(inventory.latestExpiresAt)] : [],
  )
  return {
    banked:
      pro.length > 0 && inventories.length === pro.length
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
    availablePercent: members.length === 0 ? null : (ready.length / members.length) * 100,
    observedAt: observations.length > 0 && observations.length === measured.length ? Math.min(...observations) : null,
  }
}

function renewalPassed(account: Account, now: number) {
  const observed = account.observedAt
  if (observed === null) return false
  return [account.fiveHourResetAt, account.resetAt].some(
    (reset) => reset !== null && Date.parse(observed) < Date.parse(reset) && Date.parse(reset) <= now,
  )
}
