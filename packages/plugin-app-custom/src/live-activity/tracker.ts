import type { Plugin } from "@opencode/plugin/effect"
import { Session } from "@opencode/schema/session"
import { DateTime, Effect } from "effect"
import path from "node:path"
import type { LiveActivity } from "./rpc.js"

export const limits = {
  /** A session that finished successfully counts as idle for this long. */
  idleMs: 30 * 60_000,
  /** A failure is forgotten after this long even when nobody viewed the session. */
  failedMs: 24 * 3_600_000,
  title: 80,
  project: 40,
  host: 40,
  activity: 60,
  text: 120,
  rows: 4,
  attention: 3,
}

/** The live events the tracker folds; a structural subset of the server events a plugin receives. */
export type Event =
  | {
      readonly type: "session.created"
      readonly created: number
      readonly data: {
        readonly sessionID: string
        readonly parentID?: string
        readonly title?: string
        readonly location: { readonly directory: string }
        readonly subpath?: string
      }
    }
  | {
      readonly type: "session.renamed"
      readonly created: number
      readonly data: { readonly sessionID: string; readonly title: string }
    }
  | {
      readonly type: "session.moved"
      readonly created: number
      readonly data: {
        readonly sessionID: string
        readonly location: { readonly directory: string }
        readonly subpath?: string
      }
    }
  | {
      readonly type:
        | "session.archived"
        | "session.deleted"
        | "session.execution.started"
        | "session.execution.succeeded"
        | "session.execution.failed"
        | "session.reasoning.started"
        | "session.text.started"
      readonly created: number
      readonly data: { readonly sessionID: string }
    }
  | {
      readonly type: "session.execution.interrupted"
      readonly created: number
      readonly data: { readonly sessionID: string; readonly reason: string }
    }
  | {
      readonly type: "session.viewed"
      readonly created: number
      readonly data: { readonly sessionID: string; readonly idle: number }
    }
  | {
      readonly type: "session.tool.input.started"
      readonly created: number
      readonly data: { readonly sessionID: string; readonly id: string; readonly name: string }
    }
  | {
      readonly type: "session.tool.called"
      readonly created: number
      readonly data: {
        readonly sessionID: string
        readonly id: string
        readonly input: Readonly<Record<string, unknown>>
      }
    }
  | {
      readonly type: "permission.asked" | "form.created"
      /** Read from `ctx.request.pending()` instead, which also covers requests that end without an event. */
      readonly data: unknown
    }
  /** Published before the request leaves `ctx.request.pending()`, so the settled ID is excluded from that read. */
  | { readonly type: "form.replied" | "form.cancelled"; readonly data: { readonly id: string } }
  | { readonly type: "permission.replied"; readonly data: { readonly requestID: string } }

export const eventTypes: ReadonlySet<string> = new Set<Event["type"]>([
  "session.created",
  "session.renamed",
  "session.moved",
  "session.archived",
  "session.deleted",
  "session.viewed",
  "session.execution.started",
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
  "session.tool.input.started",
  "session.tool.called",
  "session.reasoning.started",
  "session.text.started",
  "permission.asked",
  "permission.replied",
  "form.created",
  "form.replied",
  "form.cancelled",
])

export type TrackerContext = {
  session: Pick<Plugin.Context["session"], "get" | "scan" | "active" | "family">
  message: Pick<Plugin.Context["message"], "list">
  request: Pick<Plugin.Context["request"], "pending">
}

type Entry = {
  readonly id: string
  readonly parentID?: string
  title?: string
  directory: string
  subpath?: string
  readonly created: number
  /** Last idle transition known from storage (rebuild and hydration only). */
  readonly idleAt?: number
  archived: boolean
  running: boolean
  /** Start of the session's own current (or most recent) execution, when known. */
  startedAt?: number
  /** Latest observed activity, which orders working rows and picks the family's activity text. */
  activityAt: number
  ended?: { readonly outcome: "succeeded" | "failed" | "interrupted"; readonly at: number; cleared: boolean }
  activity?: string
  /** Tool call ID → tool name of the current execution, to describe `session.tool.called`. */
  readonly tools: Map<string, string>
}

