import type { Context } from "../context.js"
import type { AgentEditor } from "@opencode/plugin/effect/agent"
import type { ToolEditor } from "@opencode/plugin/effect/tool"
import { optional } from "@opencode/schema/schema"
import { Tool } from "@opencode/schema/tool"
import { Clock, Deferred, Effect, Option, Schema } from "effect"
import { agentID } from "../master/index.js"
import { Device } from "./rpc.js"

export const limits = {
  /** The app renews its presence about every 30 seconds while its event stream is connected. */
  leaseSeconds: 75,
  defaultTimeoutSeconds: 5,
  maxTimeoutSeconds: 30,
  healthDays: 90,
  motionDays: 7,
  /** Devices not seen for this long are dropped from presence. */
  forgetDays: 30,
}

export const presenceKey = "device:presence"

export const instructions = `Dados do iPhone de Alexandre: use iphone_status para ver se o app está conectado e quais fontes estão ligadas, e iphone_query para ler aparelho, rede, localização, Saúde, movimento ou fotos recentes na hora. Se a resposta vier offline, timeout, locked, disabled ou denied, diga isso claramente (por exemplo: abra o app OpenCode no iPhone, desbloqueie-o ou ligue a fonte em Você → Dados do iPhone) e não invente valores.`

const Entry = Schema.Struct({
  deviceID: Schema.String,
  name: Schema.String,
  model: optional(Schema.String),
  system: optional(Schema.String),
  sources: Schema.Array(Device.SourceState),
  seenAt: Schema.Number,
  expiresAt: Schema.Number,
  detached: Schema.Boolean,
})
type Entry = typeof Entry.Type
const Presence = Schema.Array(Entry)
const decodePresence = (value: Schema.Json | undefined) =>
  Option.getOrElse(Schema.decodeUnknownOption(Presence)(value ?? []), () => [])
const encodePresence = Schema.encodeSync(Presence)

export const QueryInput = Schema.Struct({
  ...Device.Query.fields,
  timeoutSeconds: optional(
    Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: limits.maxTimeoutSeconds })).annotate({
      description: `Seconds to wait for the iPhone. Defaults to ${limits.defaultTimeoutSeconds}.`,
    }),
  ),
})
export type QueryInput = typeof QueryInput.Type

const DeviceView = Schema.Struct({
  deviceID: Schema.String,
  name: Schema.String,
  model: optional(Schema.String),
  system: optional(Schema.String),
  online: Schema.Boolean,
  lastSeen: Schema.Number,
  sources: Schema.Array(Device.SourceState),
})
export const StatusOutput = Schema.Struct({ online: Schema.Boolean, devices: Schema.Array(DeviceView) })

export const QueryOutput = Schema.Struct({
  source: Device.Source,
  status: Device.Status,
  device: optional(Schema.String),
  lastSeen: optional(Schema.Number),
  collectedAt: optional(Schema.Number),
  data: optional(Schema.Json),
  note: optional(Schema.String),
  truncated: optional(Schema.Boolean),
  files: optional(Schema.Array(Schema.Struct({ name: Schema.String, mime: Schema.String }))),
})
export type QueryOutput = typeof QueryOutput.Type

export type DeviceContext = {
  storage: Pick<Context["storage"], "get" | "update">
  /** The Location of this plugin instance; responses must be routed back to it. */
  directory: string
  emit: (request: Device.Request) => Effect.Effect<void, unknown>
}

export const registerDevice = Effect.fn("Device.register")(function* (ctx: Context) {
  const emitter = yield* Deferred.make<(request: Device.Request) => Effect.Effect<void, unknown>>()
  const device = makeDevice({
    storage: ctx.storage,
    directory: ctx.location.directory,
    emit: (request) => Deferred.await(emitter).pipe(Effect.flatMap((emit) => emit(request))),
  })
  const registration = yield* ctx.rpc
    .register(Device.Definition, {
      attach: device.attach,
      detach: device.detach,
      respond: device.respond,
    })
    .pipe(Effect.orDie)
  yield* Deferred.succeed(emitter, (request) => registration.events.emit("request", { request }))
  yield* ctx.agent.transform(configureMaster)
  yield* ctx.tool.transform((editor) => registerTools(editor, device))
})

/**
 * Presence lives in plugin storage, which every Location's plugin instance shares. Pending requests stay in this
 * instance: the request event carries this Location's directory and the app answers through it.
 */
