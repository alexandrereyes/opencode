import { Clock, Effect, Option, Queue, Schema } from "effect"
import path from "node:path"
import { privateEnv } from "../private-env.js"
import type { Storage } from "./lifecycle.js"
import { Summary, settled, type Peer } from "./unified.js"

/** Contract: `packages/plugin-app-custom/docs/unified-summary.md`, "Link". */

export const limits = {
  /** A summary with work in progress is renewed this often; a parked one is never renewed. */
  heartbeatMs: 15_000,
  /** Changes are sent at most this often, like the `changed` event. */
  minMs: 1_000,
  /** One request's deadline. */
  requestMs: 5_000,
  /** A summary with work in progress not renewed for this long: its server is offline and its work leaves. */
  staleMs: 60_000,
  /** Waits after the first, second and every later failed send in a row. */
  backoffMs: [2_000, 5_000, 15_000],
  /** A server that published nothing for this long is forgotten. */
  forgetMs: 30 * 86_400_000,
  /** The stored copy of an unchanged summary is refreshed this often, so `forgetMs` counts from its last arrival. */
  touchMs: 86_400_000,
  /** The goodbye of a server that stops must not hold its shutdown. */
  leaveMs: 2_000,
}

export const peersKey = "unified:peers"
/** The password of the hub when it is not this server's own; from the private environment (MyCredentials). */
export const passwordVariable = "OPENCODE_SUMMARY_HUB_PASSWORD"

/**
 * The link's settings from the server environment. `OPENCODE_HUB=1`: this server is the hub; it accepts the other
 * servers' summaries and writes the "Todos" activity. `OPENCODE_SUMMARY_HUB`: the hub's address, to which this
 * server sends its own summary. Neither: nothing here runs, and the Live Activity is this server's alone.
 */
export function linkSettings(env: Readonly<Record<string, string | undefined>> = process.env) {
  const target = env.OPENCODE_SUMMARY_HUB?.trim().replace(/\/+$/, "")
  return { hub: env.OPENCODE_HUB?.trim() === "1", ...(target ? { target } : {}) }
}

export type LinkSettings = ReturnType<typeof linkSettings>

/**
 * The password this server presents to the hub, as any client does (Basic `opencode`). `OPENCODE_SUMMARY_HUB_PASSWORD`
 * (private environment first) when the hub's differs; otherwise this server's own, which production's two servers
 * share: the managed service's (`service-custom.json` in the configuration directory), else the runtime's `password`
 * file of a source server. Read from where the server already keeps it; never logged.
 */
export async function hubPassword(env: Readonly<Record<string, string | undefined>> = process.env) {
  const explicit = privateEnv(passwordVariable) ?? env[passwordVariable]
  if (explicit?.trim()) return explicit.trim()
  if (env.OPENCODE_CONFIG_DIR) {
    const service: unknown = await Bun.file(path.join(env.OPENCODE_CONFIG_DIR, "service-custom.json"))
      .json()
      .catch(() => undefined)
    if (
      typeof service === "object" &&
      service !== null &&
      "password" in service &&
      typeof service.password === "string"
    )
      if (service.password.trim()) return service.password.trim()
  }
  if (env.OPENCODE_CUSTOM_HOME) {
    const own = await Bun.file(path.join(env.OPENCODE_CUSTOM_HOME, "password"))
      .text()
      .catch(() => "")
    if (own.trim()) return own.trim()
  }
  return undefined
}

export type Sent = { readonly ok: true } | { readonly ok: false; readonly reason: string }

/** One call of the hub's `custom.summary`; never throws. */
export type Send = (method: "publish" | "leave", input: unknown) => Promise<Sent>