type Request = {
  readonly id: string
  readonly kind: LiveActivity.AttentionKind
  readonly sessionID: string
  readonly since: number
  readonly text?: string
}

/** Push alert of one attention item or failed session; keyed by `<status>:<sessionID>`. */
export type Mark = { readonly title: string; readonly body: string }

export type Derived = {
  readonly state: LiveActivity.AgentsState
  /** Every attention item and failed session, untruncated, in alert priority order. */
  readonly marks: ReadonlyMap<string, Mark>
  /** When the state changes by itself next (an idle or failed row expiring). */
  readonly wakeAt?: number
}

/**
 * Folds server events into per-session status. Holds every top-level session that is running, waiting, failed or
 * recently idle, plus their subagent descendants at any depth, across all Locations. Descendants never become rows:
 * their running state and requests roll up into their top-level session.
 */
export function makeTracker(ctx: TrackerContext) {
  const sessions = new Map<string, Entry>()
  const firstSeen = new Map<string, number>()
  const state = { requests: [] as Request[], focus: undefined as string | undefined }

  const hydrate = Effect.fn("LiveActivity.hydrate")(function* (sessionID: string) {
    const info = yield* ctx.session
      .get({ sessionID: Session.ID.make(sessionID) })
      .pipe(Effect.orElseSucceed(() => undefined))
    if (!info) return undefined
    const next = fromInfo(info, false)
    sessions.set(info.id, next)
    return next
  })

  /** The session and its ancestors up to the top level, reading the unknown ones (the child → parent cache). */
  const lineage = (sessionID: string, depth = 0): Effect.Effect<Entry | undefined> =>
    Effect.gen(function* () {
      if (sessionID === "global") return undefined
      const entry = sessions.get(sessionID) ?? (yield* hydrate(sessionID))
      if (entry?.parentID && depth < 32) yield* lineage(entry.parentID, depth + 1)
      return entry
    })

  const refreshPending = Effect.fn("LiveActivity.refreshPending")(function* (now: number, settled?: string) {
    const snapshots = yield* ctx.request.pending()
    const found = snapshots
      .flatMap((snapshot) => [
        ...snapshot.forms
          .filter((form) => form.metadata?.kind === "question" || form.metadata?.kind === "websearch.provider")
          .map((form) => ({
            id: form.id,
            kind: "question" as const,
            sessionID: form.sessionID,
            created: form.created,
            text:
              form.metadata?.kind === "question"
                ? (form.fields[0]?.description ?? form.fields[0]?.title ?? form.title)
                : form.title,
          })),
        ...snapshot.permissions.map((request) => ({
          id: request.id,
          kind: "permission" as const,
          sessionID: request.sessionID,
          created: request.created,
          text: [request.action, request.resources.join(" ")].filter(Boolean).join(" · "),
        })),
      ])
      .filter((item) => item.id !== settled)
    const ids = new Set<string>(found.map((item) => item.id))
    for (const id of firstSeen.keys()) if (!ids.has(id)) firstSeen.delete(id)
    for (const item of found) if (!firstSeen.has(item.id)) firstSeen.set(item.id, item.created ?? now)
    state.requests = found.map((item) => ({
      id: item.id,
      kind: item.kind,
      sessionID: item.sessionID,
      since: firstSeen.get(item.id) ?? now,
      ...(item.text ? { text: item.text } : {}),
    }))
    // Owners may be subagent descendants or sessions this process has not seen yet; walk them up to their root.
    for (const owner of new Set(state.requests.map((request) => request.sessionID))) yield* lineage(owner)
  })

  /** Reconstructs running, waiting, failed and recently idle sessions, e.g. after a restart. */
  const rebuild = Effect.fn("LiveActivity.rebuild")(function* (now: number) {
    const active = yield* ctx.session.active()
    const scan = (after?: Session.ID): Effect.Effect<readonly Session.Info[]> =>
      ctx.session.scan({ parentID: null, archived: false, limit: 500, after }).pipe(
        Effect.flatMap((page) => {
          const rows = page.data.map((row) => row.session)
          return page.next && page.next !== after
            ? scan(page.next).pipe(Effect.map((rest) => [...rows, ...rest]))
            : Effect.succeed(rows)
        }),
      )
    for (const info of yield* scan()) {
      const idle = idleAt(info)
      if (Object.hasOwn(active, info.id) || (idle !== undefined && now - idle < limits.failedMs))
        sessions.set(info.id, fromInfo(info, false))
    }
    // The running set includes subagents at any depth; each one and its ancestors join the model.
    for (const id of Object.keys(active)) {
      const entry = yield* lineage(id)
      if (!entry) continue
      entry.running = true
      entry.ended = undefined
      entry.startedAt = yield* executionStart(entry)
    }
    const roots = new Set(
      [...sessions.values()].filter((entry) => entry.running).flatMap((entry) => rootOf(entry.id) ?? []),
    )
    for (const root of roots) {
      // A top-level session waiting for background subagents: its most recent turn started at its latest prompt.
      if (!root.running && root.startedAt === undefined) root.startedAt = yield* latestPrompt(root.id)
      const family = yield* ctx.session
        .family({ sessionID: Session.ID.make(root.id), limit: 100 })
        .pipe(Effect.orElseSucceed(() => undefined))
      for (const child of family?.data ?? [])
        if (child.parentID === root.id && !sessions.has(child.id)) sessions.set(child.id, fromInfo(child, false))
    }
    yield* refreshPending(now)
  })

  const latestPrompt = (sessionID: string) =>
    ctx.message.list({ sessionID: Session.ID.make(sessionID), limit: 1, type: "user" }).pipe(
      Effect.map((page) => page.data[0]),
      Effect.orElseSucceed(() => undefined),
      Effect.map((message) => (message ? DateTime.toEpochMillis(message.time.created) : undefined)),
    )

  /** Approximates the start of a running execution found by a rebuild: its latest prompt, after its last idle. */
  const executionStart = (entry: Entry) =>
    latestPrompt(entry.id).pipe(Effect.map((prompt) => Math.max(prompt ?? 0, entry.idleAt ?? entry.created)))

  const rootOf = (id: string) => {
    const visit = (current: Entry | undefined, depth: number): Entry | undefined =>
      current?.parentID && depth < 32 ? visit(sessions.get(current.parentID), depth + 1) : current
    const top = visit(sessions.get(id), 0)
    return top && !top.parentID ? top : undefined
  }

  const apply = Effect.fn("LiveActivity.apply")(function* (event: Event, now: number) {
    switch (event.type) {
      case "permission.asked":
      case "form.created":
        return yield* refreshPending(now)
      case "form.replied":
      case "form.cancelled":
        return yield* refreshPending(now, event.data.id)
      case "permission.replied":
        return yield* refreshPending(now, event.data.requestID)
    }
    const id = event.data.sessionID
    const entry = sessions.get(id)
    const touch = (target: Entry | undefined) => {
      if (target) target.activityAt = Math.max(target.activityAt, event.created)
      return target
    }
    switch (event.type) {
      case "session.created": {
        sessions.set(id, {
          id,
          ...(event.data.parentID ? { parentID: event.data.parentID } : {}),
          ...(event.data.title ? { title: event.data.title } : {}),
          directory: event.data.location.directory,
          ...(event.data.subpath ? { subpath: event.data.subpath } : {}),
          created: event.created,
          archived: false,
          running: false,
          activityAt: event.created,
          tools: new Map(),
        })
        if (event.data.parentID) touch(sessions.get(event.data.parentID))
        return
      }
      case "session.renamed":
        if (entry) entry.title = event.data.title
        return
      case "session.moved":
        if (!entry) return
        entry.directory = event.data.location.directory
        entry.subpath = event.data.subpath
        return
      case "session.archived":
        if (entry) entry.archived = true
        return
      case "session.deleted":
        sessions.delete(id)
        return
      case "session.viewed":
        if (entry?.ended?.outcome === "failed" && event.data.idle >= entry.ended.at) entry.ended.cleared = true
        return
      case "session.execution.started": {
        const target = yield* lineage(id)
        if (target) {
          target.running = true
          target.startedAt = event.created
          target.activityAt = event.created
          target.ended = undefined
          target.activity = undefined
          target.tools.clear()
        }
        return yield* refreshPending(now)
      }
      case "session.execution.succeeded":
      case "session.execution.failed":
      case "session.execution.interrupted": {
        const target = yield* lineage(id)
        if (target) {
          target.running = false
          target.activityAt = event.created
          target.ended = {
            outcome:
              event.type === "session.execution.succeeded"
                ? "succeeded"
                : event.type === "session.execution.failed"
                  ? "failed"
                  : "interrupted",
            at: event.created,
            cleared: false,
          }
        }
        return yield* refreshPending(now)
      }
      case "session.tool.input.started":
        touch(entry)?.tools.set(event.data.id, event.data.name)
        return
      case "session.tool.called": {
        const target = touch(entry)
        const name = target?.tools.get(event.data.id)
        if (target) target.activity = name ? describe(name, event.data.input) : undefined
        return
      }
      case "session.reasoning.started": {
        const target = touch(entry)
        if (target) target.activity = "Pensando"
        return
      }
      case "session.text.started": {
        const target = touch(entry)
        if (target) target.activity = "Escrevendo resposta"
        return
      }
    }
  })

  /** Computes the contract state; also moves the focus, which must stay put while it keeps working. */
  const derive = (now: number, host: string): Derived => {
    const owned = new Map<string, Request[]>()
    for (const request of state.requests) {
      const top = rootOf(request.sessionID)
      if (!top || top.archived) continue
      owned.set(top.id, [...(owned.get(top.id) ?? []), request])
    }
    // Executing members of each family: the top-level session itself and its descendants at any depth.
    const executing = new Map<string, Entry[]>()
    for (const entry of sessions.values()) {
      if (!entry.running || entry.archived) continue
      const top = rootOf(entry.id)
      if (top) executing.set(top.id, [...(executing.get(top.id) ?? []), entry])
    }
    const family = (entry: Entry) => {
      const members = executing.get(entry.id) ?? []
      const latest = members.toSorted((a, b) => b.activityAt - a.activityAt || a.id.localeCompare(b.id))[0]
      const starts = members.map((member) => member.startedAt ?? member.created)
      return {
        running: members.length > 0,
        startedAt: entry.startedAt ?? (starts.length > 0 ? Math.min(...starts) : entry.created),
        // Subagents created since then belong to the most recent turn.
        since:
          entry.startedAt ??
          (members.length > 0 ? Math.min(...members.map((member) => member.created)) : entry.created),
        activityAt: Math.max(entry.activityAt, ...members.map((member) => member.activityAt)),
        activity: latest?.activity,
      }
    }
    const failed = (entry: Entry) =>
      entry.ended?.outcome === "failed" && !entry.ended.cleared && now - entry.ended.at < limits.failedMs
    const idle = (entry: Entry) => entry.ended?.outcome === "succeeded" && now - entry.ended.at < limits.idleMs
    const rows = [...sessions.values()]
      .filter((entry) => !entry.parentID && !entry.archived)
      .flatMap((entry) => {
        const requests = owned.get(entry.id) ?? []
        const kind = requests.some((request) => request.kind === "question")
          ? ("question" as const)
          : requests.length > 0
            ? ("permission" as const)
            : undefined
        const oldest = requests
          .filter((request) => request.kind === kind)
          .toSorted((a, b) => a.since - b.since || a.id.localeCompare(b.id))[0]
        const rollup = family(entry)
        const status: LiveActivity.RowStatus | undefined =
          kind ?? (failed(entry) ? "failed" : rollup.running ? "working" : idle(entry) ? "idle" : undefined)
        if (!status) return []
        return [{ entry, status, oldest, ref: ref(entry), rollup }]
      })
    const of = (status: LiveActivity.RowStatus) => rows.filter((row) => row.status === status)
    const working = of("working")
    const kept = working.find((row) => row.entry.id === state.focus)
    const focused =
      kept ??
      working.toSorted((a, b) => b.rollup.startedAt - a.rollup.startedAt || a.entry.id.localeCompare(b.entry.id))[0]
    state.focus = focused?.entry.id
    const progress = (row: (typeof rows)[number]): LiveActivity.Progress | undefined => {
      const children = [...sessions.values()].filter(
        (child) => child.parentID === row.entry.id && child.created >= row.rollup.since,
      )
      if (children.length === 0) return undefined
      const done = children.filter(
        (child) => !child.running && child.ended !== undefined && child.ended.at >= child.created,
      ).length
      return { done, total: children.length, unit: "subagents" }
    }
    const bySince = (a: (typeof rows)[number], b: (typeof rows)[number]) =>
      (a.oldest?.since ?? 0) - (b.oldest?.since ?? 0) || a.entry.id.localeCompare(b.entry.id)
    const byEnded = (a: (typeof rows)[number], b: (typeof rows)[number]) =>
      (b.entry.ended?.at ?? 0) - (a.entry.ended?.at ?? 0) || a.entry.id.localeCompare(b.entry.id)
    const ordered = [
      ...of("question").toSorted(bySince),
      ...of("permission").toSorted(bySince),
      ...of("failed").toSorted(byEnded),
      ...(focused ? [focused] : []),
      ...working
        .filter((row) => row !== focused)
        .toSorted((a, b) => b.rollup.activityAt - a.rollup.activityAt || a.entry.id.localeCompare(b.entry.id)),
      ...of("idle").toSorted(byEnded),
    ]
    const counts = {
      working: working.length,
      question: of("question").length,
      permission: of("permission").length,
      failed: of("failed").length,
      idle: of("idle").length,
    }
    const waiting = rows.filter((row) => row.status === "question" || row.status === "permission").toSorted(bySince)
    const focusProgress = focused ? progress(focused) : undefined
    const marks = new Map(
      [...of("question"), ...of("permission"), ...of("failed")].map((row) => [
        `${row.status}:${row.entry.id}`,
        {
          title:
            row.status === "question"
              ? "Pergunta pendente"
              : row.status === "permission"
                ? "Permissão pendente"
                : "Sessão parou com erro",
          body: `${row.ref.title} · ${row.ref.project}`,
        },
      ]),
    )
    const expiries = rows.flatMap((row) =>
      row.status === "idle" && row.entry.ended
        ? [row.entry.ended.at + limits.idleMs]
        : row.status === "failed" && row.entry.ended
          ? [row.entry.ended.at + limits.failedMs]
          : [],
    )
    return {
      state: {
        v: 1,
        updatedAt: now,
        host: clip(host, limits.host),
        counts,
        activeTotal: counts.working + counts.question + counts.permission,
        ...(focused
          ? {
              focus: {
                ...focused.ref,
                startedAt: focused.rollup.startedAt,
                ...(focused.rollup.activity ? { activity: clip(focused.rollup.activity, limits.activity) } : {}),
                ...(focusProgress ? { progress: focusProgress } : {}),
              },
            }
          : {}),
        attention: waiting.slice(0, limits.attention).map((row) => ({
          ...row.ref,
          kind: row.status === "question" ? ("question" as const) : ("permission" as const),
          since: row.oldest?.since ?? now,
          ...(row.oldest?.text ? { text: clip(row.oldest.text, limits.text) } : {}),
        })),
        attentionTotal: counts.question + counts.permission,
        sessions: ordered.slice(0, limits.rows).map((row) => {
          const rowProgress = row.status === "working" ? progress(row) : undefined
          return { ...row.ref, status: row.status, ...(rowProgress ? { progress: rowProgress } : {}) }
        }),
      },
      marks,
      ...(expiries.length > 0 ? { wakeAt: Math.min(...expiries) } : {}),
    }
  }

  /** Forgets sessions that can no longer affect the state. */
  const prune = (now: number) => {
    const owners = new Set(state.requests.map((request) => request.sessionID))
    const live = new Set(
      [...sessions.values()].filter((entry) => entry.running).flatMap((entry) => rootOf(entry.id)?.id ?? []),
    )
    for (const entry of sessions.values()) {
      if (entry.running || owners.has(entry.id)) continue
      // Members of a family that still runs keep the parent links and the progress of their top-level session.
      if (live.has(rootOf(entry.id)?.id ?? entry.id)) continue
      if (now - Math.max(entry.activityAt, entry.ended?.at ?? 0) < limits.failedMs) continue
      sessions.delete(entry.id)
    }
  }

  return { rebuild, apply, refreshPending, derive, prune, sessions }
}

