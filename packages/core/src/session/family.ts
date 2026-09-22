export * as SessionFamily from "./family.js"

import { and, asc, gt, inArray, sql } from "drizzle-orm"
import { Context, Effect, Layer } from "effect"
import { Session } from "@opencode/schema/session"
import { SessionFamily } from "@opencode/schema/session-family"
import { makeGlobalNode } from "@opencode/util/effect/app-node"
import { Database } from "../database/database.js"
import { SessionTable } from "./sql.js"
import { fromRow } from "./info.js"

export interface Interface {
  readonly read: (input: SessionFamily.Input, active: ReadonlySet<Session.ID>) => Effect.Effect<SessionFamily.Info>
}

export class Service extends Context.Service<Service, Interface>()("@opencode/SessionFamily") {}

const layer = Layer.effect(
  Service,
  Effect.gen(function* () {
    const database = yield* Database.Service
    return Service.of({
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
                .select()
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
        const data = rows.slice(0, input.limit ?? 0).map(fromRow)
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
