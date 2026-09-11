import type { ServerSubscriptionsOutput } from "@opencode/client/promise"

type Account = ServerSubscriptionsOutput["accounts"][number]

export function subscriptionCapacity(account: Account, now = Date.now()) {
  if (account.plan !== "pro") return "outside" as const
  if (account.stale || account.hasCapacity === null || renewalPassed(account, now))
    return "unconfirmed" as const
  if (!account.hasCapacity) return "unavailable" as const
  return "available" as const
}

export function subscriptionPercentages(remaining: number) {
  const rounded = Math.round(remaining)
  return { remaining: rounded, used: 100 - rounded }
}

export function subscriptionAccounts(accounts: ServerSubscriptionsOutput["accounts"], now = Date.now()) {
  const rank = (account: Account) => {
    if (account.plan !== "pro") return account.plan === "plus" ? 2 : 3
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

export function subscriptionPool(accounts: ServerSubscriptionsOutput["accounts"], now = Date.now()) {
  const members = accounts.filter((account) => account.plan === "pro" && account.enabled && account.authenticated)
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
    // Capacity permission, not a rounded percentage, decides which accounts are available now.
    availableRemaining:
      !uncertain && ready.length > 0
        ? ready.reduce((sum, account) => sum + (account.remaining ?? 0), 0) / ready.length
        : null,
    observedAt: observations.length > 0 && observations.length === measured.length ? Math.min(...observations) : null,
  }
}

function renewalPassed(account: Account, now: number) {
  if (account.resetAt === null || account.observedAt === null) return false
  return Date.parse(account.observedAt) < Date.parse(account.resetAt) && Date.parse(account.resetAt) <= now
}
