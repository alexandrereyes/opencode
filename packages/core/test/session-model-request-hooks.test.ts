import { describe, expect } from "bun:test"
import { OpenAIChat } from "@opencode/ai/protocols"
import { RequestExecutor } from "@opencode/ai/route/executor"
import { SessionRunnerRetry } from "@opencode/core/session/runner/retry"
import { toSessionError } from "@opencode/core/session/to-session-error"
import { Agent } from "@opencode/schema/agent"
import { Money } from "@opencode/schema/money"
import { Session } from "@opencode/schema/session"
import type { SessionRequestKind } from "@opencode/plugin/effect/session"
import { Location } from "@opencode/core/location"
import { PluginHooks } from "@opencode/core/plugin/hooks"
import { Project } from "@opencode/core/project"
import { AbsolutePath } from "@opencode/core/schema"
import { SessionModelRequest } from "@opencode/core/session/model-request"
import { SessionModelTransport } from "@opencode/core/session/model-transport"
import { SessionRunnerModel } from "@opencode/core/session/runner/model"
import { DateTime, Effect, Layer } from "effect"
import { HttpClient, HttpClientRequest, HttpClientResponse } from "effect/unstable/http"
import { testEffect } from "./lib/effect"
import { PluginTestLayer } from "./plugin/fixture"

const it = testEffect(PluginTestLayer)

const KINDS: ReadonlyArray<SessionRequestKind> = ["primary", "compaction", "title", "generate"]

const session = Session.Info.make({
  id: Session.ID.make("ses_hook_kind"),
  projectID: Project.ID.global,
  cost: Money.USD.zero,
  tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  time: { created: DateTime.makeUnsafe(0), updated: DateTime.makeUnsafe(0) },
  location: Location.Ref.make({ directory: AbsolutePath.make("/project") }),
})
const model = SessionRunnerModel.resolved(OpenAIChat.route.model({ id: "gpt-5.5", provider: "test" }), {
  capabilities: { tools: true, input: ["text"], output: ["text"] },
  cost: [],
  limit: { context: 200_000, output: 32_000 },
})
const transport = SessionModelTransport.Service.of({
  bind: () => ({ execute: () => Effect.die("unused WebSocket execution") }),
  close: () => Effect.void,
  closeAll: Effect.void,
})

describe("SessionModelRequest HTTP hooks", () => {
  it.effect("passes response-hook headers through the executor failure to the retry hook", () =>
    Effect.gen(function* () {
      const hooks = yield* PluginHooks.Service
      yield* hooks.register("session", "http.response", (event) =>
        Effect.sync(() => {
          expect(new URL(event.request.url).searchParams.get("beta")).toBe("true")
          const headers = new Headers(event.response.headers)
          headers.set("x-private-reset", "18000000")
          event.response = new Response(event.response.body, { status: event.response.status, headers })
        }),
      )
      const requests = yield* SessionModelRequest.Service.pipe(Effect.provide(SessionModelRequest.layer))
      const prepared = yield* requests.primary({
        session,
        agent: Agent.ID.make("build"),
        model,
        system: [],
        messages: [],
      })
      const executor = yield* RequestExecutor.Service.pipe(
        Effect.provide(Layer.fresh(RequestExecutor.layer)),
        Effect.provideService(
          HttpClient.HttpClient,
          HttpClient.make((request) =>
            Effect.succeed(
              HttpClientResponse.fromWeb(
                request,
                new Response('{"error":{"message":"rate limited"}}', { status: 429 }),
              ),
            ),
          ),
        ),
      )
      const failure = yield* executor
        .execute(HttpClientRequest.post("https://example.test/messages?beta=true"), prepared.options.http)
        .pipe(Effect.flip)
      expect(failure.reason.http?.headers["x-private-reset"]).toBe("18000000")
      expect(failure.reason.http?.url).toBe("https://example.test/messages")
      const decide = yield* SessionRunnerRetry.policy(session.id)
      const decision = yield* decide({
        cause: failure,
        error: toSessionError(failure),
        agent: Agent.ID.make("build"),
        model: model.ref,
        retry: true,
        hook: (event) =>
          Effect.sync(() => {
            expect(event.http?.headers["x-private-reset"]).toBe("18000000")
            expect(event.error).not.toHaveProperty("headers")
            event.decision = { retry: true, delay: Number(event.http?.headers["x-private-reset"]) }
          }),
      })
      expect(decision).toEqual({ retry: true, attempt: 2, delay: 18_000_000 })
    }).pipe(Effect.provideService(SessionModelTransport.Service, transport)),
  )

  it.effect("tags every Session request kind on http.request and http.response", () =>
    Effect.gen(function* () {
      const hooks = yield* PluginHooks.Service
      const seen: Array<{ hook: string; kind: SessionRequestKind; agent: Agent.ID }> = []
      yield* hooks.register("session", "http.request", (event) =>
        Effect.sync(() => {
          seen.push({ hook: "request", kind: event.kind, agent: event.agent })
        }),
      )
      yield* hooks.register("session", "http.response", (event) =>
        Effect.sync(() => {
          seen.push({ hook: "response", kind: event.kind, agent: event.agent })
        }),
      )
      const requests = yield* SessionModelRequest.Service.pipe(Effect.provide(SessionModelRequest.layer))

      for (const kind of KINDS) {
        const prepared = yield* requests[kind]({
          session,
          agent: Agent.ID.make("build"),
          model,
          system: [],
          messages: [],
        })
        const http = prepared.options.http
        if (!http) throw new Error(`Expected HTTP middleware for ${kind}`)
        yield* http(HttpClientRequest.post("https://example.test/v1/chat/completions"), (request) =>
          Effect.succeed(HttpClientResponse.fromWeb(request, new Response("{}", { status: 200 }))),
        )
      }

      expect(seen).toEqual(
        KINDS.flatMap((kind) => [
          { hook: "request", kind, agent: Agent.ID.make("build") },
          { hook: "response", kind, agent: Agent.ID.make("build") },
        ]),
      )
    }).pipe(Effect.provideService(SessionModelTransport.Service, transport)),
  )
})
