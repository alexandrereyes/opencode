import type { PendingSnapshot } from "../request.js"

export type { PendingSnapshot } from "../request.js"

export interface RequestDomain {
  readonly pending: () => Promise<ReadonlyArray<PendingSnapshot>>
}
