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
    yield* ctx.rpc
      .register(Bancada.Definition, {
        wake: (_input, context) =>
          Effect.fail(
            context.error("unavailable", "A Bancada está desligada neste servidor (liga com OPENCODE_BANCADA=1).", {
              reason: "off",
            }),
          ),
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
  yield* ctx.rpc
    .register(Bancada.Definition, {
      wake: (input, context) =>
        Effect.tryPromise({ try: () => client.call<Bancada.Wake>("wake", input), catch: (error) => error }).pipe(
          Effect.mapError((error) => refusal(error, context)),
        ),
    })
    .pipe(Effect.orDie)

  // The process starts with the plugin, not with the first call: a server that comes back runs its Bancada at once.
  yield* Effect.tryPromise(() => client.call("wake", {})).pipe(
    Effect.catchCause((cause) => Effect.logWarning("the Bancada process did not start", { cause })),
    Effect.forkScoped({ startImmediately: true }),
  )
})

function refusal(error: unknown, context: RpcCallContext<(typeof Bancada.Definition)["methods"]["wake"]>) {
  if (error instanceof BancadaError && error.reason === "owner")
    return context.error("unavailable", error.message, {
      reason: "owner",
      ...(error.owner ? { owner: error.owner } : {}),
    })
  return context.error(
    "unavailable",
    error instanceof BancadaError ? error.message : "O processo da Bancada desta máquina não está respondendo.",
    { reason: "process" },
  )
}
