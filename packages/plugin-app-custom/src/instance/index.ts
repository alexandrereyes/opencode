import { Effect } from "effect"
import type { Context } from "../context.js"
import { hostName } from "../live-activity/index.js"
import type { Storage } from "../storage.js"
import { Instance } from "./rpc.js"

const key = "instance:id"

/**
 * `custom.instance` (`docs/instance.md`): who this server is, so the apps recognize the same server saved under
 * different addresses and adopt the hub the deployment declares.
 */
export const registerInstance = Effect.fn("Instance.register")(function* (ctx: Pick<Context, "rpc" | "storage">) {
  yield* ctx.rpc.register(Instance.Definition, { get: () => identity(ctx.storage) }).pipe(Effect.orDie)
})

export const identity = Effect.fn("Instance.identity")(function* (
  storage: Pick<Storage, "get" | "update">,
  env: Readonly<Record<string, string | undefined>> = process.env,
) {
  return {
    version: 1,
    instanceID: yield* instanceID(storage),
    name: yield* hostName(env.OPENCODE_HOST_NAME),
    hub: env.OPENCODE_HUB?.trim() === "1",
  } satisfies Instance.Identity
})

/** Made on the first read and never replaced: the storage's `update` is atomic for every Location of this plugin. */
const instanceID = Effect.fnUntraced(function* (storage: Pick<Storage, "get" | "update">) {
  const stored = yield* storage.get(key)
  if (valid(stored)) return stored
  return yield* storage.update(key, (current) => {
    const id = valid(current) ? current : crypto.randomUUID()
    return [id, id]
  })
})

function valid(value: unknown): value is string {
  return typeof value === "string" && value.length > 0
}
