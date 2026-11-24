import { Plugin } from "@opencode/plugin/effect"
import type { Context } from "../context.js"
import type { Requests } from "../request-times.js"
import { Clock, DateTime, Effect, Schema } from "effect"
import { Navigation } from "./rpc.js"
import { Session } from "@opencode/schema/session"
import { sharedHub } from "../live-activity/index.js"
import { limits, type SessionProgress } from "../live-activity/tracker.js"
import { sharedRegistry, wire } from "../browser-handoff/registry.js"
import type { BrowserHandoffs } from "../browser-handoff/rpc.js"

const encodeSession = Schema.encodeSync(Session.Info)

interface NavigationContext {
  readonly scan: Plugin.Context["session"]["scan"]
  readonly pending: Requests["pending"]
  readonly background: Plugin.Context["job"]["background"]
  /** Executing sessions at any depth: an executing subagent's shells are always its family's work. */
  readonly active: Plugin.Context["session"]["active"]
  /** A session's Progresso while it shows; the Live Activity hub folds the same events for every Location. */
  readonly progress?: (sessionID: string, now: number) => SessionProgress | undefined
  /** Browse handoffs waiting now, any Location (`docs/browser-handoff.md`). */
  readonly handoffs?: () => readonly BrowserHandoffs.Handoff[]
}

export const registerNavigation = Effect.fn("Navigation.register")(function* (ctx: Context) {
  const sessions = ctx.session
  const requests = ctx.request
  const jobs = ctx.job
  yield* ctx.rpc
    .register(Navigation.Definition, {
      list: (input) =>
        list(
          {
            scan: sessions.scan,
            pending: requests.pending,
            background: jobs.background,
            active: sessions.active,
            progress: (sessionID, now) => sharedHub().progress(sessionID, now),
            handoffs: () => sharedRegistry().waiting().map(wire),
          },
          input,
        ),
    })
    .pipe(Effect.orDie)
})

export const list = Effect.fn("Navigation.list")(function* (
  ctx: NavigationContext,
  input: { readonly after?: Session.ID; readonly limit?: number; readonly sessionID?: Session.ID },
) {
  const page = yield* ctx.scan({ ...input, archived: false })
  const pending = yield* ctx.pending()
  const permissions = Map.groupBy(
    pending.flatMap((snapshot) => snapshot.permissions),
    (request) => request.sessionID,
  )
  const questions = Map.groupBy(
    pending
      .flatMap((snapshot) => snapshot.forms)
      .filter((form) => form.metadata?.kind === "question" || form.metadata?.kind === "websearch.provider"),
    (form) => form.sessionID,
  )
  const handoffs = Map.groupBy(ctx.handoffs?.() ?? [], (handoff) => handoff.sessionID)
  // A running subagent keeps its own child Session active; other background work (shells) has no Session state.
  const background = Map.groupBy(
    (yield* ctx.background()).filter((job) => job.type !== "subagent").toSorted((a, b) => b.started - a.started),
    (job) => job.sessionID,
  )
  // Unreadable, nothing executes: a subagent's shells then count only until they detach.
  const active = background.size > 0 ? yield* ctx.active().pipe(Effect.orElseSucceed(() => ({}))) : {}
  const now = yield* Clock.currentTimeMillis
  return {
    ...(page.next === undefined ? {} : { next: page.next }),
    data: page.data.map((row) => {
      const viewed = row.session.time.viewed ? DateTime.toEpochMillis(row.session.time.viewed) : 0
      const idle = row.session.time.idle ? DateTime.toEpochMillis(row.session.time.idle) : undefined
      const unreadAt =
        !row.session.parentID && idle !== undefined && idle > viewed
          ? row.completionAt !== undefined && row.completionAt > viewed
            ? row.completionAt
            : row.session.outcome === "succeeded" || row.session.outcome === "failed"
              ? idle
              : undefined
          : undefined
      const sessionPermissions = permissions.get(row.session.id) ?? []
      const sessionQuestions = questions.get(row.session.id) ?? []
      const sessionBackground = background.get(row.session.id) ?? []
      const newestHandoff = (handoffs.get(row.session.id) ?? []).toSorted((a, b) => b.since - a.since)[0]
      const newest = sessionBackground[0]
      // A shell's end wakes its owner, whose report then wakes its parent: work while the owner is top-level,
      // executes or ran in the last hour. Past that (a dev server it left on) it is listed, not counted as work. The
      // Live Activity hub's `detachesAt` applies the same rule.
      const waited =
        !row.session.parentID ||
        Object.hasOwn(active, row.session.id) ||
        (newest !== undefined && now < Math.max(idle ?? 0, newest.started) + limits.detachMs)
      const progress = ctx.progress?.(row.session.id, now)
      return {
        session: encodeSession(row.session),
        ...(row.messageAt === undefined ? {} : { messageAt: row.messageAt }),
        ...(unreadAt === undefined ? {} : { unreadAt }),
        ...(sessionPermissions.length
          ? {
              permissionAt: Math.max(...sessionPermissions.map((request) => request.created ?? 0)),
              permissionCount: sessionPermissions.length,
            }
          : {}),
        ...(sessionQuestions.length
          ? {
              questionAt: Math.max(...sessionQuestions.map((form) => form.created ?? 0)),
              questionCount: sessionQuestions.length,
            }
          : {}),
        ...(newestHandoff
          ? {
              browserAt: newestHandoff.since,
              browserCount: handoffs.get(row.session.id)?.length ?? 1,
              browserText: newestHandoff.message,
              ...(newestHandoff.resourceID ? { browserResourceID: newestHandoff.resourceID } : {}),
            }
          : {}),
        ...(newest && waited
          ? {
              backgroundCount: sessionBackground.length,
              ...(newest.title ? { backgroundTitle: newest.title } : {}),
            }
          : {}),
        ...(newest && !waited
          ? {
              detachedCount: sessionBackground.length,
              ...(newest.title ? { detachedTitle: newest.title } : {}),
            }
          : {}),
        ...(progress ? { progress } : {}),
      }
    }),
  }
})
