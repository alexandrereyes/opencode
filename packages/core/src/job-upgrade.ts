export * as JobUpgrade from "./job-upgrade.js"

import { and, eq, gte, lt } from "drizzle-orm"
import { Effect } from "effect"
import type { Database } from "./database/database.js"
import { KVTable } from "./kv/sql.js"

export const prefix = "job.background.upgrade/"
export const archived = and(gte(KVTable.key, prefix), lt(KVTable.key, "job.background.upgrade0"))

/** Compatibility bridge for an old runtime whose maintenance counts every recovery marker as busy. */
export const restore = Effect.fn("JobUpgrade.restore")(function* (db: Database.Interface["db"]) {
  return yield* db
    .transaction(
      Effect.fnUntraced(function* (tx) {
        const rows = yield* tx.select().from(KVTable).where(archived)
        const conflicts: string[] = []
        for (const row of rows) {
          const key = `job.background/${row.key.slice(prefix.length)}`
          yield* tx
            .insert(KVTable)
            .values({ ...row, key })
            .onConflictDoNothing()
            .run()
          const current = yield* tx.select().from(KVTable).where(eq(KVTable.key, key)).get()
          if (!current || JSON.stringify(current.value) !== JSON.stringify(row.value)) {
            conflicts.push(row.key)
            continue
          }
          // The live key now preserves the exact payload/notification ID. A crash commits both changes or neither.
          yield* tx.delete(KVTable).where(eq(KVTable.key, row.key)).run()
        }
        return { restored: rows.length - conflicts.length, conflicts }
      }),
    )
    .pipe(Effect.orDie)
})
