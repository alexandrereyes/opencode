import { expect, test } from "bun:test"
import { ConfigProvider, Effect } from "effect"
import { readSubscriptions } from "../src/subscriptions"

test("reads quota metadata without returning account secrets and preserves unknown usage", async () => {
  const server = Bun.serve({
    port: 0,
    fetch(request) {
      expect(new URL(request.url).pathname).toBe("/_admin/status")
      return Response.json({
        accounts: [
          {
            account: {
              id: "one",
              name: "Subscription",
              email: "one@example.test",
              enabled: true,
              token: "private",
              planType: "plus",
              authenticationState: "Authenticated",
            },
            cooldownSeconds: 12,
            usage: {
              weeklyPercent: 75,
              weeklyResetAt: "2026-09-15T02:15:47Z",
              observedAt: "2026-09-09T20:00:00Z",
              hasCapacity: false,
              planType: "pro",
            },
            usageAgeSeconds: 4000,
          },
          {
            account: {
              id: "two",
              name: null,
              email: "two@example.test",
              enabled: false,
              planType: "pro",
              authenticationState: "ReauthenticationRequired",
            },
            cooldownSeconds: 0,
            usage: null,
            usageAgeSeconds: null,
          },
        ],
      })
    },
  })
  const result = await Effect.runPromise(
    readSubscriptions().pipe(
      Effect.provide(
        ConfigProvider.layer(ConfigProvider.fromEnv({ env: { OPENCODE_LLM_PROXY_URL: server.url.toString() } })),
      ),
      Effect.ensuring(Effect.sync(() => server.stop(true))),
    ),
  )
  expect(result).toEqual({
    status: "ok",
    accounts: [
      {
        id: "one",
        name: "Subscription",
        enabled: true,
        plan: "pro",
        authenticated: true,
        cooldownSeconds: 12,
        remaining: 25,
        resetAt: "2026-09-15T02:15:47Z",
        observedAt: "2026-09-09T20:00:00Z",
        stale: true,
        hasCapacity: false,
      },
      {
        id: "two",
        name: "two@example.test",
        enabled: false,
        plan: "pro",
        authenticated: false,
        cooldownSeconds: 0,
        remaining: null,
        resetAt: null,
        observedAt: null,
        stale: true,
        hasCapacity: null,
      },
    ],
  })
})

test("missing configuration and invalid upstream responses are explicit states", async () => {
  expect(
    await Effect.runPromise(
      readSubscriptions().pipe(Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnv({ env: {} })))),
    ),
  ).toEqual({ status: "unconfigured", accounts: [] })
  const server = Bun.serve({ port: 0, fetch: () => Response.json({ unexpected: true }) })
  expect(
    await Effect.runPromise(
      readSubscriptions().pipe(
        Effect.provide(
          ConfigProvider.layer(ConfigProvider.fromEnv({ env: { OPENCODE_LLM_PROXY_URL: server.url.toString() } })),
        ),
        Effect.ensuring(Effect.sync(() => server.stop(true))),
      ),
    ),
  ).toEqual({ status: "unavailable", accounts: [] })
})
