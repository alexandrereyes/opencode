import type { Context } from "../context.js"
import { Config, Effect, Schema } from "effect"
import os from "node:os"
import path from "node:path"
import { defaults, load } from "../live-activity/apns.js"
import { sharedHub } from "../live-activity/index.js"
import { makeGateway, type Gateway } from "./gateway.js"
import { privateEnv } from "../private-env.js"
import { warmMaster } from "../master/index.js"
import { Master } from "../master/rpc.js"
import { Voice } from "../voice/rpc.js"
import { Watch } from "./rpc.js"
import { bunSideband, proxyOrigin } from "./voice.js"

/** Cloudflare Access service token the watch sends to `watch-mac.alexandrem.com.br` (never committed). */
export const accessFile = path.join(os.homedir(), ".config/opencode/watch/cf-access-service-token.json")
/**
 * The same JSON from MyCredentials, kept by the server in its private environment (`bin/private-env`, manual.json
 * `mycred`) or, outside it, in `process.env`; wins over the file.
 */
export const accessVariable = "OPENCODE_WATCH_ACCESS_JSON"
export const defaultPort = 4192

const Access = Schema.fromJsonString(Schema.Struct({ clientId: Schema.String, clientSecret: Schema.String }))

/**
 * Reads the token at every pairing: the variable first, the file as a fallback while servers still start without
 * the vault. Errors name the source but never carry its content, since the schema's own messages quote the input.
 */
export const readAccess = Effect.fn("Watch.access")(function* (file: string = accessFile) {
  const content =
    privateEnv(accessVariable) ??
    (yield* Config.String(accessVariable).pipe(Config.withDefault(""), Effect.orElseSucceed(() => "")))
  const source = content ? accessVariable : file
  const text = content
    ? content
    : yield* Effect.tryPromise(() => Bun.file(file).text()).pipe(
        Effect.mapError(
          () =>
            new Error(
              `A credencial do Cloudflare Access do relógio não está configurada no Mac: falta ${accessVariable} (manual.json mycred, MyCredentials) e o arquivo ${file}.`,
            ),
        ),
      )
  const access = yield* Schema.decodeUnknownEffect(Access)(text).pipe(
    Effect.mapError(
      () => new Error(`A credencial do Cloudflare Access do relógio em ${source} não é um JSON com clientId e clientSecret.`),
    ),
  )
  yield* Effect.logInfo("Watch Cloudflare Access token read", { source })
  return access
})

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
    access: Effect.suspend(() => readAccess()),
    // The Live Activity hub reports the APNs configuration at startup; the gateway's own load stays quiet.
    apns: load(false),
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
          .ensure({ voice: true })
          .pipe(Effect.map((ensured) => ensured.sessionID)),
      warmMaster: () => warmMaster(ctx),
      memory: {
        context: () => ctx.rpc(Voice.Definition).context({ version: Voice.version, scope: "global" }),
        append: (turns) => ctx.rpc(Voice.Definition).append({ version: Voice.version, scope: "global", turns }),
        end: () => ctx.rpc(Voice.Definition).end({ version: Voice.version, scope: "global" }),
        reset: () => ctx.rpc(Voice.Definition).reset({ version: Voice.version, scope: "global" }),
      },
    },
  })
})
