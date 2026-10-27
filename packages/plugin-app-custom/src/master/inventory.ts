import { stat } from "node:fs/promises"
import path from "node:path"
import type { Plugin } from "@opencode/plugin/effect"
import type { PendingSnapshot } from "@opencode/plugin/effect/request"
import { Agent } from "@opencode/schema/agent"
import { Form } from "@opencode/schema/form"
import { Model } from "@opencode/schema/model"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import type { SessionScan } from "@opencode/schema/session-scan"
import { DateTime, Effect, Schema } from "effect"
import { Preferences } from "../preferences/rpc.js"
import { Master } from "./rpc.js"

const agentID = Master.agentID

export type InventoryContext = {
  session: Pick<Plugin.Context["session"], "get" | "scan" | "active">
  request: Pick<Plugin.Context["request"], "pending">
  /** Pinned and muted sessions shared by the iOS and web lists; absent in tests without preferences. */
  marks?: () => Effect.Effect<{ pinned: readonly string[]; muted: readonly string[] }>
  /** Root of the managed chats, whose sessions have no project of their own. */
  chats?: () => Effect.Effect<string | undefined>
}

export const State = Schema.Literals(["running", "needs-you", "idle"])

export const Summary = Schema.Struct({
  id: Session.ID,
  title: Schema.String,
  project: Schema.String,
  directory: AbsolutePath,
  projectID: Project.ID,
  state: State,
  unread: Schema.Boolean,
  failed: Schema.optionalKey(Schema.Literal(true)),
  outcome: Schema.optionalKey(Schema.Literals(["succeeded", "failed", "interrupted"])),
  lastActivity: Schema.Number,
  completedAt: Schema.optionalKey(Schema.Number),
  pending: Schema.Struct({ questions: Schema.Number, permissions: Schema.Number }),
  subagentsRunning: Schema.optionalKey(Schema.Number),
  pinned: Schema.optionalKey(Schema.Literal(true)),
  muted: Schema.optionalKey(Schema.Literal(true)),
  archived: Schema.optionalKey(Schema.Literal(true)),
  agent: Schema.optionalKey(Agent.ID),
  model: Schema.optionalKey(Model.Ref),
})
export type Summary = typeof Summary.Type

export type Inventory = {
  /** Every top-level session except Mestra sessions, archived ones included; newest activity first. */
  rows: SessionScan.Info[]
  active: Record<string, { readonly type: "running" }>
  pending: readonly PendingSnapshot[]
  /** Owner session (root or descendant) of every running session and pending request → its root. */
  roots: Map<string, Session.ID>
  marks: { pinned: Set<string>; muted: Set<string> }
  projects: Map<string, ProjectInfo>
}

export type ProjectInfo = {
  id: Project.ID
  name: string
  directory: AbsolutePath
  directories: AbsolutePath[]
  chats: boolean
}

export function isQuestion(form: Form.Info) {
  return form.metadata?.kind === "question" || form.metadata?.kind === "websearch.provider"
}

export function millis(value: DateTime.Utc | undefined) {
  return value === undefined ? undefined : DateTime.toEpochMillis(value)
}

export function activity(row: SessionScan.Info) {
  return row.messageAt ?? DateTime.toEpochMillis(row.session.time.created)
}

/** Same rule as the app lists: a finished run, or a newer completion, that was not opened since. */
export function attention(row: SessionScan.Info) {
  const viewed = millis(row.session.time.viewed) ?? 0
  const idle = millis(row.session.time.idle)
  const unreadAt =
    idle !== undefined && idle > viewed
      ? row.completionAt !== undefined && row.completionAt > viewed
        ? row.completionAt
        : row.session.outcome === "succeeded" || row.session.outcome === "failed"
          ? idle
          : undefined
      : undefined
  return {
    unreadAt,
    failed: row.session.outcome === "failed" && idle !== undefined && idle > viewed,
  }
}

const scanAll = (
  ctx: InventoryContext,
  input: SessionScan.Input,
  after?: Session.ID,
): Effect.Effect<SessionScan.Info[]> =>
  ctx.session
    .scan({ ...input, limit: 500, after })
    .pipe(
      Effect.flatMap((page) =>
        page.next && page.next !== after
          ? scanAll(ctx, input, page.next).pipe(Effect.map((rest) => [...page.data, ...rest]))
          : Effect.succeed([...page.data]),
      ),
    )

export const inventory = Effect.fn("Master.inventory")(function* (ctx: InventoryContext) {
  const rows = (yield* scanAll(ctx, { parentID: null }))
    .filter((row) => !row.session.parentID && row.session.agent !== agentID)
    .toSorted((a, b) => activity(b) - activity(a) || b.session.id.localeCompare(a.session.id))
  const active = yield* ctx.session.active()
  const pending = yield* ctx.request.pending()
  const known = new Map<string, Session.Info>(rows.map((row) => [row.session.id, row.session]))
  const roots = new Map<string, Session.ID>()
  const owners = new Set([
    ...Object.keys(active),
    ...pending.flatMap((item) => [
      ...item.permissions.map((request) => request.sessionID),
      ...item.forms.map((form) => form.sessionID),
    ]),
  ])
  for (const owner of owners) {
    const root = yield* rootOf(ctx, owner, known)
    if (root) roots.set(owner, root)
  }
  const marks = ctx.marks ? yield* ctx.marks() : { pinned: [], muted: [] }
  const chatsRoot = ctx.chats ? yield* ctx.chats() : undefined
  return {
    rows,
    active,
    pending,
    roots,
    marks: { pinned: new Set(marks.pinned), muted: new Set(marks.muted) },
    projects: yield* projects(rows, chatsRoot),
  } satisfies Inventory
})

