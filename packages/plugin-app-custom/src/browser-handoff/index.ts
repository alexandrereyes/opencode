import { Session } from "@opencode/schema/session"
import { Effect, Scope, Stream } from "effect"
import type { Context } from "../context.js"
import { Resources } from "../resources/rpc.js"
import { hubSettings, makeHubClient, type HubClient } from "../resources/supervisor.js"
import { relaySessions } from "../resources/adapters/chrome.js"
import { makeCurrentSessions, pick, sharedCurrentSessions } from "./current.js"
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
  /** The call's browse session: its explicit `session`, else the one `find` found. */
  readonly browse: string
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
 * How a call that `execute.after` reports ended its handoff, from browse's error text (0.0.14; the messages are pinned
 * in `test/browser-handoff.test.ts` against the installed package):
 *
 * - `Handoff timed out after <ms>ms waiting for the user: …` → `timeout`;
 * - `Handoff cancelled because its target detached|crashed: …` (the tab closed or crashed) → `failed`;
 * - `Handoff cancelled because its session was stopped, deleted or reset: …`, `Execute stopped because its caller
 *   disconnected.` (the call was interrupted), `Execute stopped: the session was stopped, deleted or reset`, `Session …
 *   was deleted|reset while this ran, so it was stopped.`, `The user took tab … back (browse toolbar button) while this
 *   script ran, so it was stopped.`, and any abort or interruption → `cancelled`;
 * - anything else (`Execute timed out after …`, an unresponsive browser) → `failed`.
 */
export function afterOutcome(event: After): BrowserHandoffs.Outcome {
  if (event.status === "completed") return "completed"
  const message = event.error?.message ?? ""
  if (/\bHandoff timed out after \d+ms waiting for the user\b/.test(message)) return "timeout"
  if (/\bHandoff cancelled because its target (detached|crashed)\b/.test(message)) return "failed"
  if (
    /\bHandoff cancelled because its session was stopped\b|\bExecute stopped\b|\bso it was stopped\b|\b(abort|interrupt)/i.test(
      message,
    )
  )
    return "cancelled"
  return "failed"
}

/** How a server event that ends a call without `execute.after` ended its handoff. */
export function endedOutcome(event: Ended): BrowserHandoffs.Outcome {
  if (event.type === "session.execution.succeeded" || event.type === "session.tool.success") return "completed"
  if (event.type === "session.execution.failed") return "failed"
  return "cancelled"
}

/**
 * The browse session a call that names none acts on, among `candidates` (`current.ts`), or `undefined` when it cannot
 * be told for sure; `since` is when the call began.
 */
export type FindSession = (candidates: readonly string[], since: number) => Effect.Effect<string | undefined>

/**
 * One Location's view of browse handoffs (`docs/browser-handoff.md`). `before` records a browse `execute` whose code
 * can hand off and, after `graceMs`, registers its resource (on its browse session: the one it names, else the one
 * `find` tells for sure among the agent's possible current ones) and marks it waiting unless it ended; `after` and the
 * events in `endedTypes` remove it. Only the entries this instance recorded are settled and announced here, so every
 * change is announced once. A waiting handoff's end goes out in the contract's
 * order: its resource's viewers end, then `announce` with `ended`, then the resources' change.
 */
