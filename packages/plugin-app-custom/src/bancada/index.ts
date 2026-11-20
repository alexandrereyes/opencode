import type { RpcCallContext } from "@opencode/plugin/effect/rpc"
import { Effect } from "effect"
import type { Context } from "../context.js"
import { identity } from "../instance/index.js"
import { hubPassword, linkSettings } from "../live-activity/link.js"
import { BancadaError, makeBancadaClient, stateDirectory } from "./client.js"
import { Bancada } from "./rpc.js"

/**
 * The Bancada of this machine (`docs/bancada.md`). The plugin only relays: every `custom.bancada` call goes to this
 * machine's process, which this instance starts as soon as it loads. A process that is missing or broken makes the
 * Bancada unavailable here, never the server. It runs only with `OPENCODE_BANCADA=1`, which the launchers of the
 * installed servers set (D13): tests and scripts of other packages load this plugin too, and must never start a process
 * in the machine's folder. Off, every call answers `unavailable { reason: "off" }`.
 */
export const registerBancada = Effect.fn("Bancada.register")(function* (
  ctx: Pick<Context, "rpc" | "storage">,
  env: Readonly<Record<string, string | undefined>> = process.env,
) {
  if (env.OPENCODE_BANCADA?.trim() !== "1") {
    const off = "A Bancada está desligada neste servidor (liga com OPENCODE_BANCADA=1)."
    yield* ctx.rpc
      .register(Bancada.Definition, {
        wake: (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        sync: (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        "blob.put": (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        "blob.get": (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
      })
      .pipe(Effect.orDie)
    return
  }

  const run = Effect.runPromiseWith(yield* Effect.context<never>())
  const link = linkSettings(env)
  const client = makeBancadaClient({
    state: stateDirectory(env),
    owner: async () => {
      const server = await run(identity(ctx.storage, env))
      const password = link.target ? await hubPassword(env) : undefined
      return {
        instanceID: server.instanceID,
        name: server.name,
        hub: server.hub,
        ...(link.target && password ? { link: { target: link.target, password } } : {}),
      }
    },
  })
  /** Another server's call, relayed as it came: the process reads it against the protocol and answers or refuses. */
  const relay = (
    method: "sync" | "blob.put" | "blob.get",
    input: Readonly<Record<string, unknown>>,
    context: RpcCallContext<(typeof Bancada.Definition)["methods"]["sync"]>,
  ) =>
    Effect.tryPromise({
      // A long poll holds the call up to its `waitMs`; a chunk of a transfer may take a while on a slow link.
      try: () =>
        client.call<Record<string, unknown>>(
          method,
          input,
          (typeof input.waitMs === "number" ? Math.min(Math.max(input.waitMs, 0), 25_000) : 0) + 30_000,
        ),
      catch: (error) => error,
    }).pipe(Effect.mapError((error) => refused(error, context)))
  yield* ctx.rpc
    .register(Bancada.Definition, {
      wake: (input, context) =>
        Effect.tryPromise({ try: () => client.call<Bancada.Wake>("wake", input), catch: (error) => error }).pipe(
          Effect.mapError((error) => refusal(error, context)),
        ),
      sync: (input, context) => relay("sync", input, context),
      "blob.put": (input, context) => relay("blob.put", input, context),
      "blob.get": (input, context) => relay("blob.get", input, context),
    })
    .pipe(Effect.orDie)

  // The process starts with the plugin, not with the first call: a server that comes back runs its Bancada at once.
  yield* Effect.tryPromise(() => client.call("wake", {})).pipe(
    Effect.catchCause((cause) => Effect.logWarning("the Bancada process did not start", { cause })),
    Effect.forkScoped({ startImmediately: true }),
  )
})

/** The process's refusal between servers, by name; anything else is this machine's Bancada not answering. */
function refused(error: unknown, context: RpcCallContext<(typeof Bancada.Definition)["methods"]["sync"]>) {
  if (error instanceof BancadaError && error.reason === "not_hub") return context.error("not_hub", error.message, {})
  if (error instanceof BancadaError && error.reason === "invalid") return context.error("invalid", error.message, {})
  if (error instanceof BancadaError && error.reason === "protocol_mismatch")
    return context.error("protocol_mismatch", error.message, { expected: Number(error.data?.expected ?? 0) })
  if (error instanceof BancadaError && error.reason === "machine_taken")
    return context.error("machine_taken", error.message, {
      instanceID: String(error.data?.instanceID ?? ""),
      name: String(error.data?.name ?? ""),
    })
  const why = unavailable(error)
  return context.error("unavailable", why.message, why.data)
}

function refusal(error: unknown, context: RpcCallContext<(typeof Bancada.Definition)["methods"]["wake"]>) {
  const why = unavailable(error)
  return context.error("unavailable", why.message, why.data)
}

/** Why this machine's Bancada does not answer: another server owns it, or its process is out. */
function unavailable(error: unknown): { readonly message: string; readonly data: Bancada.Unavailable } {
  if (error instanceof BancadaError && error.reason === "owner")
    return { message: error.message, data: { reason: "owner", ...(error.owner ? { owner: error.owner } : {}) } }
  return {
    message:
      error instanceof BancadaError ? error.message : "O processo da Bancada desta máquina não está respondendo.",
    data: { reason: "process" },
  }
}
