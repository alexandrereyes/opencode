import { expect } from "bun:test"
import { eq } from "drizzle-orm"
import { Effect } from "effect"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { Database } from "@opencode/core/database/database"
import { ProjectTable } from "@opencode/core/project/sql"
import { SessionFamily } from "@opencode/core/session/family"
import { SessionTable } from "@opencode/core/session/sql"
import { Session } from "@opencode/schema/session"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { testEffect } from "./lib/effect"

const it = testEffect(AppNodeBuilder.build(LayerNode.group([Database.node, SessionFamily.node])))

it.effect(
  "summarizes 154 descendants without messages, then reads stable bounded pages including archived grandchildren",
  () =>
    Effect.gen(function* () {
      const database = yield* Database.Service
      const family = yield* SessionFamily.Service
      const root = Session.ID.make("ses_root")
      const ids = Array.from({ length: 154 }, (_, i) => Session.ID.make(`ses_child_${String(i).padStart(3, "0")}`))
      yield* database.db
        .insert(ProjectTable)
        .values({ id: Project.ID.global, worktree: AbsolutePath.make("/repo"), sandboxes: [] })
        .run()
      yield* database.db
        .insert(SessionTable)
        .values(
          [root, ...ids, Session.ID.make("ses_unrelated")].map((id, i) => ({
            id,
            project_id: Project.ID.global,
            slug: id,
            directory: AbsolutePath.make("/repo"),
            version: "test",
            parent_id: i > 0 && i <= 154 ? (i > 100 ? ids[0] : root) : undefined,
            time_created: 1,
            time_updated: 1,
            cost: i > 0 && i <= 154 ? 0.5 : 99,
            time_archived: i === 154 ? 2 : undefined,
          })),
        )
        .run()
      const active = new Set([ids[0], ids[153], Session.ID.make("ses_unrelated")])
      const summary = yield* family.read({ sessionID: root }, active)
      expect(summary).toMatchObject({ count: 154, cost: 77, data: [] })
      expect(summary.next).toBeUndefined()
      expect(summary.active.map((session) => session.id)).toEqual([ids[0], ids[153]])
      const first = yield* family.read({ sessionID: root, limit: 10 }, active)
      expect(first.data.map((session) => session.id)).toEqual(ids.slice(0, 10))
      expect(first.next).toBe(ids[9])
      // Updating a listed row cannot change pagination position.
      yield* database.db
        .update(SessionTable)
        .set({ time_updated: 999, title: "Changed" })
        .where(eq(SessionTable.id, ids[0]))
        .run()
      const second = yield* family.read({ sessionID: root, limit: 10, after: first.next }, active)
      expect(second.data.map((session) => session.id)).toEqual(ids.slice(10, 20))
      const last = yield* family.read({ sessionID: root, limit: 10, after: ids[149] }, active)
      expect(last.data.map((session) => session.id)).toEqual(ids.slice(150))
      expect(last.data.at(-1)?.time.archived).toBeDefined()
      expect(last.next).toBeUndefined()
      const nested = yield* family.read({ sessionID: ids[0] }, active)
      expect(nested.count).toBe(54)
      expect(nested.cost).toBe(27)
    }),
)
