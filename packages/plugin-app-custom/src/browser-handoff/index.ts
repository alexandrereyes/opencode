import { Effect, Scope, Stream } from "effect"
import type { Context } from "../context.js"
import { detect } from "./detect.js"
import { limits, sharedRegistry, wire, type Entry, type Registry } from "./registry.js"
import { BrowserHandoffs } from "./rpc.js"

/** The parts of the tool hooks' events this module reads. */
export type Before = {
  readonly tool: string
  readonly sessionID: string
  readonly messageID: string
  readonly id: string
  readonly input: unknown
}
export type After = Before & { readonly status: "completed" | "error" }

/** The server events that end a call without `execute.after`: an interruption skips the hook. */
export type Ended =
  | {
      readonly type:
        | "session.execution.succeeded"
        | "session.execution.failed"
        | "session.execution.interrupted"
        | "session.archived"
        | "session.deleted"
      readonly data: { readonly sessionID: string }
    }
  | {
      readonly type: "session.tool.success" | "session.tool.failed"
      readonly data: { readonly sessionID: string; readonly id: string }
    }

export const endedTypes = [
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
  "session.archived",
  "session.deleted",
  "session.tool.success",
  "session.tool.failed",
] as const

/**
 * One Location's view of browse handoffs (`docs/browser-handoff.md`). `before` records a browse `execute` whose code
 * can hand off and, after `graceMs`, marks it waiting unless it ended; `after` and the events in `endedTypes` remove
 * it. Only the entries this instance recorded are settled and announced here, so every change is announced once.
 */
export function makeHandoffs(input: {
  readonly registry: Registry
  readonly scope: Scope.Scope
  readonly announce: (sessionID: string) => Effect.Effect<void>
  readonly now: () => number
  readonly graceMs?: number
}) {
  const owner = {}
  const graceMs = input.graceMs ?? limits.graceMs
  const settle = (match: (entry: Entry) => boolean) =>
    Effect.forEach(
      [...new Set(input.registry.remove((entry) => entry.owner === owner && match(entry)).map((e) => e.sessionID))],
      input.announce,
      { discard: true },
    )

  const before = (event: Before) =>
    Effect.suspend(() => {
      const message = detect(event.tool, event.input)
      if (message === undefined) return Effect.void
      const id = `brw_${crypto.randomUUID().replaceAll("-", "")}`
      input.registry.add({
        id,
        sessionID: event.sessionID,
        callID: event.id,
        messageID: event.messageID,
        message,
        since: input.now(),
        waiting: false,
        owner,
        input: event.input,
      })
      return Effect.sleep(graceMs).pipe(
        Effect.andThen(
          Effect.suspend(() => (input.registry.reveal(id) ? input.announce(event.sessionID) : Effect.void)),
        ),
        Effect.forkIn(input.scope),
        Effect.asVoid,
      )
    })

  // The hooks pass `execute.after` the input object `execute.before` received; a call of the same code in the same
  // tool part is the fallback when another hook replaced it.
  const after = (event: After) =>
    Effect.suspend(() => {
      if (detect(event.tool, event.input) === undefined) return Effect.void
      const same = (entry: Entry) => entry.sessionID === event.sessionID && entry.callID === event.id
      const exact = input.registry.has((entry) => entry.owner === owner && entry.input === event.input)
      let done = false
      return settle((entry) => {
        if (done || !same(entry)) return false
        const hit = exact ? entry.input === event.input : sameCode(entry.input, event.input)
        if (hit) done = true
        return hit
      })
    })

  const ended = (event: Ended) =>
    Effect.suspend(() => {
      const sessionID = event.data.sessionID
      if (!input.registry.has((entry) => entry.owner === owner && entry.sessionID === sessionID)) return Effect.void
      if (event.type === "session.tool.success" || event.type === "session.tool.failed") {
        const callID = event.data.id
        return settle((entry) => entry.sessionID === sessionID && entry.callID === callID)
      }
      return settle((entry) => entry.sessionID === sessionID)
    })

  return { before, after, ended, owner }
}

const sameCode = (a: unknown, b: unknown) =>
  typeof a === "object" &&
  a !== null &&
  typeof b === "object" &&
  b !== null &&
  (a as { code?: unknown }).code === (b as { code?: unknown }).code

export const registerBrowserHandoffs = Effect.fn("BrowserHandoffs.register")(function* (ctx: Context) {
  const registry = sharedRegistry()
  const scope = yield* Effect.scope
  const registration = yield* ctx.rpc
    .register(BrowserHandoffs.Definition, {
      list: (request) =>
        Effect.sync(() => ({
          data: registry
            .waiting()
            .filter((entry) => request.sessionID === undefined || entry.sessionID === request.sessionID)
            .map(wire),
        })),
    })
    .pipe(Effect.orDie)
  const handoffs = makeHandoffs({
    registry,
    scope,
    now: () => Date.now(),
    announce: (sessionID) =>
      registration.events
        .emit("changed", { sessionID })
        .pipe(Effect.catchCause((cause) => Effect.logWarning("Browser handoff changed event failed", { cause }))),
  })
  yield* ctx.tool.hook("execute.before", handoffs.before)
  yield* ctx.tool.hook("execute.after", handoffs.after)
  yield* ctx.event.subscribe({ types: endedTypes }).pipe(
    Stream.runForEach((event) => handoffs.ended(event as Ended)),
    Effect.catchCause((cause) => Effect.logWarning("Browser handoff event subscription failed", { cause })),
    Effect.forkScoped,
  )
  // A Location that unloads takes its calls with it.
  yield* Effect.addFinalizer(() =>
    Effect.sync(() => registry.remove((entry) => entry.owner === handoffs.owner)).pipe(Effect.asVoid),
  )
})
