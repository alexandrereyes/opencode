import { Plugin } from "@opencode/plugin/effect"
import { Session } from "@opencode/schema/session"
import { Tool } from "@opencode/schema/tool"
import { optional } from "@opencode/schema/schema"
import { Effect, Option, Schedule, Schema } from "effect"
import path from "node:path"
import { shellEnvironment, writeConfig } from "./adapters/chrome.js"
import { parseSimulators, references, resolveSimulators } from "./discovery.js"
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
      const lock = blocking(command, locks, shellWorkdir(event.input))
      if (lock) return yield* new Tool.Error({ message: refusal(lock) })
    }),
  )

  // Discovery: every shell command that names a simulator, emulator or Playwright browser registers it for the
  // session family, and its result gains an `opencode-resource:` link (once per session) and `metadata.resources`.
  const roots = new Map<string, { root: string; directory: string }>()
  const announced = new Set<string>()
  const family = (sessionID: string): Effect.Effect<{ root: string; directory: string }> =>
    Effect.gen(function* () {
      const cached = roots.get(sessionID)
      if (cached) return cached
      const session = yield* ctx.session.get({ sessionID: Session.ID.make(sessionID) })
      const parent = session.parentID ? yield* family(session.parentID) : undefined
      const found = { root: parent?.root ?? sessionID, directory: session.location.directory }
      roots.set(sessionID, found)
      return found
    }).pipe(Effect.catchCause(() => Effect.succeed({ root: sessionID, directory: "" })))

  yield* ctx.tool.hook("execute.after", (event) =>
    Effect.gen(function* () {
      const command = shellCommand(event.tool, event.input)
      if (!command || event.status !== "completed") return
      const content =
        typeof event.result.content === "string"
          ? [{ type: "text" as const, text: event.result.content }]
          : (event.result.content ?? [])
      const output = content.flatMap((item) => (item.type === "text" ? [item.text] : [])).join("\n")
      const owner = yield* family(event.sessionID)
      const found = references(command, output, shellWorkdir(event.input) ?? (owner.directory || undefined))
      if (found.length === 0) return
      const simulators = found.some((item) => item.kind === "ios-simulator")
        ? yield* Effect.promise(() => listSimulators())
        : []
      const metas = resolveSimulators(found, simulators)
      const registered = yield* Effect.forEach(metas, (meta) =>
        call(() =>
          hub.upsert({
            kind: meta.kind,
            meta,
            owner: { sessionID: event.sessionID, rootSessionID: owner.root, agent: event.agent },
            used: true,
          }),
        ).pipe(Effect.option),
      ).pipe(Effect.map((results) => results.flatMap((result) => (Option.isSome(result) ? [result.value] : []))))
      if (registered.length === 0) return
      const fresh = registered.filter((resource) => !announced.has(`${event.sessionID}:${resource.id}`))
      fresh.forEach((resource) => announced.add(`${event.sessionID}:${resource.id}`))
      event.result = {
        ...event.result,
        content: [...content, ...(fresh.length > 0 ? [{ type: "text" as const, text: links(fresh) }] : [])],
        metadata: {
          ...event.result.metadata,
          resources: registered.map((resource) => ({ id: resource.id, kind: resource.kind, label: resource.label })),
        },
      }
    }),
  )

  // Optional explicit registration, only to name a resource or say what it is for.
  yield* ctx.tool
    .transform((editor) =>
      editor.add({
        name: "resource_label",
        description:
          "Name a simulator, Android emulator or Playwright browser you already used in a shell command, or say what it is for, as Alexandre sees it in the app. ref is its UDID, simulator name, adb serial, AVD name or playwright-cli session.",
        input: standard(LabelInput),
        output: standard(Resources.Resource),
        options: { codemode: false },
        execute: (input) =>
          call(async () => {
            const target = (await hub.list()).resources.find((resource) => names(resource.meta).includes(input.ref))
            if (!target) throw new HubError("not_found", "")
            return hub.upsert({
              kind: target.kind,
              meta: target.meta,
              ...(input.name ? { name: input.name } : {}),
              ...(input.purpose ? { purpose: input.purpose } : {}),
            })
          }).pipe(
            Effect.map((output) => ({
              output,
              content: `${output.label}${output.purpose ? ` — ${output.purpose}` : ""}`,
            })),
            Effect.mapError(
              (error) =>
                new Tool.Error({
                  message:
                    error.reason === "not_found"
                      ? `No known resource is called ${input.ref}; use it in a shell command first.`
                      : error.message,
                }),
            ),
          ),
      }),
    )
    .pipe(Effect.orDie)

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

/** "Recurso: [Simulador iOS · iPhone 17 · X](opencode-resource:…)" lines for the agent and the conversation. */
export function links(resources: readonly Pick<Resources.Resource, "id" | "kind" | "label">[]) {
  const kinds = { "ios-simulator": "Simulador iOS", "android-emulator": "Emulador Android", chrome: "Chrome" }
  return resources
    .map(
      (resource) =>
        `Recurso no app: [${kinds[resource.kind]} · ${resource.label}](opencode-resource:${encodeURIComponent(resource.id)})`,
    )
    .join("\n")
}

async function listSimulators() {
  const child = Bun.spawn(["xcrun", "simctl", "list", "devices", "-j"], { stdout: "pipe", stderr: "ignore" })
  const output: unknown = await new Response(child.stdout).json().catch(() => undefined)
  return parseSimulators(output)
}

const LabelInput = Schema.Struct({
  ref: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200)),
  name: optional(Schema.String.check(Schema.isMaxLength(80))),
  purpose: optional(Schema.String.check(Schema.isMaxLength(200))),
})

function names(meta: Resources.Meta) {
  if (meta.kind === "ios-simulator") return [meta.udid, meta.name]
  if (meta.kind === "android-emulator") return [meta.serial, meta.avd]
  return [meta.session, meta.cdp]
}

function standard<A>(schema: Schema.Codec<A, unknown>) {
  return {
    "~standard": {
      ...Schema.toStandardSchemaV1(schema)["~standard"],
      ...Schema.toStandardJSONSchemaV1(schema)["~standard"],
    },
  }
}

export function shellWorkdir(input: unknown) {
  if (typeof input !== "object" || input === null || !("workdir" in input)) return undefined
  return typeof input.workdir === "string" ? input.workdir : undefined
}

export function shellCommand(tool: string, input: unknown) {
  if (tool !== "shell" || typeof input !== "object" || input === null || !("command" in input)) return undefined
  return typeof input.command === "string" ? input.command : undefined
}
