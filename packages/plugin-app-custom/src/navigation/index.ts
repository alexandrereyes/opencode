import { Plugin } from "@opencode/plugin/effect"
import type { Context } from "../context.js"
import type { Requests } from "../request-times.js"
import { DateTime, Effect, Schema } from "effect"
import { Navigation } from "./rpc.js"
import { Session } from "@opencode/schema/session"
import { sharedHub } from "../live-activity/index.js"
import type { SessionProgress } from "../live-activity/tracker.js"
import { sharedRegistry, wire } from "../browser-handoff/registry.js"
import type { BrowserHandoffs } from "../browser-handoff/rpc.js"

const encodeSession = Schema.encodeSync(Session.Info)

interface NavigationContext {
  readonly scan: Plugin.Context["session"]["scan"]
  readonly pending: Requests["pending"]
  readonly background: Plugin.Context["job"]["background"]
  /** Executing sessions at any depth: a subagent's shells count as its family's work only while it executes. */
  readonly active: Plugin.Context["session"]["active"]
  /** A session's Progresso while it shows; the Live Activity hub folds the same events for every Location. */
  readonly progress?: (sessionID: string) => SessionProgress | undefined
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
            progress: (sessionID) => sharedHub().progress(sessionID),
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
  // Unreadable, nothing executes: a subagent's shells are listed apart rather than kept working forever.
  const active = background.size > 0 ? yield* ctx.active().pipe(Effect.orElseSucceed(() => ({}))) : {}
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
      // A shell's end wakes only its owner. A subagent whose turn ended already delivered its result, so nobody
      // waits on the shells it left running (an emulator, a dev server): they are listed, not counted as work.
      const waited = !row.session.parentID || Object.hasOwn(active, row.session.id)
      const progress = ctx.progress?.(row.session.id)
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