/** Walks a session up to its top-level ancestor; missing sessions (e.g. global forms) have no root. */
const rootOf = Effect.fn("Master.rootOf")(function* (
  ctx: InventoryContext,
  sessionID: string,
  known: Map<string, Session.Info>,
) {
  let current = known.get(sessionID)
  if (!current) {
    const decoded = Schema.decodeUnknownOption(Session.ID)(sessionID)
    if (decoded._tag === "None") return undefined
    current = yield* ctx.session.get({ sessionID: decoded.value }).pipe(Effect.orElseSucceed(() => undefined))
  }
  for (let depth = 0; current?.parentID && depth < 32; depth++) {
    const parentID = current.parentID
    current =
      known.get(parentID) ??
      (yield* ctx.session.get({ sessionID: parentID }).pipe(Effect.orElseSucceed(() => undefined)))
    if (current) known.set(current.id, current)
  }
  return current && !current.parentID ? current.id : undefined
})

const projects = Effect.fn("Master.projects")(function* (rows: readonly SessionScan.Info[], chatsRoot?: string) {
  const groups = Map.groupBy(rows, (row) => row.session.projectID)
  const result = new Map<string, ProjectInfo>()
  for (const [id, members] of groups) {
    const directories = [...new Set(members.map((row) => row.session.location.directory))]
    const chats = chatsRoot !== undefined && directories.every((directory) => isWithin(chatsRoot, directory))
    const checkouts = chats
      ? []
      : yield* Effect.promise(() =>
          Promise.all(
            directories.map((directory) =>
              stat(path.join(directory, ".git")).then(
                (info) => (info.isDirectory() ? directory : undefined),
                () => undefined,
              ),
            ),
          ),
        )
    // The main checkout owns a .git directory; otherwise the directory with most sessions, newest first.
    const directory =
      checkouts.find((item) => item !== undefined) ??
      directories.toSorted(
        (a, b) =>
          members.filter((row) => row.session.location.directory === b).length -
          members.filter((row) => row.session.location.directory === a).length,
      )[0]
    if (!directory) continue
    result.set(id, {
      id,
      name: chats ? "Conversas" : path.basename(directory),
      directory,
      directories,
      chats,
    })
  }
  return result
})

function isWithin(root: string, directory: string) {
  return directory === root || directory.startsWith(root.endsWith("/") ? root : root + "/")
}

/** Counts and running work of a root, including its subagent descendants. */
export function family(inventory: Inventory, rootID: string) {
  const owned = (sessionID: string) => sessionID === rootID || inventory.roots.get(sessionID) === rootID
  const questions = inventory.pending
    .flatMap((item) => item.forms)
    .filter((form) => owned(form.sessionID) && isQuestion(form)).length
  const permissions = inventory.pending
    .flatMap((item) => item.permissions)
    .filter((request) => owned(request.sessionID)).length
  const running = Object.keys(inventory.active).filter(owned)
  return {
    questions,
    permissions,
    running: running.includes(rootID),
    subagentsRunning: running.filter((id) => id !== rootID).length,
  }
}

export function summary(inventory: Inventory, row: SessionScan.Info): Summary {
  const counts = family(inventory, row.session.id)
  const flags = attention(row)
  const project = inventory.projects.get(row.session.projectID)
  return {
    id: row.session.id,
    title: (row.session.title ?? "Sem título").slice(0, 200),
    project: project?.chats ? "Conversas" : (project?.name ?? path.basename(row.session.location.directory)),
    directory: row.session.location.directory,
    projectID: row.session.projectID,
    state:
      counts.questions || counts.permissions
        ? "needs-you"
        : counts.running || counts.subagentsRunning
          ? "running"
          : "idle",
    unread: flags.unreadAt !== undefined,
    ...(flags.failed ? { failed: true as const } : {}),
    ...(row.session.outcome ? { outcome: row.session.outcome } : {}),
    lastActivity: activity(row),
    ...(flags.unreadAt !== undefined
      ? { completedAt: flags.unreadAt }
      : row.session.time.idle
        ? { completedAt: DateTime.toEpochMillis(row.session.time.idle) }
        : {}),
    pending: { questions: counts.questions, permissions: counts.permissions },
    ...(counts.subagentsRunning ? { subagentsRunning: counts.subagentsRunning } : {}),
    ...(inventory.marks.pinned.has(row.session.id) ? { pinned: true as const } : {}),
    ...(inventory.marks.muted.has(row.session.id) ? { muted: true as const } : {}),
    ...(row.session.time.archived ? { archived: true as const } : {}),
    ...(row.session.agent ? { agent: row.session.agent } : {}),
    ...(row.session.model ? { model: row.session.model } : {}),
  }
}

/** Case- and accent-insensitive term matching used by every text filter. */
export function normalize(text: string) {
  return text
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLowerCase()
}

export function terms(query: string) {
  return normalize(query).split(/\s+/).filter(Boolean)
}

/** Preference keys are `["<server>", "<sessionID>"]` JSON pairs (or bare IDs in older profiles). */
export function preferenceSessionID(key: string) {
  if (key.startsWith("ses")) return key
  const decoded = Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Tuple([Schema.String, Schema.String])))(key)
  return decoded._tag === "Some" ? decoded.value[1] : undefined
}

/** The server key the iOS and web lists share for pins and mutes. */
export const preferenceServer = "http://localhost:4096"

export function preferenceKey(sessionID: string) {
  return JSON.stringify([preferenceServer, sessionID])
}

export function marksFrom(profile: typeof Preferences.Profile.Type) {
  return {
    pinned: profile.data.pinnedSessions.flatMap((key) => preferenceSessionID(key) ?? []),
    muted: (profile.data.mutedSessions ?? []).flatMap((key) => preferenceSessionID(key) ?? []),
  }
}
