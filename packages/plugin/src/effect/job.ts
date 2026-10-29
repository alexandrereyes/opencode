import type { Effect } from "effect"
import type { BackgroundJob } from "../job.js"

export type { BackgroundJob } from "../job.js"

export interface JobDomain {
  readonly background: () => Effect.Effect<ReadonlyArray<BackgroundJob>>
}
