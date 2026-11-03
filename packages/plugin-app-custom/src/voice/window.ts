export * as VoiceWindow from "./window.js"

import { Clock, Effect, Option, Schema } from "effect"
import type { Storage } from "../storage.js"

/**
 * The span of a voice call that delegated to the Mestra: opened by the call's first `custom.master/ensure` with
 * `voice: true` (iPhone, Mac and watch), taken by the call's memory `end`. Prompts the Mestra received inside it came
 * from that call, so a reply it never voiced can be written to voice memory.
 */
export const key = "voice/window"
/** A window this old belongs to a call that never ended; the next call starts its own. */
export const staleMs = 60 * 60_000

export const Window = Schema.Struct({ sessionID: Schema.String, since: Schema.Number })
export type Window = typeof Window.Type
const decode = Schema.decodeUnknownOption(Window)

/**
 * Keeps the open window, so a call's later requests and a call that ended without `end` keep their start, unless it
 * belongs to a replaced Mestra or is stale.
 */
export const open = Effect.fn("VoiceWindow.open")(function* (storage: Pick<Storage, "get" | "set">, sessionID: string) {
  const now = yield* Clock.currentTimeMillis
  const current = Option.getOrUndefined(decode(yield* storage.get(key)))
  if (current?.sessionID === sessionID && now - current.since < staleMs) return
  yield* storage.set(key, { sessionID, since: now })
})

/** Reads and removes the window in one update, so two `end`s never settle the same call twice. */
export const take = (storage: Pick<Storage, "update">) =>
  storage.update(key, (value) => [undefined, Option.getOrUndefined(decode(value))] as const)
