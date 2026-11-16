import { Session } from "@opencode/schema/session"
import { Effect, Scope, Stream } from "effect"
import type { Context } from "../context.js"
import { Resources } from "../resources/rpc.js"
import { hubSettings, makeHubClient, type HubClient } from "../resources/supervisor.js"
import { relayEndpoint } from "../resources/adapters/browse-relay.js"
import { browseOwner } from "./calls.js"
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
  readonly agent?: string
}
export type After = Before & {
  readonly status: "completed" | "error"
  readonly error?: { readonly message: string }
  readonly result?: { readonly output?: unknown }
}

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

/** A waiting handoff as its resource needs it. */
export type Waiting = Pick<Entry, "id" | "sessionID" | "message" | "since"> & {
  /** browse's owner of the session's tabs (`browseOwner`). */
  readonly browse: string
  /** The tab the call waits on (`handoff`'s and `demonstrate`'s `tab`). */
  readonly tab: number
  readonly agent?: string
}

/**
 * The resource of a handoff that waits (`docs/browse-handoff-remoto.md`); the resources hub in production. Failures are
 * the port's to absorb: a handoff without a resource still waits and is still announced.
 */
export interface HandoffResources {
  /** Registers it as the handoff starts waiting; `undefined` when it gets none (no relay, no tab, an older hub). */
  readonly open: (handoff: Waiting) => Effect.Effect<string | undefined>
  /** Ends it: its viewers get `end { reason }` and it leaves the hub, without a resources event yet. */
  readonly close: (resourceID: string, outcome: BrowserHandoffs.Outcome) => Effect.Effect<void>
  /** `rpc.custom.resources.changed` for it, once the handoff's own end is announced. */
  readonly announce: (resourceID: string) => Effect.Effect<void>
}

/**
 * How a call that `execute.after` reports ended its handoff (browse 0.1.0). A call that returns ended with Continue
 * (`{"outcome":"continued","tab":…}`); any other outcome makes browse fail it with its JSON as the error text, which
 * the MCP tool reports as is:
 *
 * - `{"outcome":"timeout",…}` (its 10 minutes, or the call's `timeoutSeconds`) → `timeout`;
 * - `{"outcome":"cancelled",…}` (another handoff replaced it on the tab) → `cancelled`;
 * - `{"outcome":"closed",…}` (the tab went away) → `failed`;
 * - the relay stopping the call (`The call was cancelled by its client.`, `… exited, so it was stopped.`, `… so this
 *   was stopped.`) and any abort or interruption → `cancelled`;
 * - anything else (an unresponsive browser, the relay going away, a refused tab) → `failed`.
 */
export function afterOutcome(event: After): BrowserHandoffs.Outcome {
  if (event.status === "completed") return "completed"
  const message = event.error?.message ?? ""
  const outcome = /"outcome"\s*:\s*"(\w+)"/.exec(message)?.[1]
  if (outcome === "timeout") return "timeout"
  if (outcome === "cancelled") return "cancelled"
  if (outcome === "closed") return "failed"
  if (/\bcancelled by its client\b|\bwas stopped\b|\b(abort|interrupt)/i.test(message)) return "cancelled"
  return "failed"
}

/** How a server event that ends a call without `execute.after` ended its handoff. */
export function endedOutcome(event: Ended): BrowserHandoffs.Outcome {
  if (event.type === "session.execution.succeeded" || event.type === "session.tool.success") return "completed"
  if (event.type === "session.execution.failed") return "failed"
  return "cancelled"
}

/**
 * One Location's view of browse handoffs (`docs/browser-handoff.md`). `before` records a browse `handoff` or
 * `demonstrate` call and, after `graceMs`, registers its resource (the session's browse resource, on the call's tab)
 * and marks it waiting unless it ended; `after` and the events in `endedTypes` remove it. Only the entries this
 * instance recorded are settled and announced here, so every change is announced once. A waiting handoff's end goes out
 * in the contract's order: its resource's viewers end, then `announce` with `ended`, then the resources' change.
 */
