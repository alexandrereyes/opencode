import type { Context } from "../storage.js"
import { Config, Effect, Schema } from "effect"
import os from "node:os"
import path from "node:path"
import { defaults, load } from "../live-activity/apns.js"
import { sharedHub } from "../live-activity/index.js"
import { makeGateway, type Gateway } from "./gateway.js"
import { Master } from "../master/rpc.js"
import { Voice } from "../voice/rpc.js"
import { Watch } from "./rpc.js"
import { bunSideband, proxyOrigin } from "./voice.js"

/** Cloudflare Access service token the watch sends to `watch-mac.alexandrem.com.br` (never committed). */
export const accessFile = path.join(os.homedir(), ".config/opencode/watch/cf-access-service-token.json")
export const defaultPort = 4192

const Access = Schema.fromJsonString(Schema.Struct({ clientId: Schema.String, clientSecret: Schema.String }))

declare global {
  var opencodeCustomWatchGateway: Gateway | undefined
}

/**
 * The process-wide gateway. Like the Live Activity hub, it lives in a global slot because the plugin module is
 * evaluated again for every Location; the first evaluation's code serves the process until it restarts.
 */
export function sharedGateway() {
  globalThis.opencodeCustomWatchGateway ??= makeGateway({
    port: Config.Int("OPENCODE_WATCH_GATEWAY_PORT").pipe(
      Config.withDefault(defaultPort),
      Effect.orElseSucceed(() => defaultPort),
    ),
    access: Effect.tryPromise(() => Bun.file(accessFile).text()).pipe(
      Effect.flatMap(Schema.decodeUnknownEffect(Access)),
      Effect.mapError(() => new Error("A credencial do Cloudflare Access do relógio não está configurada no Mac.")),
    ),
    apns: load(),
    widgetBundleID: Config.String("OPENCODE_APNS_BUNDLE_ID").pipe(
      Config.withDefault(defaults.bundleID),
      Effect.orElseSucceed(() => defaults.bundleID),
      Effect.map((bundleID) => `${bundleID}.watchkitapp`),
    ),
    proxy: {
      origin: (process.env.OPENCODE_LLM_PROXY_URL ?? proxyOrigin).replace(/\/$/, ""),
      fetch: (request) => fetch(request),
    },
    sideband: bunSideband,
    view: Effect.suspend(() => sharedHub().view),
  })
  return globalThis.opencodeCustomWatchGateway
}

export const registerWatch = Effect.fn("Watch.register")(function* (ctx: Context) {
  const gateway = sharedGateway()
  yield* ctx.rpc
    .register(Watch.Definition, {
      pair: (input, context) =>
        gateway.handlers.pair(input).pipe(
          Effect.mapError((error) => {
            const message = error instanceof Error ? error.message : "Não foi possível parear o relógio."
            return context.error("operation_failed", message, { message })
          }),
        ),
      devices: () => gateway.handlers.devices(),
      revoke: (input) => gateway.handlers.revoke(input),
      stats: () => gateway.handlers.stats(),
    })
    .pipe(Effect.orDie)
  yield* gateway.join({
    ctx: {
      app: ctx.app,
      storage: ctx.storage,
      request: ctx.request,
      session: ctx.session,
      permission: ctx.permission,
      message: ctx.message,
      event: ctx.event,
      instructions: () => ctx.rpc(Voice.Definition).instructions({}).pipe(Effect.map((value) => value.instructions)),
      ensureMaster: () =>
        ctx
          .rpc(Master.Definition)
          .ensure({})
          .pipe(Effect.map((ensured) => ensured.sessionID)),
      memory: {
        context: () => ctx.rpc(Voice.Definition).context({ version: Voice.version, scope: "global" }),
        append: (turns) => ctx.rpc(Voice.Definition).append({ version: Voice.version, scope: "global", turns }),
        end: () => ctx.rpc(Voice.Definition).end({ version: Voice.version, scope: "global" }),
      },
    },
  })
})
