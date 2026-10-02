import { Plugin } from "@opencode/plugin/effect"
import { Config, Effect, Schema } from "effect"
import { FetchHttpClient, HttpClient, HttpClientRequest } from "effect/unstable/http"
import { Subscriptions } from "./rpc.js"

// Decode only quota metadata. Admin credentials and OAuth data never cross this boundary.
const Usage = Schema.NullOr(
  Schema.Struct({
    fiveHourPercent: Schema.optional(Schema.NullOr(Schema.Finite)),
    fiveHourResetAt: Schema.optional(Schema.NullOr(Schema.String)),
    weeklyPercent: Schema.NullOr(Schema.Finite),
    weeklyResetAt: Schema.NullOr(Schema.String),
    observedAt: Schema.String,
    hasCapacity: Schema.Boolean,
    planType: Schema.NullOr(Schema.String),
    // Paid ChatGPT credits; proxies before the credit fallback omit it.
    credits: Schema.optional(Schema.NullOr(Schema.Struct({ balance: Schema.NullOr(Schema.Finite) }))),
  }),
)

const BankedResets = Schema.Struct({
  available: Schema.Finite,
  earliestExpiresAt: Schema.NullOr(Schema.String),
  latestExpiresAt: Schema.NullOr(Schema.String),
  nonExpiring: Schema.Finite,
})

const Automation = Schema.Struct({ enabled: Schema.Boolean })

const AutomationFields = { resetAutomation: Schema.optional(Automation) }

const Status = Schema.Struct({
  ...AutomationFields,
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
      usage: Usage,
      usageAgeSeconds: Schema.NullOr(Schema.Finite),
      cooldownSeconds: Schema.Finite,
      bankedResets: Schema.optional(Schema.NullOr(BankedResets)),
    }),
  ),
})

const AnthropicStatus = Schema.Struct({
  ...AutomationFields,
  accounts: Schema.Array(
    Schema.Struct({
      account: Schema.Struct({
        id: Schema.String,
        name: Schema.NullOr(Schema.String),
        email: Schema.String,
        enabled: Schema.Boolean,
        subscriptionTier: Schema.NullOr(Schema.String),
        authenticationState: Schema.String,
      }),
      usage: Usage,
      usageAgeSeconds: Schema.NullOr(Schema.Finite),
      cooldownSeconds: Schema.Finite,
      inventory: Schema.optional(
        Schema.NullOr(
          Schema.Struct({
            grants: Schema.Array(
              Schema.Struct({
                resetsLeft: Schema.Finite,
                endsAt: Schema.optional(Schema.NullOr(Schema.String)),
                paused: Schema.Boolean,
              }),
            ),
          }),
        ),
      ),
    }),
  ),
})

export const registerSubscriptions = Effect.fn("Subscriptions.register")(function* (ctx: Plugin.Context) {
  yield* ctx.rpc
    .register(Subscriptions.Definition, {
      list: () => read(),
      setAutomation: (input, context) =>
        writeAutomation(input).pipe(
          Effect.flatMap((automation) =>
            automation
              ? Effect.succeed(automation)
              : Effect.fail(context.error("update_failed", "The LLM proxy did not accept the change", {})),
          ),
        ),
      consumeReset: (input, context) =>
        consumeReset(input).pipe(
          Effect.flatMap((result) =>
            result.status === "ok"
              ? Effect.succeed(result.result)
              : Effect.fail(context.error(result.status, RESET_FAILURES[result.status], {})),
          ),
        ),
    })
    .pipe(Effect.orDie)
})

export const read = Effect.fn("Subscriptions.read")(function* () {
  const url = yield* Config.string("OPENCODE_LLM_PROXY_URL").pipe(Config.withDefault(""), Effect.orDie)
  if (!url)
    return {
      status: "unconfigured" as const,
      accounts: [],
      automation: null,
      anthropic: { status: "disabled" as const, accounts: [], automation: null },
    }
  const base = url.replace(/\/$/, "")
  const [codex, anthropic] = yield* Effect.all([readCodex(base), readAnthropic(base)], { concurrency: 2 })
  return { status: codex.status, accounts: codex.accounts, automation: codex.automation, anthropic }
})