export function makeHandoffs(input: {
  readonly registry: Registry
  readonly scope: Scope.Scope
  readonly announce: (sessionID: string, ended?: BrowserHandoffs.Ended) => Effect.Effect<void>
  readonly now: () => number
  readonly graceMs?: number
  readonly resources?: HandoffResources
}) {
  const owner = {}
  const graceMs = input.graceMs ?? limits.graceMs
  const resources = input.resources
  // Calls whose resource is being registered, and how those that ended meanwhile ended.
  const opening = new Set<string>()
  const outcomes = new Map<string, BrowserHandoffs.Outcome>()

  const end = (entry: Entry, outcome: BrowserHandoffs.Outcome) =>
    Effect.gen(function* () {
      const resourceID = entry.resourceID
      if (resourceID && resources) yield* resources.close(resourceID, outcome)
      yield* input.announce(entry.sessionID, { id: entry.id, ...(resourceID ? { resourceID } : {}), outcome })
      if (resourceID && resources) yield* resources.announce(resourceID)
    })

  const settle = (match: (entry: Entry) => boolean, outcome: BrowserHandoffs.Outcome) =>
    Effect.suspend(() => {
      const removed = input.registry.remove((entry) => entry.owner === owner && match(entry))
      for (const entry of removed) if (opening.has(entry.id)) outcomes.set(entry.id, outcome)
      return Effect.forEach(
        removed.filter((entry) => entry.waiting),
        (entry) => end(entry, outcome),
        { discard: true },
      )
    })

  const start = (handoff: Omit<Waiting, "tab"> & { readonly tab?: number }) =>
    Effect.gen(function* () {
      if (!input.registry.has((entry) => entry.id === handoff.id)) return
      const tab = handoff.tab
      if (tab !== undefined && resources) {
        opening.add(handoff.id)
        const resourceID = yield* resources
          .open({ ...handoff, tab })
          .pipe(Effect.ensuring(Effect.sync(() => opening.delete(handoff.id))))
        const outcome = outcomes.get(handoff.id)
        outcomes.delete(handoff.id)
        // The call ended while its resource was registered: nobody heard of either, so the resource goes quietly.
        if (resourceID && !input.registry.attach(handoff.id, resourceID)) {
          yield* resources.close(resourceID, outcome ?? "cancelled")
          return yield* resources.announce(resourceID)
        }
      }
      if (input.registry.reveal(handoff.id)) yield* input.announce(handoff.sessionID)
    })

  const before = (event: Before) =>
    Effect.suspend(() => {
      const detected = detect(event.tool, event.input)
      if (detected === undefined) return Effect.void
      const message = detected.message
      const id = `brw_${crypto.randomUUID().replaceAll("-", "")}`
      const since = input.now()
      input.registry.add({
        id,
        sessionID: event.sessionID,
        callID: event.id,
        messageID: event.messageID,
        message,
        since,
        waiting: false,
        owner,
        input: event.input,
      })
      return Effect.sleep(graceMs).pipe(
        Effect.andThen(
          start({
            id,
            sessionID: event.sessionID,
            message,
            since,
            browse: browseOwner(event.sessionID),
            ...(detected.tab === undefined ? {} : { tab: detected.tab }),
            ...(event.agent ? { agent: event.agent } : {}),
          }),
        ),
        Effect.forkIn(input.scope),
        Effect.asVoid,
      )
    })

  // The hooks pass `execute.after` the input object `execute.before` received; a call with the same message and tab in
  // the same tool part is the fallback when another hook replaced it.
  const after = (event: After) =>
    Effect.suspend(() => {
      if (detect(event.tool, event.input) === undefined) return Effect.void
      const same = (entry: Entry) => entry.sessionID === event.sessionID && entry.callID === event.id
      const exact = input.registry.has((entry) => entry.owner === owner && entry.input === event.input)
      let done = false
      return settle((entry) => {
        if (done || !same(entry)) return false
        const hit = exact ? entry.input === event.input : sameRequest(entry.input, event.input)
        if (hit) done = true
        return hit
      }, afterOutcome(event))
    })

  const ended = (event: Ended) =>
    Effect.suspend(() => {
      const sessionID = event.data.sessionID
      if (!input.registry.has((entry) => entry.owner === owner && entry.sessionID === sessionID)) return Effect.void
      if (event.type === "session.tool.success" || event.type === "session.tool.failed") {
        const callID = event.data.id
        return settle((entry) => entry.sessionID === sessionID && entry.callID === callID, endedOutcome(event))
      }
      return settle((entry) => entry.sessionID === sessionID, endedOutcome(event))
    })

  /** A Location that unloads takes its calls with it. */
  const unload = settle(() => true, "cancelled")

  return { before, after, ended, unload, owner }
}

