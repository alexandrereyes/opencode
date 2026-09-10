import type { ServerSubscriptionsOutput } from "@opencode/client/promise"

export function subscriptionPool(accounts: ServerSubscriptionsOutput["accounts"]) {
  const members = accounts.filter((account) => account.plan === "pro" && account.enabled && account.authenticated)
  const measured = members.filter((account) => !account.stale && account.remaining !== null)
  const observations = measured.flatMap((account) =>
    account.observedAt === null ? [] : [Date.parse(account.observedAt)],
  )
  return {
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