export function makeHandoffs(input: {
  readonly registry: Registry
  readonly scope: Scope.Scope
  readonly announce: (sessionID: string, ended?: BrowserHandoffs.Ended) => Effect.Effect<void>
  readonly now: () => number
  readonly graceMs?: number
  readonly resources?: HandoffResources
  readonly find?: FindSession
  /** What each agent's browse calls left current (`current.ts`); the server's shared tracker in production. */
  readonly current?: ReturnType<typeof makeCurrentSessions>
}) {
  const owner = {}
  // What each agent's browse calls left current (`current.ts`), for the calls that name no session.
  const current = input.current ?? makeCurrentSessions()
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

  const start = (
    handoff: Omit<Waiting, "browse"> & { readonly browse?: string; readonly candidates?: readonly string[] },
  ) =>
    Effect.gen(function* () {
      if (!input.registry.has((entry) => entry.id === handoff.id)) return
      const { candidates, ...waiting } = handoff
      const browse =
        waiting.browse ??
        (candidates && input.find && resources ? yield* input.find(candidates, waiting.since) : undefined)
      if (browse !== undefined && resources) {
        opening.add(handoff.id)
        const resourceID = yield* resources
          .open({ ...waiting, browse })
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
      const message = detect(event.tool, event.input)
      if (message === undefined) return Effect.void
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
      const browse = browseSession(event.input)
      // Taken now: a later call of the agent's may change its current session while this one waits.
      const candidates = browse ? undefined : current.candidates(event.sessionID)
      return Effect.sleep(graceMs).pipe(
        Effect.andThen(
          start({
            id,
            sessionID: event.sessionID,
            message,
            since,
            ...(browse ? { browse } : { candidates }),
            ...(event.agent ? { agent: event.agent } : {}),
          }),
        ),
        Effect.forkIn(input.scope),
        Effect.asVoid,
      )
    })

  // The hooks pass `execute.after` the input object `execute.before` received; a call of the same code in the same
  // tool part is the fallback when another hook replaced it.
  const after = (event: After) =>
    Effect.suspend(() => {
      current.observe(event)
      if (detect(event.tool, event.input) === undefined) return Effect.void
      const same = (entry: Entry) => entry.sessionID === event.sessionID && entry.callID === event.id
      const exact = input.registry.has((entry) => entry.owner === owner && entry.input === event.input)
      let done = false
      return settle((entry) => {
        if (done || !same(entry)) return false
        const hit = exact ? entry.input === event.input : sameCode(entry.input, event.input)
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

/** The call's explicit browse `session` (`session_new` id); without one, `FindSession` looks for it. */
export function browseSession(value: unknown) {
  if (typeof value !== "object" || value === null || !("session" in value)) return undefined
  return typeof value.session === "string" && value.session.length > 0 ? value.session : undefined
}

const sameCode = (a: unknown, b: unknown) =>
  typeof a === "object" &&
  a !== null &&
  typeof b === "object" &&
  b !== null &&
  (a as { code?: unknown }).code === (b as { code?: unknown }).code

/** browse's relay as this server reaches it: its port (`OPENCODE_BROWSER_PORT`, 19988 by default) on loopback. */
export function relayEndpoint(env: Record<string, string | undefined> = process.env) {
  const port = Number(env.OPENCODE_BROWSER_PORT)
  return `http://127.0.0.1:${Number.isInteger(port) && port > 0 ? port : 19988}`
}

/** What a browse handoff's resource offers and refuses (`browse-handoff-remoto.md`, section 3). */
export const capabilities = Resources.handoffCapabilities

/**
 * `FindSession` through browse's relay (`relayEndpoint`, the server's own: browse's MCP server runs here and reaches
 * it there): the one candidate an `execute` touched since the call began (`pick`).
 */
export function relayFind(endpoint = relayEndpoint()): FindSession {
  const port = Number(new URL(endpoint).port)
  return (candidates, since) =>
    Effect.tryPromise(() => relaySessions(port)).pipe(
      Effect.map((sessions) => pick(candidates, sessions, since)),
      Effect.tap((found) =>
        found
          ? Effect.void
          : Effect.logInfo("Browser handoff without a resource: its browse session is not certain", { candidates }),
      ),
      Effect.catchCause((cause) =>
        Effect.logWarning("Browser handoff: browse sessions could not be read", { cause }).pipe(Effect.as(undefined)),
      ),
    )
}

/** `HandoffResources` over the resources hub. */
export function hubResources(
  hub: Pick<HubClient, "upsert" | "remove" | "finish" | "announce">,
  root: (sessionID: string) => Effect.Effect<string>,
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
        const resource = yield* attempt("register", () =>
          hub.upsert({
            kind: "chrome",
            meta: { kind: "chrome", cdp: relayEndpoint(), browse: handoff.browse },
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
    find: relayFind(),
    current: sharedCurrentSessions(),
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
