import { sql } from "drizzle-orm"
import { Effect } from "effect"
import type { DatabaseMigration } from "../migration.js"

const archivedPrefix = "job.background.upgrade/"
const livePrefix = "job.background/"

export function restoreBackgroundUpgrade(tx: Parameters<DatabaseMigration.Migration["up"]>[0]) {
  return Effect.gen(function* () {
    yield* tx.run(sql`
      INSERT OR IGNORE INTO kv (key, value, time_created, time_updated)
      SELECT ${livePrefix} || substr(key, length(${archivedPrefix}) + 1), value, time_created, time_updated
      FROM kv
      WHERE key >= ${archivedPrefix} AND key < ${"job.background.upgrade0"}
    `)
    yield* tx.run(sql`
      DELETE FROM kv
      WHERE key >= ${archivedPrefix}
        AND key < ${"job.background.upgrade0"}
        AND EXISTS (
          SELECT 1
          FROM kv AS live
          WHERE live.key = ${livePrefix} || substr(kv.key, length(${archivedPrefix}) + 1)
            AND live.value = kv.value
        )
    `)
    const conflicts = yield* tx.all<{ key: string }>(sql`
      SELECT key
      FROM kv
      WHERE key >= ${archivedPrefix} AND key < ${"job.background.upgrade0"}
      ORDER BY key
    `)
    if (conflicts.length > 0)
      return yield* Effect.fail(
        new Error(`Conflicting legacy background markers: ${conflicts.map((row) => row.key).join(", ")}`),
      )
  })
}

const migration: DatabaseMigration.Migration = {
  id: "20260913000000_restore-background-upgrade",
  up: restoreBackgroundUpgrade,
}

export default migration
