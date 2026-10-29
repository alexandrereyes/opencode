import { Plugin } from "@opencode/plugin/effect"
import type { ToolEditor } from "@opencode/plugin/effect/tool"
import { optional } from "@opencode/schema/schema"
import { Tool } from "@opencode/schema/tool"
import { Clock, Deferred, Effect, Option, Schema } from "effect"
import { MacData } from "./rpc.js"

export const toolName = "mac_query"
export const presenceKey = "mac:presence"
export const limits = {
  /** The app renews its presence about every 30 seconds while its event stream is connected. */
  leaseSeconds: 75,
  /** Long enough for a first-time macOS permission prompt, which the app waits for. */
  timeoutSeconds: 60,
  /** Macs not seen for this long are dropped from presence. */
  forgetDays: 30,
}
const maxCharacters = 20_000

const Labeled = Schema.Struct({ label: Schema.String, value: Schema.String })
const Event = Schema.Struct({
  title: Schema.String,
  start: Schema.String,
  end: Schema.String,
  allDay: Schema.Boolean,
  calendar: Schema.String,
  account: Schema.optionalKey(Schema.String),
  location: Schema.optionalKey(Schema.String),
  notes: Schema.optionalKey(Schema.String),
  url: Schema.optionalKey(Schema.String),
  attendees: Schema.optionalKey(Schema.Array(Schema.String)),
  recurring: Schema.optionalKey(Schema.Boolean),
  canceled: Schema.optionalKey(Schema.Boolean),
})
const Reminder = Schema.Struct({
  title: Schema.String,
  list: Schema.String,
  completed: Schema.Boolean,
  due: Schema.optionalKey(Schema.String),
  completedAt: Schema.optionalKey(Schema.String),
  priority: Schema.optionalKey(Schema.Literals(["high", "medium", "low"])),
  notes: Schema.optionalKey(Schema.String),
  url: Schema.optionalKey(Schema.String),
})
const Contact = Schema.Struct({
  name: Schema.String,
  phones: Schema.Array(Labeled),
  emails: Schema.Array(Labeled),
  nickname: Schema.optionalKey(Schema.String),
  organization: Schema.optionalKey(Schema.String),
  jobTitle: Schema.optionalKey(Schema.String),
  birthday: Schema.optionalKey(Schema.String),
  addresses: Schema.optionalKey(Schema.Array(Labeled)),
})
const Permission = Schema.Literals(["granted", "notDetermined", "denied", "restricted"])
const Calendar = Schema.Struct({
  source: Schema.Literal("calendar"),
  timeZone: Schema.String,
  from: Schema.String,
  to: Schema.String,
  availableCalendars: Schema.Array(Schema.String),
  total: Schema.Number,
  events: Schema.Array(Event),
})
const Reminders = Schema.Struct({
  source: Schema.Literal("reminders"),
  timeZone: Schema.String,
  status: Schema.Literals(["pending", "completed", "all"]),
  availableLists: Schema.Array(Schema.String),
  total: Schema.Number,
  reminders: Schema.Array(Reminder),
})
const Contacts = Schema.Struct({
  source: Schema.Literal("contacts"),
  timeZone: Schema.String,
  total: Schema.Number,
  contacts: Schema.Array(Contact),
})
const Status = Schema.Struct({
  source: Schema.Literal("status"),
  permissions: Schema.Struct({ calendar: Permission, reminders: Permission, contacts: Permission }),
  /** The switches in the app's Ajustes → Dados do Mac. */
  enabled: Schema.Struct({ calendar: Schema.Boolean, reminders: Schema.Boolean, contacts: Schema.Boolean }),
})
/** What the Mac app answers: a result or a failure. */
export const Reply = Schema.Union([
  Calendar,
  Reminders,
  Contacts,
  Status,
  Schema.Struct({
    error: Schema.Literals(["denied", "restricted", "notDetermined", "disabled", "invalid", "failed"]),
    source: Schema.NullOr(Schema.String),
    message: Schema.String,
  }),
])
export type Reply = typeof Reply.Type
export const Output = Schema.Union([
  Schema.Struct({ ...Calendar.fields, truncated: Schema.Boolean }),
  Schema.Struct({ ...Reminders.fields, truncated: Schema.Boolean }),
  Schema.Struct({ ...Contacts.fields, truncated: Schema.Boolean }),
  Status,
])

const Entry = Schema.Struct({
  deviceID: Schema.String,
  name: Schema.String,
  model: optional(Schema.String),
  system: optional(Schema.String),
  seenAt: Schema.Number,
  expiresAt: Schema.Number,
  detached: Schema.Boolean,
})
const Presence = Schema.Array(Entry)
const decodePresence = (value: Schema.Json | undefined) =>
  Option.getOrElse(Schema.decodeUnknownOption(Presence)(value ?? []), () => [])