export function makeDevice(ctx: DeviceContext) {
  const pending = new Map<string, { deviceID: string; answer: Deferred.Deferred<Device.Answer> }>()

  const attach = Effect.fn("Device.attach")(function* (input: Device.Attach) {
    const now = yield* Clock.currentTimeMillis
    yield* ctx.storage.update(presenceKey, (current) => [
      encodePresence([
        {
          deviceID: input.deviceID,
          name: input.name,
          ...(input.model ? { model: input.model } : {}),
          ...(input.system ? { system: input.system } : {}),
          sources: input.sources,
          seenAt: now,
          expiresAt: now + limits.leaseSeconds * 1000,
          detached: false,
        },
        ...decodePresence(current).filter(
          (entry) => entry.deviceID !== input.deviceID && now - entry.seenAt < limits.forgetDays * 86_400_000,
        ),
      ]),
      undefined,
    ])
    return { leaseSeconds: limits.leaseSeconds }
  })

  const detach = Effect.fn("Device.detach")(function* (input: { readonly deviceID: string }) {
    const now = yield* Clock.currentTimeMillis
    yield* ctx.storage.update(presenceKey, (current) => [
      encodePresence(
        decodePresence(current).map((entry) =>
          entry.deviceID === input.deviceID ? { ...entry, seenAt: now, detached: true } : entry,
        ),
      ),
      undefined,
    ])
    return {}
  })

  const respond = Effect.fn("Device.respond")(function* (input: {
    readonly deviceID: string
    readonly requestID: string
    readonly answer: Device.Answer
  }) {
    const waiting = pending.get(input.requestID)
    if (!waiting || waiting.deviceID !== input.deviceID) return { accepted: false }
    pending.delete(input.requestID)
    return { accepted: yield* Deferred.succeed(waiting.answer, input.answer) }
  })

  const devices = Effect.fn("Device.devices")(function* () {
    const now = yield* Clock.currentTimeMillis
    return decodePresence(yield* ctx.storage.get(presenceKey))
      .map((entry) => ({
        deviceID: entry.deviceID,
        name: entry.name,
        ...(entry.model ? { model: entry.model } : {}),
        ...(entry.system ? { system: entry.system } : {}),
        online: !entry.detached && entry.expiresAt > now,
        lastSeen: entry.seenAt,
        sources: entry.sources,
      }))
      .toSorted((a, b) => Number(b.online) - Number(a.online) || b.lastSeen - a.lastSeen)
  })

  const status = Effect.fn("Device.status")(function* () {
    const list = yield* devices()
    return { online: list.some((entry) => entry.online), devices: list }
  })

  /** Asks the most recently seen online iPhone; images travel separately from the JSON output. */
  const query = Effect.fn("Device.query")(function* (input: QueryInput) {
    const problem = invalid(input)
    if (problem) return yield* new Tool.Error({ message: problem })
    const target = (yield* devices())[0]
    const none = (output: QueryOutput) => ({ output, images: [] as readonly Device.File[] })
    if (!target?.online)
      return none({
        source: input.source,
        status: "offline",
        ...(target ? { device: target.name, lastSeen: target.lastSeen } : {}),
        note: target
          ? "The OpenCode app is not running on the iPhone (closed, suspended or disconnected)."
          : "No iPhone has connected to this server yet.",
      })
    if (target.sources.some((item) => item.source === input.source && !item.enabled))
      return none({
        source: input.source,
        status: "disabled",
        device: target.name,
        note: "This source is turned off in the app (Você → Dados do iPhone).",
      })
    const { timeoutSeconds, ...request } = input
    const timeout = (timeoutSeconds ?? limits.defaultTimeoutSeconds) * 1000
    const now = yield* Clock.currentTimeMillis
    const requestID = crypto.randomUUID()
    const answer = yield* Deferred.make<Device.Answer>()
    pending.set(requestID, { deviceID: target.deviceID, answer })
    const received = yield* ctx
      .emit({ requestID, deviceID: target.deviceID, query: request, deadline: now + timeout, directory: ctx.directory })
      .pipe(
        Effect.mapError((error) => new Tool.Error({ message: "Unable to send the request to the iPhone", error })),
        Effect.andThen(Deferred.await(answer)),
        Effect.timeoutOption(timeout),
        Effect.ensuring(Effect.sync(() => pending.delete(requestID))),
      )
    if (Option.isNone(received))
      return none({
        source: input.source,
        status: "timeout",
        device: target.name,
        lastSeen: target.lastSeen,
        note: `The iPhone did not answer within ${timeout / 1000} seconds.`,
      })
    const value = received.value
    return {
      output: {
        source: input.source,
        device: target.name,
        status: value.status,
        ...(value.collectedAt === undefined ? {} : { collectedAt: value.collectedAt }),
        ...(value.data === undefined ? {} : { data: value.data }),
        ...(value.note === undefined ? {} : { note: value.note }),
        ...(value.truncated === undefined ? {} : { truncated: value.truncated }),
        ...(value.files ? { files: value.files.map((file) => ({ name: file.name, mime: file.mime })) } : {}),
      },
      images: value.files ?? [],
    }
  })

  return { attach, detach, respond, status, query, pending }
}

