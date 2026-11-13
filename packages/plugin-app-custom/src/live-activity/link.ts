import { Clock, Effect, Option, Schema } from "effect"
import { chmod, mkdir, rm } from "node:fs/promises"
import path from "node:path"
import type { Storage } from "./lifecycle.js"
import { decodeSummary, protocol, type Peer, type Summary } from "./unified.js"

/** Contract: `packages/plugin-app-custom/docs/unified-summary.md`, "Link". */

export const limits = {
  /** How often the writer reads each peer. */
  pollMs: 5_000,
  /** One read's deadline: a peer whose tunnel hangs must not hold the next read. */
  requestMs: 3_000,
  /** A peer's last summary is used this long after it was read; then its part leaves and it shows as offline. */
  staleMs: 60_000,
}

/** The only route of the link. */
export const route = "/summary"
const peersKey = "unified:peers"

/**
 * The link's settings from the server environment. `OPENCODE_SUMMARY_SOCKET`: the Unix socket this server publishes
 * its own summary on. `OPENCODE_SUMMARY_PEERS`: the sockets (comma separated) of the servers whose summaries this one
 * joins into the "Todos" activity. Neither set: nothing here runs, and the Live Activity is this server's alone.
 */
export function linkSettings(env: Readonly<Record<string, string | undefined>> = process.env) {
  const serve = env.OPENCODE_SUMMARY_SOCKET?.trim()
  const peers = (env.OPENCODE_SUMMARY_PEERS ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean)
  return { ...(serve ? { serve } : {}), peers: [...new Set(peers)] }
}

export type LinkSettings = ReturnType<typeof linkSettings>

/** One read of a peer's socket: the decoded JSON body of `GET /summary`, or a failure of any kind. */
export type Read = (socket: string) => Promise<unknown>

