import { expect } from "bun:test"
import { AIError, HttpContext, RateLimitError, TransportError } from "@opencode/ai"
import { Agent } from "@opencode/schema/agent"
import { Model } from "@opencode/schema/model"
import { Provider } from "@opencode/schema/provider"
import { Session } from "@opencode/schema/session"
import { SessionRunnerRetry } from "@opencode/core/session/runner/retry"
import { toSessionError } from "@opencode/core/session/to-session-error"
import { Effect, Fiber, Queue } from "effect"
import { TestClock } from "effect/testing"
import { it } from "./lib/effect"

const sessionID = Session.ID.make("ses_retry_http")
const agent = Agent.ID.make("build")
const model = { providerID: Provider.ID.make("anthropic"), id: Model.ID.make("claude") }
const headers = { "x-private-reset": "18000000", "retry-after": "18000" }
const cause = new AIError({
  reason: new RateLimitError({
    message: "Rate limited",
    retryAfterMs: 18_000_000,
    http: new HttpContext({ url: "https://example.test/messages", status: 429, headers }),
  }),
})

it.effect("retry exposes isolated HTTP metadata without changing the public error or attempt cap", () =>
  Effect.gen(function* () {
    const decide = yield* SessionRunnerRetry.policy(sessionID)
    const seen: number[] = []
    const input = {
      cause,
      error: toSessionError(cause),
      agent,
      model,
      retry: true,
      hook: (event: Parameters<Parameters<typeof decide>[0]["hook"]>[0]) =>
        Effect.sync(() => {
          expect(event.http).toEqual(cause.reason.http)
          expect(event.http?.headers).not.toBe(cause.reason.http?.headers)
          expect(Object.isFrozen(event.http)).toBe(true)
          expect(Object.isFrozen(event.http?.headers)).toBe(true)
          expect(event.error).toEqual({ type: "provider.rate-limit", status: 429, message: "Rate limited" })
          expect(event.decision).toEqual({ retry: true, delay: 900_000 })
          seen.push(event.attempt)
          event.decision = { retry: true, delay: Number(event.http?.headers["x-private-reset"]) }
        }),
    }
    for (const attempt of [2, 3, 4, 5, 6, 7, 8, 9, 10, 11]) {
      expect(yield* decide(input)).toEqual({ retry: true, attempt, delay: 18_000_000 })
    }
    expect(yield* decide(input)).toEqual({ retry: false })
    expect(seen).toEqual([2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    expect(toSessionError(cause)).not.toHaveProperty("http")
  }),
)

it.effect("transport failures have no invented HTTP metadata", () =>
  Effect.gen(function* () {
    const decide = yield* SessionRunnerRetry.policy(sessionID)
    const failure = new AIError({
      reason: new TransportError({
        message: "timeout",
        transport: "http",
        operation: "request",
      }),
    })
    yield* decide({
      cause: failure,
      error: toSessionError(failure),
      agent,
      model,
      retry: true,
      hook: (event) =>
        Effect.sync(() => {
          expect(event).not.toHaveProperty("http")
        }),
    })
  }),
)

it.effect("native retry waits the hook deadline and remains interruptible", () =>
  Effect.gen(function* () {
    const scheduled = yield* Queue.unbounded<void>()
    const attempts: number[] = []
    const run = Effect.gen(function* () {
      const decide = yield* SessionRunnerRetry.policy(sessionID)
      return yield* Effect.suspend(() => {
        attempts.push(1)
        return attempts.length % 2 === 1 ? Effect.fail(cause) : Effect.succeed("done")
      }).pipe(
        SessionRunnerRetry.transient(decide, {
          agent,
          model,
          hook: (event) =>
            Effect.gen(function* () {
              event.decision = { retry: true, delay: 18_000_000 }
              yield* Queue.offer(scheduled, undefined)
            }),
        }),
      )
    })
    const first = yield* run.pipe(Effect.forkChild)
    yield* Queue.take(scheduled)
    yield* TestClock.adjust("17999999 millis")
    expect(attempts).toHaveLength(1)
    yield* TestClock.adjust("1 millis")
    expect(yield* Fiber.join(first)).toBe("done")
    const second = yield* run.pipe(Effect.forkChild)
    yield* Queue.take(scheduled)
    yield* Fiber.interrupt(second)
    yield* TestClock.adjust("1 day")
    expect(attempts).toHaveLength(3)
  }),
)
