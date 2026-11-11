import { Plugin } from "@opencode/plugin/effect"
import { Session } from "@opencode/schema/session"
import { Tool } from "@opencode/schema/tool"
import { optional } from "@opencode/schema/schema"
import { Effect, Option, Schema } from "effect"
import path from "node:path"
import { sharedCurrentSessions } from "../browser-handoff/current.js"
import { relayEndpoint, relayFind } from "../browser-handoff/index.js"
import { limits, sharedRegistry } from "../browser-handoff/registry.js"
import { makeBrowseResources } from "./browse.js"
import { shellEnvironment, writeConfig } from "./adapters/chrome.js"
import { bareSerials, known, parseSimulators, resolveSimulators } from "./discovery.js"
import { commandLock, makeHubs, routes, sharedMacHub, type Hubs } from "./hubs.js"
import { refusal, returned } from "./lock.js"
import { Resources } from "./rpc.js"
import { HubError, hubSettings, makeHubClient, stateDirectory } from "./supervisor.js"
import { labelTarget, usage, type Caller } from "./usage.js"

/**
 * Session resources: simulators, emulators and browsers that agents use on the Mac, shown and controlled from the
 * iOS app. The registry, locks and live streams live in the hub process (`hub/`); this instance exposes the
 * `custom.resources` RPC, refuses agent commands on resources Alexandre controls, and relays hub events.
 * Specification: `docs/resources.md`.
 */
