import { Plugin } from "@opencode/plugin/effect"
import { Session } from "@opencode/schema/session"
import { Tool } from "@opencode/schema/tool"
import { Effect, Schedule } from "effect"
import path from "node:path"
import { shellEnvironment, writeConfig } from "./adapters/chrome.js"
import { blocking, refusal, returned } from "./lock.js"
import { Resources } from "./rpc.js"
import { HubError, makeHubClient, stateDirectory, type HubClient } from "./supervisor.js"

/**
 * Session resources: simulators, emulators and browsers that agents use on the Mac, shown and controlled from the
 * iOS app. The registry, locks and live streams live in the hub process (`hub/`); this instance exposes the
 * `custom.resources` RPC, refuses agent commands on resources Alexandre controls, and relays hub events.
 * Specification: `docs/resources.md`.
 */
export const registerResources = Effect.fn("Resources.register")(function* (
  ctx: Plugin.Context,
  hub: HubClient = makeHubClient({ state: stateDirectory() }),
) {
  // Chrome: agent shells open `playwright-cli` browsers with a loopback CDP port that the adapter attaches to.
  const playwrightConfig = path.join(stateDirectory(), "playwright-cli.json")
  yield* ctx.shell.hook("create.before", (input) => Effect.sync(() => shellEnvironment(input.env, playwrightConfig)))
  yield* Effect.promise(() => writeConfig(playwrightConfig))

  const call = <A>(run: () => Promise<A>) =>
    Effect.tryPromise({
      try: run,
      catch: (error) =>
        error instanceof HubError
          ? error
          : new HubError("failed", error instanceof Error ? error.message : String(error)),
    })
  const ticketFor = (id: string, capability: Resources.Capability) =>
    call(async () => {
      const [ticket, port] = await Promise.all([hub.ticket(id, capability), hub.port()])
      return {
        ticket: ticket.ticket,
        expiresAt: ticket.expiresAt,
        path: `/resources/${encodeURIComponent(id)}`,
        loopbackPort: port ?? 0,
      }
    })

  const registration = yield* ctx.rpc
    .register(Resources.Definition, {
      list: (input, context) =>
        call(() => hub.list()).pipe(
          Effect.map((result) => ({
            resources: input.sessionID
              ? result.resources.filter((resource) => resource.owner?.rootSessionID === input.sessionID)
              : result.resources,
          })),
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
      get: (input, context) =>
        call(() => hub.get(input.id)).pipe(
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
      snapshot: (input, context) =>
        call(() => hub.snapshot(input.id, input.maxWidth)).pipe(
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
      ticket: (input, context) =>
        ticketFor(input.id, "view").pipe(
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
      control: (input, context) =>
        Effect.gen(function* () {
          const result = yield* call(() => hub.control(input.id, input.action))
          if (!result.token) return { resource: result.resource }
          return { resource: result.resource, ticket: yield* ticketFor(input.id, "control") }
        }).pipe(Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason }))),
      dismiss: (input, context) =>
        call(() => hub.remove(input.id)).pipe(
          Effect.as({}),
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
    })
    .pipe(Effect.orDie)

  yield* ctx.tool.hook("execute.before", (event) =>
    Effect.gen(function* () {
      const command = shellCommand(event.tool, event.input)
      if (!command) return
      const locks = yield* Effect.promise(() => hub.locks())
      const lock = blocking(command, locks)
      if (lock) return yield* new Tool.Error({ message: refusal(lock) })
    }),
  )

  // Each hub event reaches exactly one plugin instance, which relays it.
  yield* Effect.promise(() => hub.events(25_000)).pipe(
    Effect.flatMap((events) =>
      Effect.forEach(
        events,
        (event) => {
          if (event.type === "changed")
            return registration.events.emit("changed", { ids: [...event.ids] }).pipe(Effect.ignore)
          if (!event.owner) return Effect.void
          return ctx.session
            .synthetic({ sessionID: Session.ID.make(event.owner.sessionID), text: returned(event), resume: false })
            .pipe(
              Effect.catchCause((cause) =>
                Effect.logWarning("failed to tell the session about returned control", { id: event.id, cause }),
              ),
            )
        },
        { discard: true },
      ).pipe(Effect.as(events.length)),
    ),
    // Without a hub the long poll returns at once; wait before asking again.
    Effect.flatMap((count) => (count === 0 ? Effect.sleep("2 seconds") : Effect.void)),
    Effect.repeat(Schedule.forever),
    Effect.forkScoped({ startImmediately: true }),
  )
})

export function shellCommand(tool: string, input: unknown) {
  if (tool !== "shell" || typeof input !== "object" || input === null || !("command" in input)) return undefined
  return typeof input.command === "string" ? input.command : undefined
}
