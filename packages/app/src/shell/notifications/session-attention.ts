import type { SessionInfo, SessionNavigationInfo } from "@opencode/client/promise"

export function latestAttention(...times: (number | undefined)[]) {
  const pending = times.filter((time): time is number => time !== undefined)
  return pending.length ? Math.max(...pending) : undefined
}

export function sessionAttention(input: {
  session: SessionInfo
  notifications: readonly { time: number; viewed: boolean }[]
  unreadAt?: number
  permissionAt?: number
  questionAt?: number
  autoApprove?: boolean
}) {
  const viewed = input.session.time.viewed ?? 0
  const idle =
    input.session.outcome === "succeeded" || input.session.outcome === "failed" ? input.session.time.idle : undefined
  // Child completions are internal work; only their pending requests need the user's attention.
  const unreadAt = input.session.parentID
    ? undefined
    : latestAttention(
        input.unreadAt !== undefined && input.unreadAt > viewed ? input.unreadAt : undefined,
        idle !== undefined && idle > viewed ? idle : undefined,
        ...input.notifications
          .filter((notification) => !notification.viewed && notification.time > viewed)
          .map((notification) => notification.time),
      )
  // Navigation is the complete request snapshot. SSE invalidates/refetches that index;
  // incremental request caches can be both incomplete and stale across reconnects.
  const permissionAt = input.autoApprove ? undefined : input.permissionAt
  const questionAt = input.questionAt
  return { unreadAt, permissionAt, questionAt, attention: latestAttention(unreadAt, permissionAt, questionAt) }
}

/** Navigation owns ancestry; partial cache updates may add live metadata, but cannot turn a child into a root. */
export function navigationSession(row: SessionNavigationInfo, cached?: SessionInfo): SessionInfo {
  if (!cached) return row.session
  return {
    ...row.session,
    ...cached,
    parentID: row.session.parentID ?? cached.parentID,
    outcome:
      (cached.time.idle ?? 0) >= (row.session.time.idle ?? 0)
        ? (cached.outcome ?? row.session.outcome)
        : row.session.outcome,
    time: {
      ...row.session.time,
      ...cached.time,
      idle: latestAttention(row.session.time.idle, cached.time.idle),
      viewed: latestAttention(row.session.time.viewed, cached.time.viewed),
    },
  }
}
