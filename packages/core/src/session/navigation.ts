export * as SessionNavigation from "./navigation.js"

import { and, asc, eq, gt, isNull, sql } from "drizzle-orm"
import { Context, Effect, Option, RcMap } from "effect"
import { Session } from "@opencode/schema/session"
import { SessionNavigation } from "@opencode/schema/session-navigation"
import { Event } from "@opencode/schema/event"
import { SessionEvent } from "@opencode/schema/session-event"
import { Database } from "../database/database.js"
import { EventTable } from "../event/sql.js"
import { Permission } from "../permission.js"
import { Form } from "../form.js"
import { LocationServiceMap } from "../location-service-map.js"
import { SessionMessageTable, SessionTable } from "./sql.js"
import { fromRow } from "./info.js"

/** ID pagination stays stable when a session is renamed or receives new messages. */
export const list = Effect.fn("SessionNavigation.list")(function* (
  input: { after?: Session.ID; limit?: number; sessionID?: Session.ID } = {},
) {
  const database = yield* Database.Service
  const limit = Math.min(input.limit ?? 200, 1000)
  const rows = yield* database.db
    .select({
      session: SessionTable,
      // The type/sequence index finds the latest actual user/assistant message without decoding its body.
      messageAt: sql<number | null>`(
        select max(${SessionMessageTable.time_created}) from ${SessionMessageTable}
        where ${SessionMessageTable.session_id} = ${SessionTable.id}
        and ${SessionMessageTable.type} in ('user', 'assistant')
      )`,
      unreadAt: sql<number | null>`case when ${SessionTable.time_idle} > coalesce(${SessionTable.time_viewed}, 0)
        then coalesce((select min(${EventTable.created}) from ${EventTable}
          where ${EventTable.aggregate_id} = ${SessionTable.id}
          and ${EventTable.type} in (
            ${Event.versionedType(SessionEvent.Execution.Succeeded.type, 1)},
            ${Event.versionedType(SessionEvent.Execution.Failed.type, 1)}
          ) and ${EventTable.created} > coalesce(${SessionTable.time_viewed}, 0)
        ), case when ${SessionTable.idle_outcome} in ('succeeded', 'failed') then ${SessionTable.time_idle} end)
        end`,
    })
    .from(SessionTable)
    .where(
      and(
        isNull(SessionTable.time_archived),
        input.after ? gt(SessionTable.id, input.after) : undefined,
        input.sessionID ? eq(SessionTable.id, input.sessionID) : undefined,
      ),
    )
    .orderBy(asc(SessionTable.id))
    .limit(limit + 1)
    .all()
    .pipe(Effect.orDie)
  const data = rows.slice(0, limit).map(
    (row): SessionNavigation.Info => ({
      session: fromRow(row.session),
      messageAt: row.messageAt ?? undefined,
      unreadAt: row.unreadAt ?? undefined,
    }),
  )
  return { data, next: rows.length > limit ? data.at(-1)?.session.id : undefined }
})

/** Only inspect already-live locations: listing history must never boot a project's plugins. */
export const pending = Effect.fn("SessionNavigation.pending")(function* () {
  const locations = yield* LocationServiceMap.Service
  const refs = yield* RcMap.keys(locations.rcMap)
  return yield* Effect.forEach(refs, (ref) =>
    Effect.scoped(
      Effect.gen(function* () {
        const context = yield* locations.contextEffectOption(ref)
        if (Option.isNone(context)) return []
        const permissions = Context.get(context.value, Permission.Service)
        const forms = Context.get(context.value, Form.Service)
        return [
          ...(yield* permissions.list()).map((request) => ({
            sessionID: request.sessionID,
            type: "permission" as const,
            time: request.created ?? 0,
          })),
          ...(yield* forms.list())
            .filter((form) => form.metadata?.kind === "question" || form.metadata?.kind === "websearch.provider")
            .map((form) => ({ sessionID: form.sessionID, type: "question" as const, time: form.created ?? 0 })),
        ]
      }),
    ).pipe(Effect.orDie),
  ).pipe(Effect.map((rows) => rows.flat()))
})

export const page = Effect.fn("SessionNavigation.page")(function* (
  input: { after?: Session.ID; limit?: number; sessionID?: Session.ID } = {},
) {
  const result = yield* list(input)
  const requests = Map.groupBy(yield* pending(), (request) => request.sessionID)
  return {
    ...result,
    data: result.data.map((row) => {
      const items = requests.get(row.session.id) ?? []
      const permissions = items.filter((item) => item.type === "permission")
      const questions = items.filter((item) => item.type === "question")
      return {
        ...row,
        permissionAt: permissions.length ? Math.min(...permissions.map((item) => item.time)) : undefined,
        questionAt: questions.length ? Math.min(...questions.map((item) => item.time)) : undefined,
      }
    }),
  }
})
