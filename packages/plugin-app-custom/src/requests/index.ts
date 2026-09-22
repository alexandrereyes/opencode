import { Plugin } from "@opencode/plugin/effect"
import { Permission } from "@opencode/schema/permission"
import { Effect, Schema } from "effect"
import { Requests } from "./rpc.js"

const encodePermission = Schema.encodeSync(Permission.Request)

export const registerRequests = Effect.fn("Requests.register")(function* (ctx: Plugin.Context) {
  yield* ctx.rpc
    .register(Requests.Definition, {
      permissions: () => permissions(ctx.request),
    })
    .pipe(Effect.orDie)
})

export const permissions = Effect.fn("Requests.permissions")(function* (ctx: Plugin.Context["request"]) {
  const snapshots = yield* ctx.pending()
  return snapshots.flatMap((snapshot) => snapshot.permissions.map((request) => encodePermission(request)))
})
