import { Config, Effect, Schema } from "effect"
import { FetchHttpClient, HttpClient } from "effect/unstable/http"

// Decode only quota metadata. Admin credentials and OAuth data never cross this boundary.
const Status = Schema.Struct({
  accounts: Schema.Array(
    Schema.Struct({
      account: Schema.Struct({
        id: Schema.String,
        name: Schema.NullOr(Schema.String),
        email: Schema.String,
        enabled: Schema.Boolean,
        planType: Schema.NullOr(Schema.String),
        authenticationState: Schema.String,
      }),
      usage: Schema.NullOr(
        Schema.Struct({
          weeklyPercent: Schema.NullOr(Schema.Finite),
          weeklyResetAt: Schema.NullOr(Schema.String),
          observedAt: Schema.String,
          hasCapacity: Schema.Boolean,
          planType: Schema.NullOr(Schema.String),
        }),
      ),
      usageAgeSeconds: Schema.NullOr(Schema.Finite),
      cooldownSeconds: Schema.Finite,
    }),
  ),
})

export const readSubscriptions = Effect.fn("Subscriptions.read")(function* () {
  const url = yield* Config.string("OPENCODE_LLM_PROXY_URL").pipe(Config.withDefault(""), Effect.orDie)
  if (!url) return { status: "unconfigured" as const, accounts: [] }
  return yield* Effect.gen(function* () {
    const client = yield* HttpClient.HttpClient
    const response = yield* client.get(`${url.replace(/\/$/, "")}/_admin/status`)
    if (response.status !== 200) return { status: "unavailable" as const, accounts: [] }
    const data = yield* Schema.decodeUnknownEffect(Status)(yield* response.json)
    return {
      status: "ok" as const,
      accounts: data.accounts.map((item) => ({
        id: item.account.id,
        name: item.account.name || item.account.email,
        enabled: item.account.enabled,
        plan: item.usage?.planType ?? item.account.planType,
        authenticated: item.account.authenticationState === "Authenticated",
        cooldownSeconds: item.cooldownSeconds,
        remaining:
          item.usage?.weeklyPercent == null ? null : Math.max(0, Math.min(100, 100 - item.usage.weeklyPercent)),
        resetAt: item.usage?.weeklyResetAt ?? null,
        observedAt: item.usage?.observedAt ?? null,
        stale: item.usageAgeSeconds === null || item.usageAgeSeconds < 0 || item.usageAgeSeconds > 65 * 60,
        hasCapacity: item.usage?.hasCapacity ?? null,
      })),
    }
  }).pipe(
    Effect.timeout("8 seconds"),
    Effect.catch(() => Effect.succeed({ status: "unavailable" as const, accounts: [] })),
    Effect.provide(FetchHttpClient.layer),
  )
})
