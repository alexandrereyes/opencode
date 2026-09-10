import type { ServerSubscriptionsOutput } from "@opencode/client/promise"

export function subscriptionPool(accounts: ServerSubscriptionsOutput["accounts"]) {
  const members = accounts.filter((account) => account.plan === "pro" && account.enabled && account.authenticated)
  const measured = members.filter((account) => !account.stale && account.remaining !== null)
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
    ready: members.filter((account) => !account.stale && account.hasCapacity && account.cooldownSeconds <= 0).length,
    // Never present a partial average as the whole pool, or infer capacity from rounded quota alone.
    remaining:
      members.length > 0 && measured.length === members.length
        ? measured.reduce((sum, account) => sum + (account.remaining ?? 0), 0) / members.length
        : null,
    observedAt: observations.length > 0 && observations.length === measured.length ? Math.min(...observations) : null,
  }
}
