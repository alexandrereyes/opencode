import { Tool } from "@opencode/schema/tool"
import { Effect, Scope } from "effect"
import { browseName, browseOwner, callTab, closedGroup, namedTabs } from "../browser-handoff/calls.js"
import type { TabRef } from "./adapters/browse-relay.js"
import type { Lock } from "./hub/hub.js"
import { browseRefusal, namesLockedTab } from "./lock.js"
import type { HubClient } from "./supervisor.js"

/**
 * An OpenCode session's browse resource (`chrome:browse:<owner>`, `browse-handoff-remoto.md` rev. 2026-11-22):
 * whenever an agent uses the browser, the tab it works in shows in Recursos, live, and Alexandre can take control. While
 * he holds it the session's browse calls, and any call naming one of its tabs, are refused; the hub removes the
 * resource once none of its tabs is open. browse 0.1.5 lets every agent use every tab, so the resource holds the tabs
 * its session's calls named or opened (the hub keeps them, `Entry.tabs`).
 */

/**
 * How long a browse call waits for the hub: its locks before it runs, a registration after (which then goes on
 * without the call). The shell's lock check waits longer (`adminTimeout`); a browse call is the agent's main tool.
 */
export const hubTimeouts = { locks: 1_500, write: 2_000 } as const

type Event = {
  readonly tool: string
  readonly sessionID: string
  readonly id: string
  readonly input: unknown
  readonly agent?: string
}
type After = Event & { readonly status: "completed" | "error"; readonly result?: { readonly output?: unknown } }

type Call = { readonly name: string; registered: boolean }

/** browse tools that touch no tab: never refused, never registered (`tabs` only while it lists). */
function touchesNoTab(name: string, input: unknown) {
  if (name === "status" || name === "settings") return true
  if (name !== "tabs") return false
  const action = typeof input === "object" && input !== null && "action" in input ? input.action : undefined
  return action === undefined || action === "list"
}

export function makeBrowseResources(input: {
  readonly hub: Pick<HubClient, "upsert" | "locks">
  readonly family: (sessionID: string) => Effect.Effect<{ readonly root: string }>
  readonly scope: Scope.Scope
  /** The relay's endpoint (`relayEndpoint`), the resource's `meta.cdp`. */
  readonly endpoint: () => Promise<string>
  /** How long a call runs before it counts as using its tab (`limits.graceMs` of the handoffs). */
  readonly graceMs: number
  /** How long a browse call waits for the hub's locks (`hubTimeouts`); tests shorten it. */
  readonly timeouts?: { readonly locks: number; readonly write: number }
}) {
  const calls = new Map<string, Call>()
  const timeouts = input.timeouts ?? hubTimeouts

  /**
   * The hub's locks, or `[]` when it does not answer in time, refuses or fails: a hub that is down, slow or remote and
   * unreachable never refuses or delays the agents' browse calls; it only lets them run unchecked, with a warning.
   */
  const locks = (event: Event) =>
    Effect.tryPromise(() => input.hub.locks()).pipe(
      Effect.timeout(timeouts.locks),
      Effect.flatMap((found) =>
        found === undefined ? Effect.fail(new Error("the remote hub did not answer")) : Effect.succeed(found),
      ),
      Effect.catchCause((cause) =>
        Effect.logWarning("Browse resource: hub locks unreadable; the call runs without its lock check", {
          call: event.id,
          cause,
        }).pipe(Effect.as([] as Lock[])),
      ),
    )

  /**
   * Registers the session's resource as used by the call, on `tab` when the call tells one (a call without one keeps
   * the tab the resource has). The hub adds the tab to the resource's own (a chosen id becomes browse's integer) and
   * takes it from any other session's. A write never holds the agent's call: past `timeouts.write` it goes on
   * unawaited.
   */
  const register = (event: Event, name: string, tab: TabRef | undefined, running: boolean) =>
    Effect.gen(function* () {
      const owner = yield* input.family(event.sessionID)
      const cdp = yield* Effect.promise(input.endpoint)
      const browse = browseOwner(event.sessionID)
      yield* Effect.tryPromise(() =>
        input.hub.upsert({
          kind: "chrome",
          meta: { kind: "chrome", cdp, browse, ...(tab === undefined ? {} : { targetID: String(tab) }) },
          owner: {
            sessionID: event.sessionID,
            rootSessionID: owner.root,
            ...(event.agent ? { agent: event.agent } : {}),
          },
          used: true,
          // Never the arguments: they may hold what the page asks for.
          activity: { call: event.id, command: `browse ${name}`, running },
        }),
      ).pipe(
        Effect.timeout(timeouts.write),
        Effect.asVoid,
        Effect.catchCause((cause) => Effect.logWarning("Browse resource: register failed", { browse, cause })),
      )
    })

  /**
   * Refuses a call while Alexandre controls the session's resource (any call that touches a tab) or a tab the call
   * names (any session's). A call that names its tab and keeps running past `graceMs` registers the resource as in use
   * on it; one that opens its tab registers when it ends.
   */
  const before = (event: Event) =>
    Effect.gen(function* () {
      const name = browseName(event.tool)
      if (!name || touchesNoTab(name, event.input)) return
      const browse = browseOwner(event.sessionID)
      const held = (yield* locks(event)).filter((lock) => lock.meta.kind === "chrome" && lock.meta.browse !== undefined)
      if (held.some((lock) => lock.meta.kind === "chrome" && lock.meta.browse === browse))
        return yield* new Tool.Error({ message: browseRefusal("own") })
      const named = namedTabs(name, event.input)
      const group = closedGroup(name, event.input)
      if (held.some((lock) => namesLockedTab(lock, named, group)))
        return yield* new Tool.Error({ message: browseRefusal("other") })
      const tab = callTab(name, event.input)
      if (tab === undefined) return
      const call: Call = { name, registered: false }
      calls.set(event.id, call)
      yield* Effect.sleep(input.graceMs).pipe(
        Effect.andThen(
          Effect.suspend(() => {
            if (calls.get(event.id) !== call) return Effect.void
            call.registered = true
            return register(event, name, tab, true)
          }),
        ),
        Effect.forkIn(input.scope),
      )
    })

  /**
   * Registers the tab a call used, as it names it or its result opened, and closes the call's activity. A failed call
   * registers nothing new.
   */
  const after = (event: After) =>
    Effect.gen(function* () {
      const name = browseName(event.tool)
      if (!name || touchesNoTab(name, event.input)) return
      const call = calls.get(event.id)
      calls.delete(event.id)
      if (event.status !== "completed") {
        if (call?.registered) yield* register(event, name, undefined, false)
        return
      }
      const tab = callTab(name, event.input, event.result?.output)
      if (tab === undefined && !call?.registered) return
      yield* register(event, name, tab, false)
    })

  return { before, after }
}
