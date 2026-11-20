import { Result, Schema } from "effect"
import { BancadaProtocol } from "../protocol.js"
import { CoreError, type Core, type Refusal } from "./core.js"
import type { BlobLink } from "./transfers.js"

/**
 * A machine's link to the hub (`docs/bancada.md`, "sync"): `custom.bancada/sync` on the hub's server, authenticated
 * like any client (Basic `opencode:<password>`). One long poll at a time, held by the hub until it has something for
 * this machine; when this machine writes something while it hangs, a short call carries it at once. A refusal (another
 * version, a call the hub cannot read, another server's machine, the password) goes to the core, which decides when
 * the machine is alone; a call that does not get through is tried again after a growing wait.
 */

export const limits = {
  /** How long the hub may hold a call with nothing for this machine. */
  waitMs: 25_000,
  /** Beyond its hold, how long a call may take. */
  callMs: 15_000,
  /** Waits after the first, second and every later failed call in a row. */
  backoffMs: [1_000, 3_000, 10_000],
  /** The goodbye must not hold the process's exit. */
  farewellMs: 2_000,
  /** A chunk of a transfer (1 MiB in Base64) may take this long. */
  blobMs: 120_000,
}

type Answer =
  | { readonly ok: true; readonly output: unknown }
  | { readonly ok: false; readonly refusal: Refusal }
  | { readonly ok: false; readonly reason: string }

const RpcFailure = Schema.Struct({ type: Schema.String, message: Schema.String })
const decodeFailure = Schema.decodeUnknownOption(RpcFailure)
const decodePut = Schema.decodeUnknownResult(BancadaProtocol.BlobPutOutput)
const decodeGet = Schema.decodeUnknownResult(BancadaProtocol.BlobGetOutput)
const refusals = new Set<string>(["protocol_mismatch", "invalid", "not_hub", "machine_taken"])