export const registerResources = Effect.fn("Resources.register")(function* (
  ctx: Omit<Plugin.Context, "storage">,
  given?: Hubs,
) {
  const hubs = given ?? (yield* defaultHubs())
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
  const ticketFor = (id: string, capability: Resources.Capability) => call(() => hubs.ticket(id, capability))

  const registration = yield* ctx.rpc
    .register(Resources.Definition, {
      list: (input, context) =>
        // Alexandre asked for it: a Mac hub in its backoff may be back.
        call(() => hubs.list({ probe: true })).pipe(
          Effect.map((result) => ({
            resources: input.sessionID
              ? result.resources.filter((resource) => resource.owner?.rootSessionID === input.sessionID)
              : result.resources,
          })),
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
      get: (input, context) =>
        call(() => hubs.get(input.id)).pipe(
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
      snapshot: (input, context) =>
        call(() => hubs.owner(input.id).snapshot(input.id, input.maxWidth)).pipe(
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
      ticket: (input, context) =>
        ticketFor(input.id, "view").pipe(
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
      control: (input, context) =>
        Effect.gen(function* () {
          const result = yield* call(() => hubs.control(input.id, input.action))
          if (!result.token) return { resource: result.resource }
          return { resource: result.resource, ticket: yield* ticketFor(input.id, "control") }
        }).pipe(Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason }))),
      // `browse-handoff-remoto.md`, section 4: a browse session's tab; while a handoff is on it, only while it waits.
      focus: (input, context) =>
        call(async () => {
          const hub = hubs.owner(input.id)
          const resource = await hub.get(input.id)
          if (resource.capabilities?.focus !== true || (resource.handoff !== undefined && !waiting(resource)))
            throw new HubError("unsupported", "This resource cannot be focused")
          await hub.focus(input.id)
          return {}
        }).pipe(Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason }))),
      stop: (input, context) =>
        call(() => hubs.stop(input.id)).pipe(
          Effect.as({}),
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
      dismiss: (input, context) =>
        call(() => hubs.owner(input.id).remove(input.id)).pipe(
          Effect.as({}),
          Effect.mapError((error) => context.error("unavailable", error.message, { reason: error.reason })),
        ),
    })
    .pipe(Effect.orDie)

  // Discovery: every shell command that names a simulator, emulator or Playwright browser registers it for the
  // session family, and its result gains an `opencode-resource:` link (once per session) and `metadata.resources`.
  const roots = new Map<string, Family>()
  const announced = new Set<string>()
  // Calls that touched resources while a remote hub could not say whether Alexandre holds them.
  const unchecked = new Set<string>()
  const family = (sessionID: string): Effect.Effect<Family> =>
    Effect.gen(function* () {
      const cached = roots.get(sessionID)
      if (cached) return cached
      const session = yield* ctx.session.get({ sessionID: Session.ID.make(sessionID) })
      const parent = session.parentID ? yield* family(session.parentID) : undefined
      const found: Family = {
        root: parent?.root ?? sessionID,
        directory: session.location.directory,
        ...(session.title ? { title: session.title } : {}),
        ...((parent ? parent.rootTitle : session.title)
          ? { rootTitle: parent ? parent.rootTitle : session.title }
          : {}),
      }
      roots.set(sessionID, found)
      return found
    }).pipe(Effect.catchCause(() => Effect.succeed({ root: sessionID, directory: "" })))
  const caller = (event: { readonly sessionID: string; readonly agent?: string }, owner: Family): Caller => ({
    sessionID: event.sessionID,
    rootSessionID: owner.root,
    ...(event.agent ? { agent: event.agent } : {}),
    ...(owner.title ? { title: owner.title } : {}),
    ...(owner.rootTitle ? { rootTitle: owner.rootTitle } : {}),
  })

  // A browse session's resource (this machine's browser): registered while agents use it, refused to them while
  // Alexandre controls it.
  const browse = makeBrowseResources({
    hub: hubs.local,
    current: sharedCurrentSessions(),
    find: relayFind(),
    family,
    scope: yield* Effect.scope,
    now: () => Date.now(),
    endpoint: relayEndpoint(),
    graceMs: limits.graceMs,
  })
  yield* ctx.tool.hook("execute.before", browse.before)
  yield* ctx.tool.hook("execute.after", browse.after)

  yield* ctx.tool.hook("execute.before", (event) =>
    Effect.gen(function* () {
      const command = shellCommand(event.tool, event.input)
      if (!command) return
      const workdir = shellWorkdir(event.input)
      // Each part of the command is matched on the hub of the machine it runs on (one part and hub without the Mac's).
      const all = hubs.scopes(command)
      const checked = yield* Effect.promise(() => commandLock(hubs, all, workdir))
      if (checked.unchecked) {
        unchecked.add(event.id)
        yield* Effect.logWarning("resources hub unreachable; command runs without its lock check", { call: event.id })
      }
      if (checked.lock) return yield* new Tool.Error({ message: refusal(checked.lock) })
      // In use from the start: a long command (a test run, a recording) keeps its resources `agent` until it ends, and
      // the history shows it while it runs. Only resources the hub already knows; the result registers new ones.
      if (routes(all).length === 0) return
      const owner = yield* family(event.sessionID)
      yield* Effect.forEach(
        routes(all, "", workdir ?? (owner.directory || undefined)),
        (route) =>
          Effect.gen(function* () {
            const hub = hubs.of(route.machine)
            const registered = yield* call(() => hub.list(false)).pipe(
              Effect.map((result) => [
                ...known(route.references, result.resources).map((resource) => ({
                  kind: resource.kind,
                  meta: resource.meta,
                })),
                ...bareSerials(route.references, result.resources).map((meta) => ({ kind: meta.kind, meta })),
              ]),
              Effect.orElseSucceed(() => []),
            )
            yield* Effect.forEach(
              registered,
              (resource) => {
                // A command that only asks about an emulator neither uses it nor takes it over.
                const use = usage(route.command, resource.meta, caller(event, owner), Date.now(), false)
                if (!use) return Effect.void
                return call(() =>
                  hub.upsert({
                    kind: resource.kind,
                    meta: resource.meta,
                    ...use,
                    used: true,
                    activity: { call: event.id, command, running: true },
                  }),
                ).pipe(Effect.ignore)
              },
              { discard: true },
            )
          }),
        { discard: true },
      )
    }),
  )

  yield* ctx.tool.hook("execute.after", (event) =>
    Effect.gen(function* () {
      const command = shellCommand(event.tool, event.input)
      if (!command) return
      const workdir = shellWorkdir(event.input)
      const all = hubs.scopes(command)
      // Whatever the outcome, the command no longer holds the resources it named.
      yield* Effect.forEach(routes(all), (route) => Effect.promise(() => hubs.of(route.machine).end(event.id)), {
        discard: true,
      })
      const warn = unchecked.delete(event.id)
      if (event.status !== "completed") return
      const content = [
        ...(typeof event.result.content === "string"
          ? [{ type: "text" as const, text: event.result.content }]
          : (event.result.content ?? [])),
        ...(warn ? [{ type: "text" as const, text: lockUnavailable }] : []),
      ]
      if (warn) event.result = { ...event.result, content }
      const output = content.flatMap((item) => (item.type === "text" ? [item.text] : [])).join("\n")
      const owner = yield* family(event.sessionID)
      const registered = yield* Effect.forEach(
        routes(all, output, workdir ?? (owner.directory || undefined)),
        (route) =>
          Effect.gen(function* () {
            const hub = hubs.of(route.machine)
            // Simulator names resolve on the hub's machine; this one may have no `xcrun` at all.
            const simulators = route.references.some((item) => item.kind === "ios-simulator")
              ? yield* Effect.promise(() =>
                  route.machine === "mac"
                    ? hub.simulators().catch(() => [])
                    : hub.remote
                      ? hub.simulators().catch(() => listSimulators())
                      : listSimulators(),
                )
              : []
            const metas = resolveSimulators(route.references, simulators).flatMap((meta) => {
              const use = usage(route.command, meta, caller(event, owner), Date.now(), true)
              return use ? [{ meta, use }] : []
            })
            return yield* Effect.forEach(metas, ({ meta, use }) =>
              call(() =>
                hub.upsert({
                  kind: meta.kind,
                  meta,
                  ...use,
                  used: true,
                  activity: { call: event.id, command, running: false },
                }),
              ).pipe(Effect.option),
            )
          }),
      ).pipe(Effect.map((results) => results.flat().flatMap((result) => (Option.isSome(result) ? [result.value] : []))))
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
        description: hubs.mac
          ? "Name an iOS simulator or Android emulator of the Mac (used through `mac …`) or a Playwright browser of this machine that you already used in a shell command, or say what it is for, as Alexandre sees it in the app. ref is its UDID, simulator name, AVD name (prefer it to the adb serial, which another AVD may hold now) or playwright-cli session. Emulators reached otherwise (adb without `mac`, ssh, docker exec) are not resources here."
          : "Name a simulator, Android emulator or Playwright browser of this Mac you already used in a shell command, or say what it is for, as Alexandre sees it in the app. ref is its UDID, simulator name, AVD name (prefer it to the adb serial, which another AVD may hold now) or playwright-cli session. Emulators on other machines (ssh, docker exec) are not resources here.",
        input: standard(LabelInput),
        output: standard(Resources.Resource),
        options: { codemode: false },
        execute: (input) =>
          call(async () => {
            const found = labelTarget((await hubs.list()).resources, input.ref, hubs.mac !== undefined)
            if ("refusal" in found) throw new HubError("not_found", found.refusal)
            const { resource: target, bare } = found
            // A serial is resolved by the hub against the emulator there now (it may be another AVD's by now).
            return hubs.owner(target.id).upsert({
              kind: target.kind,
              meta: bare ? { kind: "android-emulator", serial: input.ref } : target.meta,
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
                  message: error.message,
                }),
            ),
          ),
      }),
    )
    .pipe(Effect.orDie)

  // Each hub event reaches exactly one plugin instance, which relays it; the Mac's hub going away or coming back
  // reaches each instance once (`hubs.relay`).
  yield* hubs.relay((event) => {
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
  })
})

