import { Tool } from "@opencode/schema/tool"
import { Effect, Scope } from "effect"
import { browseName, explicitSession, named } from "../browser-handoff/current.js"
import type { FindSession } from "../browser-handoff/index.js"
import type { HubClient } from "./supervisor.js"
import { browseRefusal } from "./lock.js"

/**
 * A browse session's resource (`chrome:browse:<session>`, `browse-handoff-remoto.md` rev. 2026-11-09): whenever an
 * agent uses the browser, its session's tab shows in Recursos, live, and Alexandre can take control. While he holds it
 * the agents' browse calls on that session are refused; the hub removes the resource once the relay no longer lists the
 * session.
 */

/** browse tools that touch no session's tab: never refused, never registered. */
const global = new Set(["status", "session_list", "session_use", "settings"])

type Event = {
  readonly tool: string
  readonly sessionID: string
  readonly id: string
  readonly input: unknown
  readonly agent?: string
}
type After = Event & { readonly status: "completed" | "error"; readonly result?: { readonly output?: unknown } }

type Call = {
  readonly name: string
  readonly since: number
  readonly explicit?: string
  readonly candidates: readonly string[]
  browse?: string
}

export function makeBrowseResources(input: {
  readonly hub: Pick<HubClient, "upsert" | "remove" | "locks">
  readonly current: { readonly candidates: (sessionID: string) => readonly string[] }
  readonly find: FindSession
  readonly family: (sessionID: string) => Effect.Effect<{ readonly root: string }>
  readonly scope: Scope.Scope
  readonly now: () => number
  /** The relay's endpoint (`relayEndpoint`). */
  readonly endpoint: string
  /** How long a call runs before it counts as using its session (`limits.graceMs` of the handoffs). */
  readonly graceMs: number
}) {
  const calls = new Map<string, Call>()

  const register = (event: Event, call: Call, browse: string, running: boolean) =>
    Effect.gen(function* () {
      const owner = yield* input.family(event.sessionID)
      yield* Effect.tryPromise(() =>
        input.hub.upsert({
          kind: "chrome",
          meta: { kind: "chrome", cdp: input.endpoint, browse },
          owner: {
            sessionID: event.sessionID,
            rootSessionID: owner.root,
            ...(event.agent ? { agent: event.agent } : {}),
          },
          used: true,
          // Never the code: it may hold what the page asks for.
          activity: { call: event.id, command: `browse ${call.name}`, running },
        }),
      ).pipe(Effect.catchCause((cause) => Effect.logWarning("Browse resource: register failed", { browse, cause })))
    })

  /**
   * Refuses a call on a browse session Alexandre controls: the one it names, else any the agent may have current
   * (`current.ts`). A call that keeps running past `graceMs` registers its session as in use: the named one, else the
   * one the relay saw it touch (`find`).
   */
  const before = (event: Event) =>
    Effect.gen(function* () {
      const name = browseName(event.tool)
      if (!name || global.has(name)) return
      const explicit = explicitSession(name, event.input)
      const candidates = name === "session_new" ? [] : explicit ? [explicit] : input.current.candidates(event.sessionID)
      const locks = yield* Effect.promise(() => input.hub.locks())
      const held = (locks ?? []).find(
        (lock) => lock.meta.kind === "chrome" && lock.meta.browse && candidates.includes(lock.meta.browse),
      )
      if (held && held.meta.kind === "chrome" && held.meta.browse)
        return yield* new Tool.Error({ message: browseRefusal(held.meta.browse, explicit === undefined) })
      if (name === "session_delete" || name === "session_new") return
      const call: Call = { name, since: input.now(), candidates, ...(explicit ? { explicit } : {}) }
      calls.set(event.id, call)
      yield* Effect.sleep(input.graceMs).pipe(
        Effect.andThen(
          Effect.gen(function* () {
            if (calls.get(event.id) !== call) return
            const browse = call.explicit ?? (yield* input.find(call.candidates, call.since))
            if (!browse || calls.get(event.id) !== call) return
            call.browse = browse
            yield* register(event, call, browse, true)
          }),
        ),
        Effect.forkIn(input.scope),
      )
    })

  /**
   * Registers the session a call used, as its result names it (or as it was found while it ran), and closes the
   * call's activity. A failed call registers nothing new. `session_delete` removes its resource at once (the hub's
   * probe would within seconds).
   */
  const after = (event: After) =>
    Effect.gen(function* () {
      const name = browseName(event.tool)
      if (!name || global.has(name)) return
      const call = calls.get(event.id)
      calls.delete(event.id)
      if (name === "session_delete") {
        const id = explicitSession(name, event.input)
        if (event.status === "completed" && id)
          yield* Effect.tryPromise(() => input.hub.remove(`chrome:browse:${id}`)).pipe(Effect.ignore)
        return
      }
      const browse =
        event.status === "completed" ? (named(event.result?.output) ?? call?.explicit ?? call?.browse) : call?.browse
      if (!browse) return
      yield* register(event, call ?? { name, since: input.now(), candidates: [] }, browse, false)
    })

  return { before, after }
}
