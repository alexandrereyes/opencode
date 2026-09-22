export * as SessionFamily from "./family.js"

import { and, asc, getTableColumns, getTableName, gt, inArray, sql } from "drizzle-orm"
import { Context, Effect, Layer, Option, Schema } from "effect"
import { Session } from "@opencode/schema/session"
import { SessionFamily } from "@opencode/schema/session-family"
import { makeGlobalNode } from "@opencode/util/effect/app-node"
import { Database } from "../database/database.js"
import type { SessionMessage } from "@opencode/schema/session-message"
import { SessionMessageTable, SessionTable } from "./sql.js"
import { fromRow } from "./info.js"

export interface Interface {
  readonly boundaries: (input: SessionFamily.BoundariesInput) => Effect.Effect<typeof SessionFamily.Boundaries.Type>
  readonly read: (input: SessionFamily.Input, active: ReadonlySet<Session.ID>) => Effect.Effect<SessionFamily.Info>
}

export class Service extends Context.Service<Service, Interface>()("@opencode/SessionFamily") {}

const decodeContext = Schema.decodeUnknownOption(Schema.fromJsonString(SessionFamily.Context))

const layer = Layer.effect(
  Service,
  Effect.gen(function* () {
    const database = yield* Database.Service
    return Service.of({
      boundaries: Effect.fn("SessionFamily.boundaries")(function* (input) {
        const rows = yield* database.db
          .select({
            id: SessionTable.id,
            parentID: SessionTable.parent_id,
            // SELECT expressions strip column qualifiers; keep the correlated outer ID explicit.
            messageID: input.message
              ? sql<SessionMessage.ID | null>`(
                  select id from ${SessionMessageTable}
                  where session_id = ${sql.identifier(getTableName(SessionTable))}.${sql.identifier(SessionTable.id.name)}
                    and type = ${input.message.type}
                    and time_created >= ${input.message.createdAtOrAfter}
                  order by seq asc limit 1
                )`
              : sql<SessionMessage.ID | null>`json_extract(${SessionTable.revert}, '$.messageID')`,
          })
          .from(SessionTable)
          .where(
            sql`${SessionTable.id} in (
            with recursive family(id) as (
              select id from ${SessionTable} where parent_id = ${input.sessionID}
              union
              select child.id from ${SessionTable} child join family on child.parent_id = family.id
            ) select id from family where id != ${input.sessionID}
          )`,
          )
          .orderBy(asc(SessionTable.time_updated), asc(SessionTable.id))
          .all()
          .pipe(Effect.orDie)
        // Match paged session.list(order: asc) breadth-first traversal, including
        // ancestors without a matching boundary. Do not decode message payloads.
        const children = new Map<Session.ID, typeof rows>()
        for (const row of rows) {
          if (!row.parentID) continue
          const siblings = children.get(row.parentID) ?? []
          siblings.push(row)
          children.set(row.parentID, siblings)
        }
        const pending = [input.sessionID]
        const visited = new Set(pending)
        const result: SessionFamily.Boundary[] = []
        for (const parentID of pending) {
          for (const row of children.get(parentID) ?? []) {
            if (visited.has(row.id)) continue
            visited.add(row.id)
            pending.push(row.id)
            if (row.messageID) result.push({ sessionID: row.id, messageID: row.messageID })
          }
        }
        return result
      }),
      read: Effect.fn("SessionFamily.read")(function* (input, active) {
        // Walk the indexed parent relation in SQLite; never decode descendant transcripts.
        // UNION also bounds a malformed cycle without adding browser-side traversal state.
        const descendants = sql`${SessionTable.id} in (
          with recursive family(id) as (
            select id from ${SessionTable} where parent_id = ${input.sessionID}
            union
            select child.id from ${SessionTable} child join family on child.parent_id = family.id
          ) select id from family where id != ${input.sessionID}
        )`
        const summary = yield* database.db
          .select({ count: sql<number>`count(*)`, cost: sql<number>`coalesce(sum(${SessionTable.cost}), 0)` })
          .from(SessionTable)
          .where(descendants)
          .get()
          .pipe(Effect.orDie)
        const rows =
          input.limit === undefined
            ? []
            : yield* database.db
                .select({
                  session: getTableColumns(SessionTable),
                  // The newest assistant measurement per listed row, read from the
                  // indexed (session, type, seq) order without decoding payloads.
                  context: sql<string | null>`(
                    select json_object(
                      'id', id,
                      'tokens', json_extract(data, '$.tokens'),
                      'model', json_extract(data, '$.model')
                    )
                    from ${SessionMessageTable}
                    where session_id = ${sql.identifier(getTableName(SessionTable))}.${sql.identifier(SessionTable.id.name)}
                      and type = 'assistant'
                      and json_extract(data, '$.tokens') is not null
                    order by seq desc limit 1
                  )`,
                })
                .from(SessionTable)
                .where(and(descendants, input.after ? gt(SessionTable.id, input.after) : undefined))
                .orderBy(asc(SessionTable.id))
                .limit(input.limit + 1)
                .all()
                .pipe(Effect.orDie)
        const running =
          active.size === 0
            ? []
            : yield* database.db
                .select()
                .from(SessionTable)
                .where(and(descendants, inArray(SessionTable.id, [...active])))
                .orderBy(asc(SessionTable.id))
                .all()
                .pipe(Effect.orDie)
        const data = rows.slice(0, input.limit ?? 0).map((row) => {
          const context = row.context ? Option.getOrUndefined(decodeContext(row.context)) : undefined
          return { ...fromRow(row.session), ...(context ? { context } : {}) }
        })
        return {
          count: summary?.count ?? 0,
          cost: summary?.cost ?? 0,
          data,
          ...(rows.length > data.length ? { next: data.at(-1)!.id } : {}),
          active: running.map(fromRow),
        }
      }),
    })
  }),
)

export const node = makeGlobalNode({ service: Service, layer, deps: [Database.node] })
