import type { Plugin } from "@opencode/plugin/effect"
import type { Requests } from "./request-times.js"
import type { Storage } from "./storage.js"

/** The host context as this plugin's modules use it: storage with `update`, and pending requests with their times. */
export type Context = Omit<Plugin.Context, "storage" | "request"> & {
  readonly storage: Storage
  readonly request: Requests
}