const sameRequest = (a: unknown, b: unknown) =>
  typeof a === "object" &&
  a !== null &&
  typeof b === "object" &&
  b !== null &&
  (a as { message?: unknown }).message === (b as { message?: unknown }).message &&
  (a as { tab?: unknown }).tab === (b as { tab?: unknown }).tab

/** What a browse handoff's resource offers and refuses (`browse-handoff-remoto.md`, section 3). */
export const capabilities = Resources.handoffCapabilities

/** `HandoffResources` over the resources hub; `endpoint` is the browse relay's (`meta.cdp`). */
export function hubResources(
  hub: Pick<HubClient, "upsert" | "remove" | "finish" | "announce">,
  root: (sessionID: string) => Effect.Effect<string>,
  endpoint: () => Promise<string> = () => relayEndpoint(),
): HandoffResources {
  const attempt = <A>(what: string, run: () => Promise<A>) =>
    Effect.tryPromise(run).pipe(
      Effect.catchCause((cause) =>
        Effect.logWarning(`Browser handoff resource: ${what} failed`, { cause }).pipe(Effect.as(undefined)),
      ),
    )
  return {
    open: (handoff) =>
      Effect.gen(function* () {
        const rootSessionID = yield* root(handoff.sessionID)
        const cdp = yield* Effect.promise(endpoint)
        const resource = yield* attempt("register", () =>
          hub.upsert({
            kind: "chrome",
            meta: { kind: "chrome", cdp, browse: handoff.browse, targetID: String(handoff.tab) },
            purpose: handoff.message,
            owner: {
              sessionID: handoff.sessionID,
              rootSessionID,
              ...(handoff.agent ? { agent: handoff.agent } : {}),
            },
            used: true,
            capabilities,
            handoff: { id: handoff.id, sessionID: handoff.sessionID, message: handoff.message, since: handoff.since },
          }),
        )
        if (!resource) return undefined
        // A hub from before this contract ignores `handoff` and would serve the tab without its locks: never offer it.
        if (resource.handoff?.id !== handoff.id || resource.capabilities?.navigation !== false) {
          yield* attempt("remove an unlocked registration", () => hub.remove(resource.id))
          return undefined
        }
        return resource.id
      }),
    close: (resourceID, outcome) =>
      attempt("end", () => hub.finish(resourceID, Resources.handoffEndReasons[outcome])).pipe(Effect.asVoid),
    announce: (resourceID) => attempt("announce", () => hub.announce([resourceID])).pipe(Effect.asVoid),
  }
}

export const registerBrowserHandoffs = Effect.fn("BrowserHandoffs.register")(function* (
  ctx: Context,
  hub: HubClient = makeHubClient(hubSettings()),
) {
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
  const roots = new Map<string, string>()
  const root = (sessionID: string): Effect.Effect<string> =>
    Effect.gen(function* () {
      const cached = roots.get(sessionID)
      if (cached) return cached
      const session = yield* ctx.session.get({ sessionID: Session.ID.make(sessionID) })
      const found = session.parentID ? yield* root(session.parentID) : sessionID
      roots.set(sessionID, found)
      return found
    }).pipe(Effect.catchCause(() => Effect.succeed(sessionID)))
  const handoffs = makeHandoffs({
    registry,
    scope,
    now: () => Date.now(),
    resources: hubResources(hub, root),
    announce: (sessionID, ended) =>
      registration.events
        .emit("changed", { sessionID, ...(ended ? { ended } : {}) })
        .pipe(Effect.catchCause((cause) => Effect.logWarning("Browser handoff changed event failed", { cause }))),
  })
  yield* ctx.tool.hook("execute.before", handoffs.before)
  yield* ctx.tool.hook("execute.after", handoffs.after)
  yield* ctx.event.subscribe({ types: endedTypes }).pipe(
    Stream.runForEach((event) => handoffs.ended(event as Ended)),
    Effect.catchCause((cause) => Effect.logWarning("Browser handoff event subscription failed", { cause })),
    Effect.forkScoped,
  )
  yield* Effect.addFinalizer(() => handoffs.unload)
})