const encodePresence = Schema.encodeSync(Presence)

export type MacContext = {
  storage: Pick<Plugin.Context["storage"], "get" | "update">
  /** The Location of this plugin instance; answers must be routed back to it. */
  directory: string
  emit: (request: MacData.Request) => Effect.Effect<void, unknown>
}

export const registerMacData = Effect.fn("MacData.register")(function* (ctx: Plugin.Context) {
  const emitter = yield* Deferred.make<(request: MacData.Request) => Effect.Effect<void, unknown>>()
  const mac = makeMac({
    storage: ctx.storage,
    directory: ctx.location.directory,
    emit: (request) => Deferred.await(emitter).pipe(Effect.flatMap((emit) => emit(request))),
  })
  const registration = yield* ctx.rpc
    .register(MacData.Definition, { attach: mac.attach, detach: mac.detach, respond: mac.respond })
    .pipe(Effect.orDie)
  yield* Deferred.succeed(emitter, (request) => registration.events.emit("request", { request }))
  yield* ctx.tool.transform((editor) => registerTools(editor, mac))
})

/**
 * The OpenCode app on the Mac reads Calendar, Reminders and Contacts, under its own macOS grants, and answers through
 * `custom.mac` like the iPhone answers `custom.device`: presence lives in plugin storage, shared by every Location's
 * plugin instance, and pending requests stay in the instance whose Location the request carries.
 */