// Resolves to null when the proxy is unconfigured, unreachable, or rejects the change.
export const writeAutomation = Effect.fn("Subscriptions.writeAutomation")(function* (input: {
  provider: "codex" | "anthropic"
  enabled: boolean
}) {
  const url = yield* Config.string("OPENCODE_LLM_PROXY_URL").pipe(Config.withDefault(""), Effect.orDie)
  if (!url) return null
  const path = input.provider === "codex" ? "/_admin/banked-resets" : "/_admin/anthropic/banked-resets"
  return yield* Effect.gen(function* () {
    const client = yield* HttpClient.HttpClient
    const response = yield* client.execute(
      HttpClientRequest.put(`${url.replace(/\/$/, "")}${path}`).pipe(
        HttpClientRequest.bodyJsonUnsafe({ enabled: input.enabled }),
      ),
    )
    if (response.status !== 200) return null
    const data = yield* Schema.decodeUnknownEffect(Automation)(yield* response.json)
    return { enabled: data.enabled }
  }).pipe(
    Effect.timeout("15 seconds"),
    Effect.orElseSucceed(() => null),
    Effect.provide(FetchHttpClient.layer),
  )
})

const RESET_FAILURES = {
  no_credit: "The account has no banked reset available",
  busy: "The account is already applying a reset",
  consume_failed: "The LLM proxy could not apply the reset",
}

const ResetResponse = Schema.Struct({
  code: Schema.String,
  windowsReset: Schema.Finite,
  succeeded: Schema.Boolean,
})

const ResetConflict = Schema.Struct({ error: Schema.Literals(["no_credit", "busy"]) })

// Consumes one banked reset; a 200 answer whose upstream call did not succeed counts as a failure.
export const consumeReset = Effect.fn("Subscriptions.consumeReset")(function* (input: {
  provider: "codex" | "anthropic"
  accountId: string
}) {
  const failed = { status: "consume_failed" as const }
  const url = yield* Config.string("OPENCODE_LLM_PROXY_URL").pipe(Config.withDefault(""), Effect.orDie)
  if (!url) return failed
  const prefix = input.provider === "codex" ? "/_admin/accounts/" : "/_admin/anthropic/accounts/"
  return yield* Effect.gen(function* () {
    const client = yield* HttpClient.HttpClient
    const response = yield* client.execute(
      HttpClientRequest.post(
        `${url.replace(/\/$/, "")}${prefix}${encodeURIComponent(input.accountId)}/banked-resets/consume`,
      ),
    )
    if (response.status === 409)
      return { status: (yield* Schema.decodeUnknownEffect(ResetConflict)(yield* response.json)).error }
    if (response.status !== 200) return failed
    const data = yield* Schema.decodeUnknownEffect(ResetResponse)(yield* response.json)
    if (!data.succeeded) return failed
    return { status: "ok" as const, result: { code: data.code, windowsReset: data.windowsReset } }
  }).pipe(
    // Longer than other proxy calls: the proxy observes usage before and after its single send (~75s worst case).
    Effect.timeout("90 seconds"),
    Effect.orElseSucceed(() => failed),
    Effect.provide(FetchHttpClient.layer),
  )
})

const readCodex = (base: string) =>
  Effect.gen(function* () {
    const client = yield* HttpClient.HttpClient
    const response = yield* client.get(`${base}/_admin/status`)
    if (response.status !== 200) return { status: "unavailable" as const, accounts: [], automation: null }
    const data = yield* Schema.decodeUnknownEffect(Status)(yield* response.json)
    return {
      status: "ok" as const,
      accounts: data.accounts.map((item) =>
        account(item, item.usage?.planType ?? item.account.planType, item.bankedResets ?? null),
      ),
      automation: automation(data),
    }
  }).pipe(
    Effect.timeout("8 seconds"),
    Effect.orElseSucceed(() => ({ status: "unavailable" as const, accounts: [], automation: null })),
    Effect.provide(FetchHttpClient.layer),
  )