export type Tracker = ReturnType<typeof makeTracker>

/** pt-BR description of a tool call, per the contract's activity mapping. */
export function describe(name: string, input: Readonly<Record<string, unknown>>) {
  const text = (key: string) => {
    const value = input[key]
    return typeof value === "string" && value.trim() ? value : undefined
  }
  const file = (value: string | undefined) => (value ? path.basename(value.trim()) : undefined)
  switch (name) {
    case "edit":
    case "write": {
      const target = file(text("path"))
      return target ? `Editando ${target}` : undefined
    }
    case "patch": {
      const target = file(text("patchText")?.match(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/m)?.[1])
      return target ? `Editando ${target}` : undefined
    }
    case "read": {
      const target = file(text("path"))
      return target ? `Lendo ${target}` : undefined
    }
    case "shell": {
      const command = text("command")
      return command ? `Rodando ${Array.from(collapse(command)).slice(0, 40).join("").trimEnd()}` : undefined
    }
    case "grep":
    case "glob": {
      const pattern = text("pattern")
      return pattern ? `Buscando ${collapse(pattern)}` : undefined
    }
    case "webfetch":
    case "websearch":
      return "Pesquisando na web"
    case "subagent": {
      const agent = text("agent")
      return agent ? `Delegando para ${collapse(agent)}` : undefined
    }
    default:
      return undefined
  }
}

