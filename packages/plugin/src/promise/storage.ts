import type { Schema } from "effect"
import type { StorageScanOptions, StorageScanResult } from "../storage.js"

export interface StorageDomain {
  readonly get: (key: string) => Promise<Schema.Json | undefined>
  readonly set: (key: string, value: Schema.Json) => Promise<void>
  readonly remove: (key: string) => Promise<void>
  readonly scan: (options: StorageScanOptions) => Promise<StorageScanResult>
  readonly update: <A>(
    key: string,
    update: (current: Schema.Json | undefined) => readonly [next: Schema.Json, result: A],
  ) => Promise<A>
  readonly adoptLegacy: (key: string) => Promise<boolean>
}
