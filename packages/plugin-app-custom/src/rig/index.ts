import { Effect, Option, Schema } from "effect"
import type { Context } from "../context.js"
import { Rig } from "./rpc.js"

export const limits = {
  /** `rig status --json` reads one file: past this it is stuck. */
  statusMs: 10_000,
}

const decode = Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Json))

/**
 * `custom.rig` (`docs/rig.md`): the rig's queue for the apps, from the `rig` CLI on this server's PATH. The plugin only
 * relays what the CLI prints.
 */
export const registerRig = Effect.fn("Rig.register")(function* (
  ctx: Pick<Context, "rpc">,
  env: Readonly<Record<string, string | undefined>> = process.env,
) {
  yield* ctx.rpc
    .register(Rig.Definition, {
      status: (_input, context) =>
        status(env).pipe(
          Effect.mapError((failure) => context.error("unavailable", failure.message, { reason: failure.reason })),
        ),
    })
    .pipe(Effect.orDie)
})

/** `rig status --json`, its output as it came once it is JSON; why not otherwise. */
const status = Effect.fnUntraced(function* (env: Readonly<Record<string, string | undefined>>) {
  const rig = Bun.which("rig", { PATH: env.PATH ?? "" })
  if (!rig) return yield* Effect.fail(failure("missing", "rig is not on this server's PATH"))
  const ran = yield* Effect.tryPromise(async () => {
    const child = Bun.spawn([rig, "status", "--json"], {
      // The rig is a compiled Bun binary: with `BUN_BE_BUN` (a server run by `bun`) it would be Bun itself.
      env: Object.fromEntries(Object.entries(env).filter(([name]) => name !== "BUN_BE_BUN")),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
      timeout: limits.statusMs,
    })
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ])
    return { stdout, stderr, code }
  }).pipe(Effect.mapError(() => failure("failed", "rig status --json could not run")))
  const said = ran.stderr.trim().split("\n").at(-1)
  if (ran.code !== 0)
    return yield* Effect.fail(failure("failed", `rig status --json ended with ${ran.code}${said ? `: ${said}` : ""}`))
  const json = decode(ran.stdout)
  if (Option.isNone(json)) return yield* Effect.fail(failure("failed", "rig status --json printed no JSON"))
  return json.value
})

function failure(reason: "missing" | "failed", message: string) {
  return { reason, message }
}