export const readSocket: Read = async (socket) => {
  const response = await fetch(`http://summary${route}`, {
    unix: socket,
    signal: AbortSignal.timeout(limits.requestMs),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

/**
 * Publishes this server's own summary on a Unix socket only its user can open (0600 in a 0700 folder): `GET /summary`
 * and nothing else. A socket that already answers belongs to another running server (a sandbox started with
 * production's environment must never take production's place): it is left alone and nothing is served here.
 * `read` answers `undefined` while the hub is not ready (503).
 */
export const serveSummary = Effect.fn("LiveActivity.serveSummary")(function* (input: {
  readonly socket: string
  readonly read: () => Summary | undefined
}) {
  const taken = yield* Effect.promise(() =>
    fetch(`http://summary${route}`, { unix: input.socket, signal: AbortSignal.timeout(limits.requestMs) }).then(
      () => true,
      // A deadline means something holds the socket without answering: still not ours to replace.
      (error: unknown) => error instanceof Error && error.name === "TimeoutError",
    ),
  )
  if (taken)
    return yield* Effect.logWarning(
      "Unified summary socket is already served by another process; this server publishes none",
      { socket: input.socket },
    )
  const served = yield* Effect.tryPromise(async () => {
    await mkdir(path.dirname(input.socket), { recursive: true, mode: 0o700 })
    await rm(input.socket, { force: true })
    const server = Bun.serve({
      unix: input.socket,
      fetch: (request) => {
        if (request.method !== "GET" || new URL(request.url).pathname !== route)
          return new Response(null, { status: 404 })
        const summary = input.read()
        return summary ? Response.json(summary) : new Response(null, { status: 503 })
      },
    })
    await chmod(input.socket, 0o600)
    return server
  }).pipe(Effect.option)
  if (Option.isNone(served))
    return yield* Effect.logWarning("Unified summary socket could not be opened; this server publishes none", {
      socket: input.socket,
    })
  yield* Effect.addFinalizer(() =>
    Effect.promise(() => served.value.stop(true).then(() => rm(input.socket, { force: true }))).pipe(Effect.ignore),
  )
  yield* Effect.logInfo("Unified summary served", { socket: input.socket })
})

const Known = Schema.Record(Schema.String, Schema.Struct({ instanceID: Schema.String, name: Schema.String }))
const decodeKnown = (value: Schema.Json | undefined): typeof Known.Type =>
  Option.getOrElse(Schema.decodeUnknownOption(Known)(value ?? {}), () => ({}))

/**
 * The peers' latest summaries, read every `pollMs`. A peer is known once it answered: its identity is kept in plugin
 * storage, so after a restart with the peer away it still shows as offline. Any failure (no socket, refused, deadline,
 * a body that is not this protocol's summary) just leaves the last good summary to age out after `staleMs`.
 */
export function makePeers(input: {
  readonly sockets: readonly string[]
  readonly storage: Storage
  readonly read?: Read
  /** Called when what `current` answers may have changed. */
  readonly changed: () => void
}) {
  const read = input.read ?? readSocket
  const peers = new Map<
    string,
    { identity?: { instanceID: string; name: string }; summary?: Summary; seenAt?: number; problem?: string }
  >(input.sockets.map((socket) => [socket, {}]))

  const load = input.storage.get(peersKey).pipe(
    Effect.map((value) => {
      const known = decodeKnown(value)
      for (const [socket, peer] of peers) if (known[socket] && !peer.identity) peer.identity = known[socket]
    }),
  )

  const poll = Effect.fnUntraced(function* (socket: string) {
    const peer = peers.get(socket)
    if (!peer) return
    const result = yield* Effect.promise(() =>
      read(socket).then(
        (body) => {
          const decoded = decodeSummary(body)
          if (Option.isSome(decoded)) return { summary: decoded.value }
          const theirs = typeof body === "object" && body !== null && "protocol" in body ? body.protocol : undefined
          return {
            problem:
              theirs === protocol ? "summary does not decode" : `protocol ${String(theirs)}, expected ${protocol}`,
          }
        },
        () => ({ problem: "unreachable" }),
      ),
    )
    const now = yield* Clock.currentTimeMillis
    if ("problem" in result) {
      // Said once per kind of failure, not on every poll of a Mac that sleeps for the night.
      if (peer.problem !== result.problem)
        yield* Effect.logWarning("Unified summary peer is not readable", { socket, reason: result.problem })
      peer.problem = result.problem
      return
    }
    if (peer.problem !== undefined) yield* Effect.logInfo("Unified summary peer is back", { socket })
    const before = peer.summary && peer.seenAt !== undefined && now - peer.seenAt < limits.staleMs ? peer.summary : null
    const identity = { instanceID: result.summary.instanceID, name: result.summary.name }
    if (peer.identity?.instanceID !== identity.instanceID || peer.identity.name !== identity.name)
      yield* input.storage.update(peersKey, (current) => [{ ...decodeKnown(current), [socket]: identity }, undefined])
    peer.problem = undefined
    peer.identity = identity
    peer.summary = result.summary
    peer.seenAt = now
    if (!before || key(before) !== key(result.summary)) input.changed()
  })

  /** Reads every peer forever; run it in the hub's scope. */
  const run = load.pipe(
    Effect.andThen(
      Effect.forEach(input.sockets, poll, { concurrency: "unbounded", discard: true }).pipe(
        Effect.catchCause((cause) => Effect.logWarning("Unified summary poll failed", { cause })),
        Effect.andThen(Effect.sleep(limits.pollMs)),
        Effect.forever,
      ),
    ),
  )

  /** The peers known so far, each with its summary while fresh, and when the next one turns stale. */
  const current = (now: number): { readonly peers: readonly Peer[]; readonly wakeAt?: number } => {
    const fresh = [...peers.values()].flatMap((peer) =>
      peer.seenAt !== undefined && now - peer.seenAt < limits.staleMs ? [peer.seenAt + limits.staleMs] : [],
    )
    return {
      peers: [...peers.values()].flatMap((peer) =>
        peer.identity
          ? [
              {
                ...peer.identity,
                ...(peer.summary && peer.seenAt !== undefined && now - peer.seenAt < limits.staleMs
                  ? { summary: peer.summary }
                  : {}),
              },
            ]
          : [],
      ),
      ...(fresh.length > 0 ? { wakeAt: Math.min(...fresh) } : {}),
    }
  }

  return { run, current, load, poll }
}

export type Peers = ReturnType<typeof makePeers>

/** A summary's identity for change detection: everything but the time it was computed. */
function key(summary: Summary) {
  return JSON.stringify({ ...summary, state: { ...summary.state, updatedAt: 0 } })
}
