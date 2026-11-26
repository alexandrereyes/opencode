import { stat } from "node:fs/promises"
import path from "node:path"
import type { Plugin } from "@opencode/plugin/effect"
import type { BackgroundJob } from "@opencode/plugin/effect/job"
import type { PendingSnapshot } from "@opencode/plugin/effect/request"
import { Agent } from "@opencode/schema/agent"
import { Form } from "@opencode/schema/form"
import { Model } from "@opencode/schema/model"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import type { SessionScan } from "@opencode/schema/session-scan"
import { Clock, DateTime, Effect, Schema } from "effect"
import { Preferences } from "../preferences/rpc.js"
import { Master } from "../master/rpc.js"
import { detachesAt, type SessionProgress } from "../live-activity/tracker.js"

const agentID = Master.agentID

export type InventoryContext = {
  session: Pick<Plugin.Context["session"], "get" | "scan" | "active" | "family">
  job: Pick<Plugin.Context["job"], "background">
  request: Pick<Plugin.Context["request"], "pending">
  /** Pinned and "Avisar ao terminar" sessions shared by the app lists; absent in tests without preferences. */
  marks?: () => Effect.Effect<{ pinned: readonly string[]; notify: readonly string[] }>
  /** Root of the managed chats, whose sessions have no project of their own. */
  chats?: () => Effect.Effect<string | undefined>
  /** A session's Progresso while it shows (`docs/progress.md`); absent in tests without the Live Activity hub. */
  progress?: (sessionID: string, now: number) => SessionProgress | undefined
}

/** Progresso of a running session: `done` of `total` completed, and the item in hand. */
export const Progress = Schema.Struct({
  done: Schema.Number,
  total: Schema.Number,
  current: Schema.String,
})

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
  backgroundRunning: Schema.optionalKey(Schema.Number),
  progress: Schema.optionalKey(Progress),
  pinned: Schema.optionalKey(Schema.Literal(true)),
  notify: Schema.optionalKey(Schema.Literal(true)),
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
  /** Owner session (root or descendant) of each execution, background shell and pending request → its root. */
  roots: Map<string, Session.ID>
  background: Map<Session.ID, BackgroundJob[]>
  marks: { pinned: Set<string>; notify: Set<string> }
  projects: Map<string, ProjectInfo>
  progress: (sessionID: string) => SessionProgress | undefined
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

export const inventory = Effect.fn("Sessions.inventory")(function* (ctx: InventoryContext) {
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
  const marks = ctx.marks ? yield* ctx.marks() : { pinned: [], notify: [] }
  const chatsRoot = ctx.chats ? yield* ctx.chats() : undefined
  const now = yield* Clock.currentTimeMillis
  return {
    rows,
    active,
    pending,
    roots,
    background: yield* expectedShells(ctx, active, { known, roots }),
    marks: { pinned: new Set(marks.pinned), notify: new Set(marks.notify) },
    projects: yield* projects(rows, chatsRoot),
    progress: (sessionID) => ctx.progress?.(sessionID, now),
  } satisfies Inventory
})

