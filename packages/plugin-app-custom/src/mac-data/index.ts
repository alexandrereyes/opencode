import { Plugin } from "@opencode/plugin/effect"
import type { ToolEditor } from "@opencode/plugin/effect/tool"
import { PositiveInt } from "@opencode/schema/schema"
import { Tool } from "@opencode/schema/tool"
import { Effect, Option, Schema } from "effect"
import path from "node:path"
import { agentID } from "../master/index.js"

export const toolName = "mac_query"
// Release layout from packages/cli/script/custom-signing.ts: <release>/plugin/index.js beside the app bundle.
export const releaseHelper = path.join(
  import.meta.dirname,
  "..",
  "OpenCode Custom.app/Contents/Helpers/OpenCode Mac Data.app/Contents/MacOS/opencode-mac-data",
)
const maxCharacters = 20_000

const When = Schema.String.check(
  Schema.isPattern(/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:\d{2})?)?$/),
)
const Names = Schema.Array(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))).check(
  Schema.isMaxLength(20),
)
const Query = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))
const Limit = (max: number) => PositiveInt.check(Schema.isLessThanOrEqualTo(max))
export const Input = Schema.Union([
  Schema.Struct({
    source: Schema.Literal("calendar"),
    from: Schema.optionalKey(When),
    to: Schema.optionalKey(When),
    calendars: Schema.optionalKey(Names),
    query: Schema.optionalKey(Query),
    limit: Schema.optionalKey(Limit(200)),
  }),
  Schema.Struct({
    source: Schema.Literal("reminders"),
    status: Schema.optionalKey(Schema.Literals(["pending", "completed", "all"])),
    from: Schema.optionalKey(When),
    to: Schema.optionalKey(When),
    lists: Schema.optionalKey(Names),
    query: Schema.optionalKey(Query),
    limit: Schema.optionalKey(Limit(200)),
  }),
  Schema.Struct({
    source: Schema.Literal("contacts"),
    query: Query,
    limit: Schema.optionalKey(Limit(50)),
  }),
  Schema.Struct({ source: Schema.Literal("status") }),
])

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
})
const Reply = Schema.Union([
  Calendar,
  Reminders,
  Contacts,
  Status,
  Schema.Struct({
    error: Schema.Literals(["denied", "restricted", "notDetermined", "invalid", "failed"]),
    source: Schema.NullOr(Schema.String),
    message: Schema.String,
  }),
])
export const Output = Schema.Union([
  Schema.Struct({ ...Calendar.fields, truncated: Schema.Boolean }),
  Schema.Struct({ ...Reminders.fields, truncated: Schema.Boolean }),
  Schema.Struct({ ...Contacts.fields, truncated: Schema.Boolean }),
  Status,
])

export const registerMacData = Effect.fn("MacData.register")(function* (ctx: Plugin.Context) {
  if (process.platform !== "darwin") return
  yield* ctx.tool.transform((editor) => registerTools(editor, process.env.OPENCODE_MAC_DATA_HELPER ?? releaseHelper))
})

export function registerTools(editor: ToolEditor, helper: string) {
  editor.namespace({ name: "mac", description: "Alexandre's Calendar, Reminders and Contacts, read on his Mac." })
  editor.add({
    name: toolName,
    description: [
      "Read Alexandre's Calendar, Reminders or Contacts from his Mac (iCloud-synced, read-only).",
      "Dates are YYYY-MM-DD (a whole local day; `to` is inclusive) or ISO date-times; results carry the Mac time zone and ISO times with offset.",
      "calendar: events in [from, to], default today plus 7 days, at most 366 days; filter by calendar names or a text query.",
      "reminders: status pending (default; from/to filter the due date), completed (completion date, default last 30 days) or all; filter by list names or text.",
      "contacts: search by name, phone or e-mail; returns phones, e-mails, birthday (--MM-DD when the year is unknown) and addresses.",
      "status: permission state without prompting. Lists are bounded by limit (default 50; contacts 10) and 20,000 characters; check truncated and total.",
    ].join(" "),
    input: standard(Input),
    output: standard(Output),
    options: { namespace: "mac", codemode: true, agents: [agentID] },
    execute: (input, context) =>
      Effect.gen(function* () {
        if (context.agent !== agentID)
          return yield* new Tool.Error({ message: "Only the Mestra agent may read Mac personal data" })
        const output = bound(input, yield* query(helper, input))
        return { output, content: JSON.stringify(output) }
      }),
  })
}

function query(helper: string, input: typeof Input.Type) {
  return Effect.gen(function* () {
    const result = yield* Effect.tryPromise({
      try: async (signal) => {
        const child = Bun.spawn([helper, JSON.stringify(input)], {
          signal,
          stdin: "ignore",
          stdout: "pipe",
          stderr: "pipe",
        })
        const [code, stdout, stderr] = await Promise.all([
          child.exited,
          new Response(child.stdout).text(),
          new Response(child.stderr).text(),
        ])
        return { code, stdout, stderr }
      },
      catch: () =>
        new Tool.Error({
          message: `Could not run the OpenCode Mac Data helper at ${helper}; it ships with custom:update releases`,
          metadata: { reason: "unavailable" },
        }),
    }).pipe(
      // The helper waits up to 50 seconds for a first-time permission prompt.
      Effect.timeoutOrElse({
        duration: "70 seconds",
        orElse: () => Effect.fail(new Tool.Error({ message: "The Mac data helper did not answer within 70 seconds" })),
      }),
    )
    const reply = Schema.decodeUnknownOption(Schema.fromJsonString(Reply))(result.stdout.trim())
    if (Option.isNone(reply))
      return yield* new Tool.Error({
        message: `The Mac data helper failed (exit ${result.code}): ${(result.stderr || result.stdout).trim().slice(0, 500)}`,
      })
    if ("error" in reply.value) return yield* failure(reply.value)
    return reply.value
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
  if (error.error === "notDetermined")
    return new Tool.Error({
      message: `The macOS prompt asking to give "OpenCode Mac Data" access to ${pane.name} was not answered. Ask Alexandre to click Allow on that prompt, then retry.`,
      metadata,
    })
  if (error.error === "restricted")
    return new Tool.Error({ message: `${pane.name} access is restricted by a macOS device policy.`, metadata })
  return new Tool.Error({
    message: `${pane.name} access is denied for "OpenCode Mac Data". Ask Alexandre to enable it in System Settings → Privacy & Security → ${pane.en} (Ajustes do Sistema → Privacidade e Segurança → ${pane.pt})${pane.full ? " with Full Access" : ""}, then retry.`,
    metadata,
  })
}

function bound(input: typeof Input.Type, reply: Exclude<typeof Reply.Type, { readonly error: unknown }>) {
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