/** The hub's plugin RPC over its normal API, authenticated like every client. */
export function httpSend(target: string, password: () => Promise<string | undefined> = () => hubPassword()): Send {
  return async (method, input) => {
    const secret = await password().catch(() => undefined)
    if (!secret) return { ok: false, reason: "no password for the hub" }
    try {
      const response = await fetch(`${target}/api/rpc/custom.summary/${method}`, {
        method: "POST",
        headers: {
          authorization: `Basic ${Buffer.from(`opencode:${secret}`).toString("base64")}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ input }),
        signal: AbortSignal.timeout(limits.requestMs),
      })
      if (response.ok) return { ok: true }
      if (response.status === 401) return { ok: false, reason: "unauthorized (the hub refused the password)" }
      const body: unknown = await response.json().catch(() => undefined)
      const type = typeof body === "object" && body !== null && "type" in body ? String(body.type) : undefined
      return { ok: false, reason: type ? `${type} (HTTP ${response.status})` : `HTTP ${response.status}` }
    } catch {
      return { ok: false, reason: "unreachable" }
    }
  }
}

/**
 * Sends this server's own summary to the hub, driven by changes: at once when it starts, whenever the summary
 * changes (at most once per `minMs`) and, only while something works here, every `heartbeatMs`, because no event
 * says that a working server fell asleep. A parked summary stays true while the server sleeps and is never renewed.
 * A failed send is tried again after a short growing wait until it gets through. It runs in its own fiber and never
 * holds the hub's loop.
 */
export function makePublisher(input: { readonly read: (now: number) => Summary; readonly send: Send }) {
  const signal = Effect.runSync(Queue.sliding<void>(1))
  const memo = {
    sent: undefined as string | undefined,
    sentAt: -Infinity,
    attemptAt: -Infinity,
    failures: 0,
    reason: undefined as string | undefined,
    delivered: undefined as Summary | undefined,
  }

  const step = Effect.gen(function* () {
    const now = yield* Clock.currentTimeMillis
    const summary = input.read(now)
    const working = summary.state.counts.working > 0
    const key = summaryKey(summary)
    const due = key !== memo.sent || (working && now - memo.sentAt >= limits.heartbeatMs)
    if (!due) {
      const wait = Queue.take(signal)
      return yield* working
        ? wait.pipe(Effect.timeoutOption(Math.max(memo.sentAt + limits.heartbeatMs - now, 1)))
        : wait
    }
    if (now - memo.attemptAt < limits.minMs) return yield* Effect.sleep(memo.attemptAt + limits.minMs - now)
    memo.attemptAt = now
    const result = yield* Effect.promise(() => input.send("publish", summary))
    if (result.ok) {
      if (memo.reason !== undefined) yield* Effect.logInfo("Unified summary reaches the hub again")
      memo.sent = key
      memo.sentAt = now
      memo.failures = 0
      memo.reason = undefined
      memo.delivered = summary
      return
    }
    // Said once per kind of failure, not on every attempt while the hub is away.
    if (memo.reason !== result.reason)
      yield* Effect.logWarning("Unified summary could not be sent to the hub; retrying", { reason: result.reason })
    memo.reason = result.reason
    memo.failures++
    yield* Effect.sleep(limits.backoffMs[Math.min(memo.failures, limits.backoffMs.length) - 1] ?? limits.minMs)
  })

  return {
    /** Sends forever; run it in the hub's scope. */
    run: step.pipe(
      Effect.catchCause((cause) =>
        Effect.logWarning("Unified summary publisher failed", { cause }).pipe(
          Effect.andThen(Effect.sleep(limits.minMs)),
        ),
      ),
      Effect.forever,
    ),
    /** The local state may have changed. */
    changed: () => void Queue.offerUnsafe(signal, undefined),
    /** Tells the hub this server is stopping, when it ever heard from it; best effort and short. */
    leave: Effect.suspend(() =>
      memo.delivered
        ? Effect.promise(() =>
            Promise.race([
              input.send("leave", { protocol: memo.delivered?.protocol, instanceID: memo.delivered?.instanceID }),
              new Promise<void>((resolve) => setTimeout(resolve, limits.leaveMs)),
            ]),
          ).pipe(Effect.asVoid)
        : Effect.void,
    ),
  }
}

export type Publisher = ReturnType<typeof makePublisher>

const Stored = Schema.Array(Schema.Struct({ summary: Summary, receivedAt: Schema.Number }))
const decodeStored = (value: Schema.Json | undefined) =>
  Option.getOrElse(Schema.decodeUnknownOption(Stored)(value ?? []), () => [])
const encodeStored = Schema.encodeSync(Stored)

/**
 * The hub's side: the latest summary each server sent. A summary with work in progress must be renewed within
 * `staleMs`; when it is not, or when the server said it was stopping, the server is offline and only what was left
 * waiting there (requests, failures, unread answers) stays, as last known. A parked summary never expires. That
 * settled part is kept in plugin storage, written only when it changes, so a hub restart does not lose a parked
 * server that has no reason to send again.
 */
export function makeInbox(input: {
  readonly storage: Storage
  /** Called when what `current` answers may have changed. */
  readonly changed: () => void
}) {
  const entries = new Map<
    string,
    { summary: Summary; receivedAt: number; left: boolean; stored: string; storedAt: number }
  >()

  const load = Effect.gen(function* () {
    const now = yield* Clock.currentTimeMillis
    for (const item of decodeStored(yield* input.storage.get(peersKey))) {
      if (now - item.receivedAt >= limits.forgetMs || entries.has(item.summary.instanceID)) continue
      const summary = settled(item.summary)
      entries.set(summary.instanceID, {
        summary,
        receivedAt: item.receivedAt,
        left: false,
        stored: summaryKey(summary),
        storedAt: item.receivedAt,
      })
    }
  })

  const persist = (now: number) =>
    input.storage.update(peersKey, () => [
      encodeStored(
        [...entries.values()]
          .filter((entry) => now - entry.receivedAt < limits.forgetMs)
          .map((entry) => ({ summary: settled(entry.summary), receivedAt: entry.receivedAt })),
      ),
      undefined,
    ])

  const accept = Effect.fnUntraced(function* (summary: Summary) {
    const now = yield* Clock.currentTimeMillis
    const before = entries.get(summary.instanceID)
    const rest = summaryKey(settled(summary))
    const write = !before || before.stored !== rest || now - before.storedAt >= limits.touchMs
    entries.set(summary.instanceID, {
      summary,
      receivedAt: now,
      left: false,
      stored: rest,
      storedAt: write ? now : before.storedAt,
    })
    if (write) yield* persist(now)
    // A renewal that says the same as a summary still in force moves nothing on the card.
    const renewal =
      before !== undefined &&
      !before.left &&
      now - before.receivedAt < limits.staleMs &&
      summaryKey(before.summary) === summaryKey(summary)
    if (!renewal) input.changed()
  })

  const leave = (instanceID: string) =>
    Effect.sync(() => {
      const entry = entries.get(instanceID)
      if (!entry || entry.left) return
      entry.left = true
      input.changed()
    })

  /** Every server heard from, in the order first heard, and when the next working summary turns stale. */
  const current = (now: number): { readonly peers: readonly Peer[]; readonly wakeAt?: number } => {
    const wakes: number[] = []
    const peers = [...entries.values()].flatMap((entry): Peer[] => {
      if (now - entry.receivedAt >= limits.forgetMs) return []
      const working = entry.summary.state.counts.working > 0
      const offline = entry.left || (working && now - entry.receivedAt >= limits.staleMs)
      if (working && !offline) wakes.push(entry.receivedAt + limits.staleMs)
      return [
        {
          instanceID: entry.summary.instanceID,
          name: entry.summary.name,
          summary: offline ? settled(entry.summary) : entry.summary,
          ...(offline ? { offline: true } : {}),
        },
      ]
    })
    return { peers, ...(wakes.length > 0 ? { wakeAt: Math.min(...wakes) } : {}) }
  }

  return { load, accept, leave, current }
}

export type Inbox = ReturnType<typeof makeInbox>

/** A summary's identity for change detection: everything but the time it was computed. */
export function summaryKey(summary: Summary) {
  return JSON.stringify({ ...summary, state: { ...summary.state, updatedAt: 0 } })
}
