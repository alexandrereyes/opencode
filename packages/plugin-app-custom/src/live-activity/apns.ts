import { Clock, Config, Effect, Option, Schema } from "effect"
import { createPrivateKey, sign, type KeyObject } from "node:crypto"
import http2 from "node:http2"
import type { LiveActivity } from "./rpc.js"

export const defaults = {
  teamID: "ERRYZ68LX5",
  bundleID: "br.com.alexandrem.opencode",
  /** Apple accepts a provider token for an hour and rejects refreshing it more often than every 20 minutes. */
  tokenMs: 50 * 60_000,
  requestMs: 10_000,
}

export const origins: Record<LiveActivity.Environment, string> = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
}

export type Push = {
  readonly token: string
  readonly environment: LiveActivity.Environment
  readonly priority: 5 | 10
  /** Epoch seconds; the contract sets it to the body's `stale-date`. */
  readonly expiration: number
  readonly body: unknown
  /**
   * APNs push type; Live Activity updates when omitted. Its topic suffix follows Apple's naming for each type; a
   * plain alert (session notifications) uses the bundle ID itself.
   */
  readonly type?: "liveactivity" | "widgets" | "alert"
  /** Bundle ID the topic is built from; the app's own when omitted (a watch widget uses its watch app's). */
  readonly bundleID?: string
}

export type Result =
  | { readonly status: "sent" }
  | { readonly status: "invalid"; readonly reason: string }
  | { readonly status: "failed"; readonly reason: string }

export type Client = {
  readonly send: (push: Push) => Effect.Effect<Result>
  readonly close: Effect.Effect<void>
}

/** APNs credentials from the environment, or `undefined` (push `unconfigured`) when the key or its ID is missing. */
export const load = Effect.fn("LiveActivity.Apns.load")(function* () {
  const keyPath = yield* Config.String("OPENCODE_APNS_KEY_PATH").pipe(Config.withDefault(""))
  const keyID = yield* Config.String("OPENCODE_APNS_KEY_ID").pipe(Config.withDefault(""))
  const teamID = yield* Config.String("OPENCODE_APNS_TEAM_ID").pipe(Config.withDefault(defaults.teamID))
  const bundleID = yield* Config.String("OPENCODE_APNS_BUNDLE_ID").pipe(Config.withDefault(defaults.bundleID))
  // Tests only: a local stand-in for Apple's hosts, so a sandbox can exercise delivery without reaching any device.
  const origin = yield* Config.String("OPENCODE_APNS_ORIGIN").pipe(Config.withDefault(""))
  if (!keyPath || !keyID) return undefined
  const key = yield* Effect.tryPromise(() => Bun.file(keyPath).text()).pipe(
    Effect.map((pem) => createPrivateKey(pem)),
    Effect.tapError((error) => Effect.logWarning("Live Activity APNs key is unreadable; pushes stay off", { error })),
    Effect.option,
  )
  if (Option.isNone(key)) return undefined
  if (origin) yield* Effect.logWarning("APNs requests go to a test origin instead of Apple", { origin })
  return makeClient({ key: key.value, keyID, teamID, bundleID, ...(origin ? { origin: () => origin } : {}) })
}, Effect.orDie)

/**
 * Token-based APNs over HTTP/2: one connection per origin, a provider JWT reused for about 50 minutes. `origin`
 * exists for tests against a local HTTP/2 server; production always uses Apple's hosts.
 */
export function makeClient(input: {
  readonly key: KeyObject
  readonly keyID: string
  readonly teamID: string
  readonly bundleID: string
  readonly origin?: (environment: LiveActivity.Environment) => string
}): Client {
  const sessions = new Map<string, http2.ClientHttp2Session>()
  const jwt = { value: "", issuedAt: -Infinity }

  const connect = (origin: string) => {
    const existing = sessions.get(origin)
    if (existing && !existing.closed && !existing.destroyed) return existing
    const session = http2.connect(origin)
    const forget = () => {
      if (sessions.get(origin) === session) sessions.delete(origin)
    }
    session.on("error", forget)
    session.on("goaway", forget)
    session.on("close", forget)
    session.unref()
    sessions.set(origin, session)
    return session
  }

  const token = (now: number) => {
    if (now - jwt.issuedAt < defaults.tokenMs) return jwt.value
    const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url")
    const unsigned = `${encode({ alg: "ES256", kid: input.keyID })}.${encode({ iss: input.teamID, iat: Math.floor(now / 1000) })}`
    const signature = sign("sha256", Buffer.from(unsigned), { key: input.key, dsaEncoding: "ieee-p1363" })
    jwt.value = `${unsigned}.${signature.toString("base64url")}`
    jwt.issuedAt = now
    return jwt.value
  }

  const send = (push: Push) =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis
      const origin = (input.origin ?? ((environment) => origins[environment]))(push.environment)
      return yield* Effect.tryPromise({
        try: () =>
          request(
            connect(origin),
            {
              ":method": "POST",
              ":path": `/3/device/${push.token}`,
              authorization: `bearer ${token(now)}`,
              "apns-push-type": push.type ?? "liveactivity",
              "apns-topic":
                push.type === "alert"
                  ? (push.bundleID ?? input.bundleID)
                  : `${push.bundleID ?? input.bundleID}.push-type.${push.type ?? "liveactivity"}`,
              "apns-priority": String(push.priority),
              "apns-expiration": String(push.expiration),
              "content-type": "application/json",
            },
            JSON.stringify(push.body),
          ),
        catch: (error) => (error instanceof Error ? error.message : String(error)),
      }).pipe(
        Effect.match({
          onFailure: (reason): Result => ({ status: "failed", reason }),
          onSuccess: (response): Result => {
            if (response.status === 200) return { status: "sent" }
            const reason = readReason(response.body) ?? `HTTP ${response.status}`
            if (response.status === 403 && reason === "ExpiredProviderToken") jwt.issuedAt = -Infinity
            if (response.status === 410 || (response.status === 400 && invalidReasons.has(reason)))
              return { status: "invalid", reason }
            return { status: "failed", reason }
          },
        }),
      )
    })

  return {
    send,
    close: Effect.sync(() => {
      for (const session of sessions.values()) session.close()
      sessions.clear()
    }),
  }
}

const invalidReasons = new Set(["BadDeviceToken", "Unregistered"])

function request(session: http2.ClientHttp2Session, headers: http2.OutgoingHttpHeaders, body: string) {
  return new Promise<{ status: number; body: string }>((resolve, reject) => {
    const stream = session.request(headers)
    const chunks: Buffer[] = []
    const state = { status: 0 }
    stream.setTimeout(defaults.requestMs, () => {
      stream.close(http2.constants.NGHTTP2_CANCEL)
      reject(new Error("APNs request timed out"))
    })
    stream.on("response", (response) => {
      state.status = Number(response[":status"])
    })
    stream.on("data", (chunk: Buffer) => chunks.push(chunk))
    stream.on("end", () => resolve({ status: state.status, body: Buffer.concat(chunks).toString("utf8") }))
    stream.on("error", reject)
    stream.end(body)
  })
}

const readReason = (body: string) =>
  Option.getOrUndefined(
    Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Struct({ reason: Schema.String })))(body),
  )?.reason
