import path from "node:path"
import type { RpcCallContext } from "@opencode/plugin/effect/rpc"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Effect, Schedule } from "effect"
import type { Context } from "../context.js"
import { identity } from "../instance/index.js"
import { hubPassword, linkSettings } from "../live-activity/link.js"
import { privateEnv } from "../private-env.js"
import { BancadaError, makeBancadaClient, stateDirectory } from "./client.js"
import { Bancada } from "./rpc.js"
import { registerBancadaTools } from "./tools.js"
import { makeBancadaHook } from "./hook.js"

/**
 * The Bancada of this machine (`docs/bancada.md`). The plugin only relays: every `custom.bancada` call goes to this
 * machine's process, which this instance starts as soon as it loads. A process that is missing or broken makes the
 * Bancada unavailable here, never the server. It runs only with `OPENCODE_BANCADA=1`, which the launchers of the
 * installed servers set (D13): tests and scripts of other packages load this plugin too, and must never start a process
 * in the machine's folder. Off, every call answers `unavailable { reason: "off" }`.
 */
export const registerBancada = Effect.fn("Bancada.register")(function* (
  ctx: Pick<Context, "rpc" | "storage" | "tool" | "session">,
  env: Readonly<Record<string, string | undefined>> = process.env,
) {
  if (env.OPENCODE_BANCADA?.trim() !== "1") {
    const off = "A Bancada está desligada neste servidor (liga com OPENCODE_BANCADA=1)."
    yield* ctx.rpc
      .register(Bancada.Definition, {
        wake: (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        submit: (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        status: (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        cancel: (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        session: (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        queue: (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        sync: (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        "blob.put": (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
        "blob.get": (_input, context) => Effect.fail(context.error("unavailable", off, { reason: "off" })),
      })
      .pipe(Effect.orDie)
    return
  }

  const run = Effect.runPromiseWith(yield* Effect.context<never>())
  const link = linkSettings(env)
  const client = makeBancadaClient({
    state: stateDirectory(env),
    owner: async () => {
      const server = await run(identity(ctx.storage, env))
      const password = link.target ? await hubPassword(env) : undefined
      const self = env.OPENCODE_BANCADA_SELF?.trim().replace(/\/+$/, "")
      const own = self ? await ownPassword(env) : undefined
      return {
        instanceID: server.instanceID,
        name: server.name,
        hub: server.hub,
        ...(link.target && password ? { link: { target: link.target, password } } : {}),
        ...(self && own ? { self: { url: self, password: own } } : {}),
      }
    },
  })
  /** Another server's call, relayed as it came: the process reads it against the protocol and answers or refuses. */
  const relay = (
    method: "sync" | "blob.put" | "blob.get",
    input: Readonly<Record<string, unknown>>,
    context: RpcCallContext<(typeof Bancada.Definition)["methods"]["sync"]>,
  ) =>
    Effect.tryPromise({
      // A long poll holds the call up to its `waitMs`; a chunk of a transfer may take a while on a slow link.
      try: () =>
        client.call<Record<string, unknown>>(
          method,
          input,
          (typeof input.waitMs === "number" ? Math.min(Math.max(input.waitMs, 0), 25_000) : 0) + 30_000,
        ),
      catch: (error) => error,
    }).pipe(Effect.mapError((error) => refused(error, context)))
  const registration = yield* ctx.rpc
    .register(Bancada.Definition, {
      wake: (input, context) =>
        Effect.tryPromise({ try: () => client.call<Bancada.Wake>("wake", input), catch: (error) => error }).pipe(
          Effect.mapError((error) => refusal(error, context)),
        ),
      submit: (input, context) =>
        Effect.tryPromise({
          // Freezing a big repository's tree takes more than an ordinary call (`docs/bancada.md`, "Request").
          try: () => client.call<Bancada.Submitted>("submit", input, 120_000),
          catch: (error) => error,
        }).pipe(
          Effect.mapError((error) =>
            error instanceof BancadaError && error.reason === "invalid"
              ? context.error("invalid", error.message, { problems: [...(error.problems ?? [])] })
              : context.error("unavailable", unavailable(error).message, unavailable(error).data),
          ),
        ),
      status: (input, context) =>
        Effect.gen(function* () {
          const root = input.sessionID ? yield* rootOf(ctx, input.sessionID) : undefined
          return yield* Effect.tryPromise({
            try: () =>
              client.call<{ jobs: Bancada.JobView[] }>(
                "status",
                input.job
                  ? { job: input.job, ...(input.waitMs ? { waitMs: input.waitMs } : {}) }
                  : root
                    ? { rootSessionID: root }
                    : {},
                (input.waitMs ?? 0) + 10_000,
              ),
            catch: (error) => error,
          })
        }).pipe(
          Effect.mapError((error) => context.error("unavailable", unavailable(error).message, unavailable(error).data)),
        ),
      cancel: (input, context) =>
        Effect.tryPromise({
          try: () => client.call<{ state: string }>("cancel", input),
          catch: (error) => error,
        }).pipe(
          Effect.mapError((error) => context.error("unavailable", unavailable(error).message, unavailable(error).data)),
        ),
      session: (input, context) =>
        Effect.gen(function* () {
          const root = yield* rootOf(ctx, input.sessionID)
          const view = yield* Effect.tryPromise({
            try: () => client.call<Record<string, unknown>>("session", { rootSessionID: root }),
            catch: (error) => error,
          })
          return yield* withAgents(ctx, view)
        }).pipe(
          Effect.mapError((error) => context.error("unavailable", unavailable(error).message, unavailable(error).data)),
        ),
      queue: (_input, context) =>
        Effect.tryPromise({
          try: () => client.call<Record<string, unknown>>("queue", {}),
          catch: (error) => error,
        }).pipe(
          Effect.mapError((error) => context.error("unavailable", unavailable(error).message, unavailable(error).data)),
        ),
      sync: (input, context) => relay("sync", input, context),
      "blob.put": (input, context) => relay("blob.put", input, context),
      "blob.get": (input, context) => relay("blob.get", input, context),
    })
    .pipe(Effect.orDie)

  yield* registerBancadaTools(ctx, client, () => run(identity(ctx.storage, env)).then((server) => server.instanceID))
  const hook = makeBancadaHook(ctx, client)
  yield* ctx.tool.hook("execute.before", hook.before)
  yield* ctx.tool.hook("execute.after", hook.after)

  // Notices: each goes to one instance, which puts it in its session with a fixed id (a second delivery never makes a
  // second message) and then says so; without that, it goes again in 30 s (`docs/bancada.md`, "Notice").
  // Interrupted (this instance unloads), the long poll is abandoned and does not start the process again.
  yield* Effect.tryPromise((signal) =>
    client.call<{
      notices: Message[]
      notes?: (Omit<Message, "job"> & { key: string })[]
      changed?: { sessions: string[]; queue: boolean; alerts: { id: string; kind: string; text: string }[] }
    }>("events", { waitMs: 25_000 }, 35_000, signal),
  ).pipe(
    Effect.flatMap((answer) =>
      Effect.all(
        [
          // What the apps show changed: they reload what it names (`docs/bancada.md`, "changed").
          answer.changed
            ? registration.events
                .emit("changed", { sessions: answer.changed.sessions, queue: answer.changed.queue })
                .pipe(Effect.ignore)
            : Effect.void,
          Effect.forEach(
            answer.changed?.alerts ?? [],
            (alert) => registration.events.emit("alert", alert).pipe(Effect.ignore),
            { discard: true },
          ),
          Effect.forEach(answer.notices, (notice) => deliver(notice), { discard: true }),
          // Notes of holds (one came out, one expired): the same way, with their own message id and wake-up.
          Effect.forEach(
            answer.notes ?? [],
            (note) =>
              deliver({ ...note, job: "" }, (missing) =>
                client.call("note.ack", { key: note.key, ...(missing ? { missing } : {}) }),
              ),
            { discard: true },
          ),
        ],
        { discard: true },
      ),
    ),
    Effect.catchCause(() => Effect.sleep("2 seconds")),
    Effect.repeat(Schedule.forever),
    Effect.forkScoped({ startImmediately: true }),
  )
  type Message = { job: string; sessionID: string; id: string; text: string; resume: boolean }
  function deliver(
    notice: Message,
    ack: (missing: boolean) => Promise<unknown> = (missing) =>
      client.call("notice.ack", { job: notice.job, ...(missing ? { missing } : {}) }),
  ) {
    return ctx.session
      .synthetic({
        sessionID: Session.ID.make(notice.sessionID),
        id: SessionMessage.ID.make(notice.id),
        text: notice.text,
        // What the apps show for the message: the notice's first line ("[Bancada] j-… terminou: aprovado (…)").
        description: notice.text.split("\n", 1)[0]!,
        metadata: { custom: { bancada: notice.job ? { job: notice.job } : {} } },
        // A request cancelled whole has nothing to act on: its notice does not wake the session.
        ...(notice.resume ? {} : { resume: false }),
      })
      .pipe(
        Effect.as(false),
        // A session that no longer exists: the notice is dropped, and said in the process's log. The core's error is
        // `Session.NotFoundError`; the HTTP API's name is accepted too.
        Effect.catch((error: unknown) =>
          typeof error === "object" &&
          error !== null &&
          "_tag" in error &&
          (error._tag === "Session.NotFoundError" || error._tag === "SessionNotFoundError")
            ? Effect.succeed(true)
            : Effect.fail(error),
        ),
        Effect.flatMap((missing) => Effect.tryPromise(() => ack(missing))),
        Effect.catchCause((cause) =>
          Effect.logWarning("a Bancada notice was not delivered", { job: notice.job, cause }),
        ),
      )
  }

  // The process starts with the plugin, not with the first call: a server that comes back runs its Bancada at once.
  yield* Effect.tryPromise(() => client.call("wake", {})).pipe(
    Effect.catchCause((cause) => Effect.logWarning("the Bancada process did not start", { cause })),
    Effect.forkScoped({ startImmediately: true }),
  )
})

/** The root of a session's family. */
const rootOf = Effect.fnUntraced(function* (ctx: Pick<Context, "session">, sessionID: string) {
  const first = yield* ctx.session.get({ sessionID: Session.ID.make(sessionID) }).pipe(Effect.option)
  if (first._tag === "None") return sessionID
  let current = first.value
  for (let depth = 0; current.parentID && depth < 32; depth++) {
    const parent = yield* ctx.session.get({ sessionID: current.parentID }).pipe(Effect.option)
    if (parent._tag === "None") break
    current = parent.value
  }
  return current.id
})

/**
 * This server's own password, to wake itself (`OPENCODE_BANCADA_SELF`): the managed service's, else a manually run
 * server's (host-6's, whose launcher removes it from the environment and hands it in the private environment), else
 * the runtime's `password` file; never another server's.
 */
export async function ownPassword(env: Readonly<Record<string, string | undefined>>) {
  if (env.OPENCODE_CONFIG_DIR) {
    const service: unknown = await Bun.file(path.join(env.OPENCODE_CONFIG_DIR, "service-custom.json"))
      .json()
      .catch(() => undefined)
    if (
      typeof service === "object" &&
      service !== null &&
      "password" in service &&
      typeof service.password === "string"
    )
      if (service.password.trim()) return service.password.trim()
  }
  const given = (
    privateEnv("OPENCODE_SERVER_PASSWORD") ||
    env.OPENCODE_PASSWORD ||
    env.OPENCODE_SERVER_PASSWORD
  )?.trim()
  if (given) return given
  if (!env.OPENCODE_CUSTOM_HOME) return undefined
  const own = await Bun.file(path.join(env.OPENCODE_CUSTOM_HOME, "password"))
    .text()
    .catch(() => "")
  return own.trim() || undefined
}

/** The process's refusal between servers, by name; anything else is this machine's Bancada not answering. */
function refused(error: unknown, context: RpcCallContext<(typeof Bancada.Definition)["methods"]["sync"]>) {
  if (error instanceof BancadaError && error.reason === "not_hub") return context.error("not_hub", error.message, {})
  if (error instanceof BancadaError && error.reason === "invalid") return context.error("invalid", error.message, {})
  if (error instanceof BancadaError && error.reason === "protocol_mismatch")
    return context.error("protocol_mismatch", error.message, { expected: Number(error.data?.expected ?? 0) })
  if (error instanceof BancadaError && error.reason === "machine_taken")
    return context.error("machine_taken", error.message, {
      instanceID: String(error.data?.instanceID ?? ""),
      name: String(error.data?.name ?? ""),
    })
  const why = unavailable(error)
  return context.error("unavailable", why.message, why.data)
}

function refusal(error: unknown, context: RpcCallContext<(typeof Bancada.Definition)["methods"]["wake"]>) {
  const why = unavailable(error)
  return context.error("unavailable", why.message, why.data)
}

/** Why this machine's Bancada does not answer: another server owns it, or its process is out. */
function unavailable(error: unknown): { readonly message: string; readonly data: Bancada.Unavailable } {
  if (error instanceof BancadaError && error.reason === "owner")
    return { message: error.message, data: { reason: "owner", ...(error.owner ? { owner: error.owner } : {}) } }
  return {
    message:
      error instanceof BancadaError ? error.message : "O processo da Bancada desta máquina não está respondendo.",
    data: { reason: "process" },
  }
}

/**
 * The family's views with each session's title and agent read now, from this server (`docs/bancada.md`, "session":
 * `by`): the process knows only the titles of the moment of each request.
 */
const withAgents = Effect.fnUntraced(function* (ctx: Pick<Context, "session">, view: Record<string, unknown>) {
  type By = { sessionID: string; title?: string; agent?: string }
  const items = [...((view.using as { by: By }[]) ?? []), ...((view.waiting as { by: By }[]) ?? [])]
  const ids = [
    ...new Set([
      ...items.map((item) => item.by.sessionID),
      ...((view.members as By[]) ?? []).map((item) => item.sessionID),
    ]),
  ]
  const found = new Map(
    yield* Effect.forEach(ids, (id) =>
      ctx.session.get({ sessionID: Session.ID.make(id) }).pipe(
        Effect.map((session) => [id, { title: session.title, agent: session.agent }] as const),
        Effect.orElseSucceed(() => [id, undefined] as const),
      ),
    ),
  )
  const fill = <T extends By>(by: T): T => {
    const live = found.get(by.sessionID)
    return {
      ...by,
      ...(live?.title ? { title: live.title } : {}),
      ...(live?.agent ? { agent: live.agent } : {}),
    }
  }
  return {
    ...view,
    using: ((view.using as { by: By }[]) ?? []).map((item) => ({ ...item, by: fill(item.by) })),
    waiting: ((view.waiting as { by: By }[]) ?? []).map((item) => ({ ...item, by: fill(item.by) })),
    members: ((view.members as By[]) ?? []).map((member) => {
      const live = found.get(member.sessionID)
      return { ...member, ...(live?.title ? { title: live.title } : {}) }
    }),
  }
})
