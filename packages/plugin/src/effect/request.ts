import type { Effect } from "effect"
import type { PendingSnapshot } from "../request.js"

export type { PendingSnapshot } from "../request.js"

export interface RequestDomain {
  readonly pending: () => Effect.Effect<ReadonlyArray<PendingSnapshot>>
}