export function makeLink(input: {
  /** The hub's address (`OPENCODE_SUMMARY_HUB`). */
  readonly target: string
  /** In this process's memory only. */
  readonly password: string
  readonly core: Core
  readonly log: (line: string) => void
  readonly fetch?: typeof fetch
}) {
  const send = input.fetch ?? fetch
  const authorization = `Basic ${Buffer.from(`opencode:${input.password}`).toString("base64")}`
  const state: {
    stopped: boolean
    failures: number
    /** The newest message to the hub the long poll in flight carries. */
    carried: number
    short?: Promise<unknown>
    reason?: string
    abort: AbortController
  } = { stopped: false, failures: 0, carried: 0, abort: new AbortController() }

  const call = async (method: string, body: unknown, timeoutMs: number): Promise<Answer> => {
    const response = await send(`${input.target}/api/rpc/custom.bancada/${method}`, {
      method: "POST",
      headers: { authorization, "content-type": "application/json" },
      body: JSON.stringify({ input: body }),
      signal: AbortSignal.any([AbortSignal.timeout(timeoutMs), state.abort.signal]),
    }).catch(() => undefined)
    if (!response) return { ok: false, reason: "o hub não respondeu" }
    if (response.ok) {
      const json: unknown = await response.json().catch(() => undefined)
      return { ok: true, output: typeof json === "object" && json !== null && "output" in json ? json.output : {} }
    }
    if (response.status === 401) return { ok: false, refusal: { type: "unauthorized", message: "401" } }
    const failure = decodeFailure(await response.json().catch(() => undefined))
    if (failure._tag === "Some" && refusals.has(failure.value.type))
      return { ok: false, refusal: { type: failure.value.type as Refusal["type"], message: failure.value.message } }
    return {
      ok: false,
      reason: failure._tag === "Some" ? `${failure.value.type} (HTTP ${response.status})` : `HTTP ${response.status}`,
    }
  }

  /**
   * One call to the hub, its answer applied; says whether it went through and moved something (rule 12): the hub
   * confirmed what this machine wrote, or brought something, or held the long poll as it should. A call that comes
   * back at once with nothing confirmed counts as a failure for the waits, so the link never spins.
   */
  const exchange = async (waitMs: number) => {
    const before = input.core.queued()
    const startedAt = Date.now()
    const sent = input.core.outgoing(waitMs)
    if (waitMs > 0) state.carried = sent.out.messages.at(-1)?.seq ?? sent.out.base
    const answer = await call("sync", sent, waitMs + limits.callMs)
    if (answer.ok) {
      const received = apply(answer.output)
      if (received === undefined) return false
      if (state.reason !== undefined) input.log("the hub answers again")
      state.reason = undefined
      const confirmed = input.core.queued().acked > before.acked
      const owed = sent.out.messages.length > 0
      const held = waitMs > 0 && Date.now() - startedAt >= waitMs / 2
      return confirmed || (!owed && (received > 0 || held))
    }
    if ("refusal" in answer) {
      input.core.refused(answer.refusal)
      return false
    }
    // Said once per kind of failure, not on every call while the hub is out.
    if (state.reason !== answer.reason) input.log(`the hub did not answer: ${answer.reason}`)
    state.reason = answer.reason
    return false
  }
  /** The hub's answer applied: how many of its messages it carried, or undefined when it could not be read. */
  const apply = (output: unknown) => {
    try {
      return input.core.incoming(output)
    } catch (error) {
      // Another version was already told to the core by `incoming`; an answer this machine cannot read is a refusal.
      if (error instanceof CoreError && error.type === "invalid")
        input.core.refused({ type: "unreadable", message: error.message })
      return undefined
    }
  }

  const loop = async () => {
    while (!state.stopped) {
      const queued = input.core.queued()
      const through = await exchange(queued.written > queued.acked ? 0 : limits.waitMs)
      if (state.stopped) return
      if (through) {
        state.failures = 0
        continue
      }
      state.failures++
      await Bun.sleep(limits.backoffMs[Math.min(state.failures, limits.backoffMs.length) - 1]!)
    }
  }

  const blob = async <A>(
    method: "blob.put" | "blob.get",
    body: unknown,
    decode: (raw: unknown) => Result.Result<A, { readonly message: string }>,
  ) => {
    const answer = await call(method, body, limits.blobMs)
    if (!answer.ok)
      throw new Error("refusal" in answer ? `${answer.refusal.type}: ${answer.refusal.message}` : answer.reason)
    const decoded = decode(answer.output)
    if (Result.isFailure(decoded))
      throw new Error(`the hub's ${method} answer could not be read: ${decoded.failure.message}`)
    return decoded.success
  }

  return {
    /** Runs until `stop`; never rejects. */
    run: () => loop().catch((error: unknown) => input.log(`the link to the hub stopped: ${String(error)}`)),
    /**
     * This machine wrote something for the hub: while a long poll hangs with older messages, a short call carries it
     * now (one at a time).
     */
    nudge: () => {
      if (state.stopped || state.short) return
      const queued = input.core.queued()
      if (queued.written <= state.carried || queued.written <= queued.acked) return
      state.short = exchange(0).finally(() => {
        state.short = undefined
      })
    },
    /**
     * Stops the link with a goodbye (`leaving: "restart"`), so the hub shows "reconciliando" instead of "silenciosa";
     * best effort, at most `limits.farewellMs`.
     */
    stop: async () => {
      state.stopped = true
      state.abort.abort()
      state.abort = new AbortController()
      const sent = input.core.outgoing(0, "restart")
      await call("sync", sent, limits.farewellMs)
    },
    /** The hub's `blob.put` and `blob.get` over HTTP. */
    blobs: {
      put: (body) => blob("blob.put", body, decodePut),
      get: (body) => blob("blob.get", body, decodeGet),
    } satisfies BlobLink,
  }
}

export type Link = ReturnType<typeof makeLink>