/** Single-line text of at most `max` characters, ending in an ellipsis when cut. */
export function clip(text: string, max: number) {
  const chars = Array.from(collapse(text))
  return chars.length <= max ? chars.join("") : `${chars.slice(0, max - 1).join("")}…`
}

function collapse(text: string) {
  return text.replace(/\s+/g, " ").trim()
}

function ref(entry: Entry) {
  return {
    sessionID: entry.id,
    title: clip(entry.title?.trim() ? entry.title : "Sem título", limits.title),
    project: clip(
      path.basename(entry.subpath ? path.join(entry.directory, entry.subpath) : entry.directory),
      limits.project,
    ),
    directory: entry.directory,
  }
}

function idleAt(info: Session.Info) {
  return info.time.idle ? DateTime.toEpochMillis(info.time.idle) : undefined
}

function fromInfo(info: Session.Info, running: boolean): Entry {
  const idle = idleAt(info)
  const viewed = info.time.viewed ? DateTime.toEpochMillis(info.time.viewed) : undefined
  return {
    id: info.id,
    ...(info.parentID ? { parentID: info.parentID } : {}),
    ...(info.title ? { title: info.title } : {}),
    directory: info.location.directory,
    ...(info.subpath ? { subpath: info.subpath } : {}),
    created: DateTime.toEpochMillis(info.time.created),
    ...(idle === undefined ? {} : { idleAt: idle }),
    archived: info.time.archived !== undefined,
    running,
    activityAt: Math.max(DateTime.toEpochMillis(info.time.updated), idle ?? 0),
    ...(!running && info.outcome && idle !== undefined
      ? {
          ended: {
            outcome: info.outcome,
            at: idle,
            cleared: info.outcome === "failed" && viewed !== undefined && viewed >= idle,
          },
        }
      : {}),
    tools: new Map(),
  }
}