export function configureMaster(editor: AgentEditor) {
  editor.update(agentID, (agent) => {
    if (agent.system?.includes(instructions)) return
    agent.system = agent.system ? `${agent.system}\n${instructions}` : instructions
  })
}

export function registerTools(editor: ToolEditor, device: ReturnType<typeof makeDevice>) {
  editor.add({
    name: "iphone_status",
    description:
      "Check whether Alexandre's (the user's) iPhone is reachable before or instead of reading it: online is true while the OpenCode app is open on the iPhone or a voice call keeps it running. Lists each device's last contact (epoch ms) and every data source with its in-app switch and iOS permission.",
    input: standard(Schema.Struct({})),
    output: standard(StatusOutput),
    options: { codemode: false },
    execute: () => device.status().pipe(Effect.map((output) => ({ output, content: JSON.stringify(output) }))),
  })
  editor.add({
    name: "iphone_query",
    description: [
      "Read live data from Alexandre's (the user's) iPhone when he asks about his phone, health, sleep, workouts, activity, location or recent photos. The OpenCode app on the iPhone collects it on demand within the timeout (default 5 s, max 30 s); nothing is stored on the server.",
      "Sources: device (battery, low power, thermal, storage, model, iOS); network (Wi-Fi/cellular, expensive, constrained); location (current position and reverse-geocoded address; with the app in the background only the last known position);",
      `health (metrics sleep, steps, activeEnergy, restingHeartRate, hrv, workouts, weight; from/to as YYYY-MM-DD in the iPhone's time zone, at most ${limits.healthDays} days, default the last 7; granularity day = daily aggregates, sample = also individual sleep samples);`,
      `motion (CoreMotion steps, distance, floors and walking/running/automotive minutes per day; last ${limits.motionDays} days only); photos (recent photos' date, place and type; limit 1–10, default 5; thumbnails default true, attached as images).`,
      "When status is not ok, report it instead of guessing values: offline = the app is not running on the iPhone (ask him to open it); timeout = the iPhone did not answer in time; locked = the iPhone is locked and health data cannot be read (a note says when a cached daily summary answered instead); disabled = the source is off in the app (Você → Dados do iPhone); denied = iOS permission missing; unavailable = not available on this device or right now.",
    ].join(" "),
    input: standard(QueryInput),
    output: standard(QueryOutput),
    options: { codemode: false },
    execute: (input) =>
      device.query(input).pipe(
        Effect.map((result) => ({
          output: result.output,
          content: [
            { type: "text" as const, text: JSON.stringify(result.output) },
            ...result.images.map((file) => ({
              type: "file" as const,
              uri: `data:${file.mime};base64,${file.data}`,
              mime: file.mime,
              name: file.name,
            })),
          ],
        })),
      ),
  })
}

function invalid(input: QueryInput) {
  if (input.from && input.to && input.from > input.to) return "from must not be after to"
  const span = input.from && input.to ? (Date.parse(input.to) - Date.parse(input.from)) / 86_400_000 + 1 : 0
  if (input.source === "health" && span > limits.healthDays)
    return `health queries cover at most ${limits.healthDays} days`
  if (input.source === "motion" && span > limits.motionDays + 1)
    return `motion history covers at most the last ${limits.motionDays} days`
  return undefined
}

function standard<A>(schema: Schema.Codec<A, unknown>) {
  return {
    "~standard": {
      ...Schema.toStandardSchemaV1(schema)["~standard"],
      ...Schema.toStandardJSONSchemaV1(schema)["~standard"],
    },
  }
}