/** Walks a session up to its top-level ancestor; missing sessions (e.g. global forms) have no root. */
const rootOf = Effect.fn("Sessions.rootOf")(function* (
  ctx: Pick<InventoryContext, "session">,
  sessionID: string,
  known: Map<string, Session.Info>,
) {
  let current = known.get(sessionID)
  if (!current) {
    const decoded = Schema.decodeUnknownOption(Session.ID)(sessionID)
    if (decoded._tag === "None") return undefined
    current = yield* ctx.session.get({ sessionID: decoded.value }).pipe(Effect.orElseSucceed(() => undefined))
    if (current) known.set(current.id, current)
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

const expectedShells = Effect.fn("Sessions.expectedShells")(function* (
  ctx: Pick<InventoryContext, "session" | "job">,
  active: Inventory["active"],
  lookup: { known: Map<string, Session.Info>; roots: Map<string, Session.ID>; target?: Session.ID },
) {
  const background = new Map<Session.ID, BackgroundJob[]>()
  const jobs = (yield* ctx.job.background()).filter((job) => job.type !== "subagent")
  const now = yield* Clock.currentTimeMillis
  for (const [sessionID, shells] of Map.groupBy(jobs, (job) => job.sessionID)) {
    const root = lookup.roots.get(sessionID) ?? (yield* rootOf(ctx, sessionID, lookup.known))
    if (!root) continue
    lookup.roots.set(sessionID, root)
    if (lookup.target && root !== lookup.target) continue
    const session =
      lookup.known.get(sessionID) ?? (yield* ctx.session.get({ sessionID }).pipe(Effect.orElseSucceed(() => undefined)))
    if (!session) continue
    const owner = {
      parentID: session.parentID,
      running: Object.hasOwn(active, sessionID),
      archived: Boolean(session.time.archived),
      idleAt: millis(session.time.idle),
    }
    const waited = shells.filter((job) => now < detachesAt(owner, job.started))
    if (waited.length) background.set(root, [...(background.get(root) ?? []), ...waited])
  }
  return background
})

export const waitForFamily = Effect.fn("Sessions.waitForFamily")(function* (
  ctx: Pick<InventoryContext, "session" | "job">,
  sessionID: Session.ID,
) {
  // Ancestry is stable across polls; only owners in the target family need their idle time read again.
  const roots = new Map<string, Session.ID>()
  const poll = (previousIdle: boolean): Effect.Effect<void, unknown> =>
    Effect.gen(function* () {
      const active = yield* ctx.session.active()
      const executing = Object.hasOwn(active, sessionID) || (yield* ctx.session.family({ sessionID })).active.length > 0
      const idle =
        !executing &&
        !(yield* expectedShells(ctx, active, { known: new Map(), roots, target: sessionID })).has(sessionID)
      // A settled shell leaves the job list before its owner wakes; the parent's report has a similar gap.
      if (idle && previousIdle) return
      yield* Effect.sleep("500 millis")
      return yield* poll(idle)
    })
  yield* poll(false)
})

const projects = Effect.fn("Sessions.projects")(function* (rows: readonly SessionScan.Info[], chatsRoot?: string) {
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
export function family(inventory: Inventory, rootID: Session.ID) {
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
    backgroundRunning: inventory.background.get(rootID)?.length ?? 0,
  }
}

export function summary(inventory: Inventory, row: SessionScan.Info): Summary {
  const counts = family(inventory, row.session.id)
  const flags = attention(row)
  const project = inventory.projects.get(row.session.projectID)
  const progress = inventory.progress(row.session.id)
  return {
    id: row.session.id,
    title: (row.session.title ?? "Sem título").slice(0, 200),
    project: project?.chats ? "Conversas" : (project?.name ?? path.basename(row.session.location.directory)),
    directory: row.session.location.directory,
    projectID: row.session.projectID,
    state:
      counts.questions || counts.permissions
        ? "needs-you"
        : counts.running || counts.subagentsRunning || counts.backgroundRunning
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
    ...(counts.backgroundRunning ? { backgroundRunning: counts.backgroundRunning } : {}),
    ...(progress ? { progress: { done: progress.done, total: progress.total, current: progress.current } } : {}),
    ...(inventory.marks.pinned.has(row.session.id) ? { pinned: true as const } : {}),
    ...(inventory.marks.notify.has(row.session.id) ? { notify: true as const } : {}),
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

/** The server key the iOS and web lists share for pins and "Avisar ao terminar". */
export const preferenceServer = "http://localhost:4096"

export function preferenceKey(sessionID: string) {
  return JSON.stringify([preferenceServer, sessionID])
}

export function marksFrom(profile: typeof Preferences.Profile.Type) {
  return {
    pinned: profile.data.pinnedSessions.flatMap((key) => preferenceSessionID(key) ?? []),
    notify: (profile.data.notifySessions ?? []).flatMap((key) => preferenceSessionID(key) ?? []),
  }
}