export function makeMac(ctx: MacContext) {
  const pending = new Map<string, { deviceID: string; answer: Deferred.Deferred<Schema.Json> }>()

  const attach = Effect.fn("MacData.attach")(function* (input: MacData.Attach) {
    const now = yield* Clock.currentTimeMillis
    yield* ctx.storage.update(presenceKey, (current) => [
      encodePresence([
        {
          deviceID: input.deviceID,
          name: input.name,
          ...(input.model ? { model: input.model } : {}),
          ...(input.system ? { system: input.system } : {}),
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

  const detach = Effect.fn("MacData.detach")(function* (input: { readonly deviceID: string }) {
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

  const respond = Effect.fn("MacData.respond")(function* (input: {
    readonly deviceID: string
    readonly requestID: string
    readonly answer: Schema.Json
  }) {
    const waiting = pending.get(input.requestID)
    if (!waiting || waiting.deviceID !== input.deviceID) return { accepted: false }
    pending.delete(input.requestID)
    return { accepted: yield* Deferred.succeed(waiting.answer, input.answer) }
  })

  /** Asks the most recently seen online Mac. */
  const query = Effect.fn("MacData.query")(function* (input: MacData.Query) {
    const now = yield* Clock.currentTimeMillis
    const target = decodePresence(yield* ctx.storage.get(presenceKey))
      .map((entry) => ({ ...entry, online: !entry.detached && entry.expiresAt > now }))
      .toSorted((a, b) => Number(b.online) - Number(a.online) || b.seenAt - a.seenAt)[0]
    if (!target?.online)
      return yield* new Tool.Error({
        message: target
          ? `The OpenCode app is not running on ${target.name} (closed or disconnected since ${new Date(target.seenAt).toISOString()}). Ask Alexandre to open it, then retry.`
          : "The OpenCode app on the Mac has never connected to this server. Ask Alexandre to open it, then retry.",
        metadata: { reason: "offline" },
      })
    const requestID = crypto.randomUUID()
    const answer = yield* Deferred.make<Schema.Json>()
    pending.set(requestID, { deviceID: target.deviceID, answer })
    const received = yield* ctx
      .emit({
        requestID,
        deviceID: target.deviceID,
        query: input,
        deadline: now + limits.timeoutSeconds * 1000,
        directory: ctx.directory,
      })
      .pipe(
        Effect.mapError((error) => new Tool.Error({ message: "Unable to send the request to the Mac", error })),
        Effect.andThen(Deferred.await(answer)),
        Effect.timeoutOption(limits.timeoutSeconds * 1000),
        Effect.ensuring(Effect.sync(() => pending.delete(requestID))),
      )
    if (Option.isNone(received))
      return yield* new Tool.Error({
        message: `The OpenCode app on ${target.name} did not answer within ${limits.timeoutSeconds} seconds.`,
        metadata: { reason: "timeout" },
      })
    const reply = Schema.decodeUnknownOption(Reply)(received.value)
    if (Option.isNone(reply))
      return yield* new Tool.Error({
        message: `The OpenCode app on ${target.name} answered in an unexpected format: ${JSON.stringify(received.value).slice(0, 500)}`,
      })
    if ("error" in reply.value) return yield* failure(reply.value)
    return bound(input, reply.value)
  })

  return { attach, detach, respond, query, pending }
}

export function registerTools(editor: ToolEditor, mac: ReturnType<typeof makeMac>) {
  editor.namespace({ name: "mac", description: "Alexandre's Calendar, Reminders and Contacts, read on his Mac." })
  editor.add({
    name: toolName,
    description: [
      "Read Alexandre's (the user's) Calendar, Reminders or Contacts from his Mac (iCloud-synced, read-only) when he asks about his schedule, events, reminders/to-dos or a person's phone, e-mail, birthday or address.",
      "The OpenCode app on the Mac reads them on demand, so it must be open.",
      "Dates are YYYY-MM-DD (a whole local day; `to` is inclusive) or ISO date-times; results carry the Mac time zone and ISO times with offset.",
      "calendar: events in [from, to], default today plus 7 days, at most 366 days; filter by calendar names or a text query.",
      "reminders: status pending (default; from/to filter the due date), completed (completion date, default last 30 days) or all; filter by list names or text.",
      "contacts: search by name, phone or e-mail; returns phones, e-mails, birthday (--MM-DD when the year is unknown) and addresses.",
      "status: macOS permission and in-app switch of each source, without prompting. Lists are bounded by limit (default 50; contacts 10) and 20,000 characters; check truncated and total.",
      "Failures say what to do; relay them instead of guessing: offline (the app is closed on the Mac; he opens it), timeout, disabled (the source is off in the app's Ajustes → Dados do Mac), notDetermined (a macOS permission prompt on the Mac was not answered; he clicks Allow), denied (he enables OpenCode in System Settings → Privacy & Security), restricted (blocked by a device policy).",
    ].join(" "),
    input: standard(MacData.Query),
    output: standard(Output),
    options: { namespace: "mac", codemode: true },
    execute: (input) => mac.query(input).pipe(Effect.map((output) => ({ output, content: JSON.stringify(output) }))),
  })
}

const panes = {
  calendar: { name: "Calendar", en: "Calendars", pt: "Calendários", full: true },
  reminders: { name: "Reminders", en: "Reminders", pt: "Lembretes", full: true },
  contacts: { name: "Contacts", en: "Contacts", pt: "Contatos", full: false },
}

function failure(error: { error: string; source: string | null; message: string }) {
  const pane =
    error.source === "calendar" || error.source === "reminders" || error.source === "contacts"
      ? panes[error.source]
      : undefined
  const metadata = { reason: error.error, source: error.source }
  if (!pane || error.error === "invalid" || error.error === "failed")
    return new Tool.Error({ message: error.message, metadata })
  if (error.error === "disabled")
    return new Tool.Error({
      message: `${pane.name} is turned off in the OpenCode app on the Mac. Ask Alexandre to turn it on in OpenCode → Ajustes → Dados do Mac, then retry.`,
      metadata,
    })
  if (error.error === "notDetermined")
    return new Tool.Error({
      message: `The macOS prompt asking to give the OpenCode app access to ${pane.name} was not answered. Ask Alexandre to click Allow on that prompt on the Mac (or in OpenCode → Ajustes → Dados do Mac), then retry.`,
      metadata,
    })
  if (error.error === "restricted")
    return new Tool.Error({ message: `${pane.name} access is restricted by a macOS device policy.`, metadata })
  return new Tool.Error({
    message: `${pane.name} access is denied for the OpenCode app. Ask Alexandre to enable "OpenCode" in System Settings → Privacy & Security → ${pane.en} (Ajustes do Sistema → Privacidade e Segurança → ${pane.pt})${pane.full ? " with Full Access" : ""}, then retry.`,
    metadata,
  })
}

function bound(input: MacData.Query, reply: Exclude<Reply, { readonly error: unknown }>) {
  if (reply.source === "status") return reply
  const limit = ("limit" in input ? input.limit : undefined) ?? (reply.source === "contacts" ? 10 : 50)
  if (reply.source === "calendar") {
    const events = fit(reply.events, limit)
    return { ...reply, events, truncated: events.length < reply.total }
  }
  if (reply.source === "reminders") {
    const reminders = fit(reply.reminders, limit)
    return { ...reply, reminders, truncated: reminders.length < reply.total }
  }
  const contacts = fit(reply.contacts, limit)
  return { ...reply, contacts, truncated: contacts.length < reply.total }
}

function fit<A>(items: readonly A[], limit: number) {
  return items.slice(0, limit).reduce<{ data: A[]; size: number; full: boolean }>(
    (result, item) => {
      if (result.full) return result
      const size = result.size + JSON.stringify(item).length
      if (size > maxCharacters) return { ...result, full: true }
      return { data: [...result.data, item], size, full: false }
    },
    { data: [], size: 0, full: false },
  ).data
}

function standard<A>(schema: Schema.Codec<A, unknown>) {
  return {
    "~standard": {
      ...Schema.toStandardSchemaV1(schema)["~standard"],
      ...Schema.toStandardJSONSchemaV1(schema)["~standard"],
    },
  }
}
