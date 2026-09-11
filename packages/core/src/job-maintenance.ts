export * as JobMaintenance from "./job-maintenance.js"

import { Effect } from "effect"
import { Job } from "./job.js"

/** Called only behind the process admission barrier. Never consumes recovery markers. */
export const pending = Effect.fn("JobMaintenance.pending")(function* (input: {
  jobs: Pick<Job.Interface, "pendingBackground" | "get">
  /** Unknown failures must escape: only authoritative missing/terminal state permits recovery on restart. */
  activity: (recovery: Job.Recovery) => Effect.Effect<"running" | "ended" | "missing", unknown>
}) {
  const records = yield* input.jobs.pendingBackground
  for (const record of records) {
    const current = yield* input.jobs.get(record.id)
    // Same ID can be reused; compare notification identity before trusting a terminal generation.
    if (current?.status === "running") return true
    if (record.status === "completed" || record.status === "error") return true
    if (current && current.notificationID === record.notificationID && current.status !== "cancelled") return true
    if ((yield* input.activity(record.recovery)) === "running") return true
    // A cancelled marker, or running marker with no live owner/shell/child, is restart work.
    // SessionRestart preserves its notification ID, reports interrupted shells, and recovers children.
    // Keeping the marker is essential: deleting it here would lose those outcomes on the next boot.
    yield* Effect.logInfo("background marker retained for restart recovery", {
      jobID: record.id,
      notificationID: record.notificationID,
      recovery: record.recovery.kind,
      status: record.status,
    })
  }
  return false
})
