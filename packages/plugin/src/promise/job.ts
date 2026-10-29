import type { BackgroundJob } from "../job.js"

export type { BackgroundJob } from "../job.js"

export interface JobDomain {
  readonly background: () => Promise<ReadonlyArray<BackgroundJob>>
}