const readAnthropic = (base: string) =>
  Effect.gen(function* () {
    const client = yield* HttpClient.HttpClient
    const response = yield* client.get(`${base}/_admin/anthropic/status`)
    // Proxies without the Anthropic pool answer 404, and a disabled pool answers 503.
    if (response.status === 404 || response.status === 503)
      return { status: "disabled" as const, accounts: [], automation: null }
    if (response.status !== 200) return { status: "unavailable" as const, accounts: [], automation: null }
    const data = yield* Schema.decodeUnknownEffect(AnthropicStatus)(yield* response.json)
    return {
      status: "ok" as const,
      accounts: data.accounts.map((item) =>
        account(
          item,
          anthropicPlan(item.usage?.planType ?? item.account.subscriptionTier),
          item.inventory ? anthropicBankedResets(item.inventory.grants) : null,
        ),
      ),
      automation: automation(data),
    }
  }).pipe(
    Effect.timeout("8 seconds"),
    Effect.orElseSucceed(() => ({ status: "unavailable" as const, accounts: [], automation: null })),
    Effect.provide(FetchHttpClient.layer),
  )

// Older proxies omit the automation fields; the client then hides the switch.
function automation(data: { resetAutomation?: { enabled: boolean } }) {
  return data.resetAutomation ? { enabled: data.resetAutomation.enabled } : null
}

function account(
  item: {
    account: { id: string; name: string | null; email: string; enabled: boolean; authenticationState: string }
    usage: typeof Usage.Type
    usageAgeSeconds: number | null
    cooldownSeconds: number
  },
  plan: string | null,
  bankedResets: Subscriptions.BankedResets | null,
): Subscriptions.Account {
  return {
    id: item.account.id,
    name: item.account.name || item.account.email,
    enabled: item.account.enabled,
    plan,
    authenticated: item.account.authenticationState === "Authenticated",
    cooldownSeconds: item.cooldownSeconds,
    bankedResets,
    fiveHourRemaining:
      item.usage?.fiveHourPercent == null ? null : Math.max(0, Math.min(100, 100 - item.usage.fiveHourPercent)),
    fiveHourResetAt: item.usage?.fiveHourResetAt ?? null,
    remaining: item.usage?.weeklyPercent == null ? null : Math.max(0, Math.min(100, 100 - item.usage.weeklyPercent)),
    resetAt: item.usage?.weeklyResetAt ?? null,
    observedAt: item.usage?.observedAt ?? null,
    stale: item.usageAgeSeconds === null || item.usageAgeSeconds < 0 || item.usageAgeSeconds > 65 * 60,
    hasCapacity: item.usage?.hasCapacity ?? null,
    credits: item.usage?.credits?.balance ?? null,
  }
}

// Anthropic reports rate-limit tiers such as `default_claude_max_20x`; unknown tiers pass through unchanged.
function anthropicPlan(tier: string | null) {
  if (tier?.includes("max_20x")) return "max20x"
  if (tier?.includes("max_5x")) return "max5x"
  return tier
}

function anthropicBankedResets(
  grants: readonly { resetsLeft: number; endsAt?: string | null; paused: boolean }[],
): Subscriptions.BankedResets {
  const active = grants.filter((grant) => !grant.paused && grant.resetsLeft > 0)
  const expiries = active
    .flatMap((grant) => (grant.endsAt ? [grant.endsAt] : []))
    .toSorted((a, b) => Date.parse(a) - Date.parse(b))
  return {
    available: active.reduce((sum, grant) => sum + grant.resetsLeft, 0),
    earliestExpiresAt: expiries[0] ?? null,
    latestExpiresAt: expiries.at(-1) ?? null,
    nonExpiring: active.filter((grant) => !grant.endsAt).reduce((sum, grant) => sum + grant.resetsLeft, 0),
  }
}