/** This machine's hub and, when configured, the Mac's (`resources.md`, "Mac hub"); a misconfiguration only warns. */
const defaultHubs = Effect.fn("Resources.hubs")(function* () {
  const mac = sharedMacHub()
  if (mac.problem) yield* Effect.logWarning(mac.problem)
  return makeHubs(makeHubClient(hubSettings()), mac.client)
})

/** Whether a resource's browse handoff still waits (the hub may still list it for a moment after it ended). */
export function waiting(resource: Pick<Resources.Resource, "id" | "handoff">, registry = sharedRegistry()) {
  const handoff = resource.handoff
  return (
    handoff !== undefined &&
    registry.waiting().some((entry) => entry.id === handoff.id && entry.resourceID === resource.id)
  )
}

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

export const lockUnavailable =
  "Aviso: o hub de recursos no Mac não respondeu, então este comando rodou sem verificar se Alexandre está usando o recurso. Evite novos comandos nesse simulador, emulador ou navegador até o hub voltar, a menos que a tarefa não possa esperar."

/**
 * This machine's iOS simulators. Without `xcrun` (a Linux server) `Bun.spawn` throws: no simulators, never a failure,
 * which would fail the agent's shell call from `execute.after`.
 */
export async function listSimulators() {
  const output: unknown = await Promise.resolve()
    .then(() => {
      const child = Bun.spawn(["xcrun", "simctl", "list", "devices", "-j"], { stdout: "pipe", stderr: "ignore" })
      return new Response(child.stdout).json()
    })
    .catch(() => undefined)
  return parseSimulators(output)
}

const LabelInput = Schema.Struct({
  ref: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200)),
  name: optional(Schema.String.check(Schema.isMaxLength(80))),
  purpose: optional(Schema.String.check(Schema.isMaxLength(200))),
})

function standard<A>(schema: Schema.Codec<A, unknown>) {
  return {
    "~standard": {
      ...Schema.toStandardSchemaV1(schema)["~standard"],
      ...Schema.toStandardJSONSchemaV1(schema)["~standard"],
    },
  }
}

interface Family {
  readonly root: string
  readonly directory: string
  readonly title?: string
  readonly rootTitle?: string
}

export function shellWorkdir(input: unknown) {
  if (typeof input !== "object" || input === null || !("workdir" in input)) return undefined
  return typeof input.workdir === "string" ? input.workdir : undefined
}

export function shellCommand(tool: string, input: unknown) {
  if (tool !== "shell" || typeof input !== "object" || input === null || !("command" in input)) return undefined
  return typeof input.command === "string" ? input.command : undefined
}
