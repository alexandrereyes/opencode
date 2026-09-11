import { expect } from "bun:test"
import { Effect } from "effect"
import { eq } from "drizzle-orm"
import { AppNodeBuilder } from "../src/effect/app-node-builder"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Database } from "../src/database/database"
import { KVTable } from "../src/kv/sql"
import { JobUpgrade } from "../src/job-upgrade"
import { testEffect } from "./lib/effect"

const it = testEffect(AppNodeBuilder.build(LayerNode.group([Database.node])))
it.effect("restores exact payload and timestamps atomically and idempotently", () =>
  Effect.gen(function* () {
    const database = yield* Database.Service
    const archived = {
      key: `${JobUpgrade.prefix}msg_fixture`,
      value: {
        id: "sh_fixture",
        notificationID: "msg_fixture",
        status: "running",
        recovery: { kind: "shell", sessionID: "ses_fixture", shellID: "sh_fixture", command: "fixture" },
      },
      time_created: 10,
      time_updated: 20,
    }
    yield* database.db.insert(KVTable).values(archived).run()
    expect(yield* JobUpgrade.restore(database.db)).toEqual({ restored: 1, conflicts: [] })
    expect(
      yield* database.db.select().from(KVTable).where(eq(KVTable.key, "job.background/msg_fixture")).get(),
    ).toEqual({ ...archived, key: "job.background/msg_fixture" })
    expect(yield* JobUpgrade.restore(database.db)).toEqual({ restored: 0, conflicts: [] })
  }),
)
it.effect("does not overwrite newer live payload and retains conflicting archived record", () =>
  Effect.gen(function* () {
    const database = yield* Database.Service
    const key = `${JobUpgrade.prefix}msg_collision`
    yield* database.db
      .insert(KVTable)
      .values([
        { key, value: { status: "running" }, time_created: 1, time_updated: 2 },
        {
          key: "job.background/msg_collision",
          value: { status: "completed", output: "retained result" },
          time_created: 1,
          time_updated: 3,
        },
      ])
      .run()
    expect(yield* JobUpgrade.restore(database.db)).toEqual({ restored: 0, conflicts: [key] })
    expect((yield* database.db.select().from(KVTable)).length).toBe(2)
    expect(
      (yield* database.db.select().from(KVTable).where(eq(KVTable.key, "job.background/msg_collision")).get())?.value,
    ).toEqual({ status: "completed", output: "retained result" })
  }),
)
