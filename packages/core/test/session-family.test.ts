import { expect } from "bun:test"
import { eq } from "drizzle-orm"
import { DateTime, Effect } from "effect"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { Database } from "@opencode/core/database/database"
import { ProjectTable } from "@opencode/core/project/sql"
import { SessionFamily } from "@opencode/core/session/family"
import { SessionMessage } from "@opencode/schema/session-message"
import { SessionStore } from "@opencode/core/session/store"
import { SessionMessageTable, SessionTable } from "@opencode/core/session/sql"
import { Session } from "@opencode/schema/session"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { testEffect } from "./lib/effect"

const it = testEffect(AppNodeBuilder.build(LayerNode.group([Database.node, SessionFamily.node, SessionStore.node])))

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

it.effect("selects boundaries across 154 descendants with native list/message ordering and an exact cutoff", () =>
  Effect.gen(function* () {
    const database = yield* Database.Service
    const family = yield* SessionFamily.Service
    const store = yield* SessionStore.Service
    const root = Session.ID.make("ses_boundaries_root")
    const ids = Array.from({ length: 154 }, (_, i) => Session.ID.make(`ses_boundary_${String(i).padStart(3, "0")}`))
    yield* database.db
      .insert(ProjectTable)
      .values({ id: Project.ID.global, worktree: AbsolutePath.make("/repo"), sandboxes: [] })
      .onConflictDoNothing()
      .run()
    yield* database.db
      .insert(SessionTable)
      .values(
        [root, ...ids].map((id, i) => ({
          id,
          project_id: Project.ID.global,
          slug: id,
          directory: AbsolutePath.make("/repo"),
          version: "test",
          parent_id: i === 0 ? undefined : i === 154 ? ids[0] : root,
          time_created: i,
          time_updated: 200 - i,
          time_archived: i === 154 ? 1 : undefined,
          revert: i === 1 || i === 154 ? { messageID: SessionMessage.ID.make(`msg_staged_${i}`) } : undefined,
        })),
      )
      .run()
    const messages = [
      { session: ids[0], id: "msg_before", seq: 1, time: 99, type: "user" as const },
      { session: ids[0], id: "msg_z_exact", seq: 2, time: 100, type: "user" as const },
      { session: ids[0], id: "msg_a_later", seq: 3, time: 101, type: "user" as const },
      { session: ids[1], id: "msg_assistant", seq: 1, time: 101, type: "assistant" as const },
      { session: ids[152], id: "msg_child_153", seq: 1, time: 101, type: "user" as const },
      { session: ids[153], id: "msg_grandchild", seq: 1, time: 100, type: "user" as const },
      { session: root, id: "msg_root_excluded", seq: 1, time: 100, type: "user" as const },
    ]
    yield* database.db
      .insert(SessionMessageTable)
      .values(
        messages.map((m) => ({
          id: SessionMessage.ID.make(m.id),
          session_id: m.session,
          seq: m.seq,
          type: m.type,
          time_created: m.time,
          time_updated: m.time,
          data: { text: m.id, time: { created: m.time } },
        })),
      )
      .run()
    const result = yield* family.boundaries({ sessionID: root, message: { type: "user", createdAtOrAfter: 100 } })
    expect(result).toEqual([
      { sessionID: ids[152], messageID: SessionMessage.ID.make("msg_child_153") },
      { sessionID: ids[0], messageID: SessionMessage.ID.make("msg_z_exact") },
      { sessionID: ids[153], messageID: SessionMessage.ID.make("msg_grandchild") },
    ])
    // Compare the aggregation to the actual existing native read services.
    const native = []
    const pending = [root]
    for (const parentID of pending) {
      const children = yield* store.list({ parentID, order: "asc" })
      for (const child of children) {
        pending.push(child.id)
        const history = yield* store.messages({ sessionID: child.id, type: "user", order: "asc" })
        const message = history.find((m) => DateTime.toEpochMillis(m.time.created) >= 100)
        if (message) native.push({ sessionID: child.id, messageID: message.id })
      }
    }
    expect(result).toEqual(native)
    expect(
      yield* family.boundaries({ sessionID: root, message: { type: "assistant", createdAtOrAfter: 100 } }),
    ).toEqual([{ sessionID: ids[1], messageID: SessionMessage.ID.make("msg_assistant") }])
    expect(yield* family.boundaries({ sessionID: root, message: { type: "user", createdAtOrAfter: 102 } })).toEqual([])
    expect(yield* family.boundaries({ sessionID: root })).toEqual([
      { sessionID: ids[0], messageID: SessionMessage.ID.make("msg_staged_1") },
      { sessionID: ids[153], messageID: SessionMessage.ID.make("msg_staged_154") },
    ])
    // A malformed parent cycle still excludes root and visits each descendant once.
    yield* database.db.update(SessionTable).set({ parent_id: ids[153] }).where(eq(SessionTable.id, root)).run()
    expect(yield* family.boundaries({ sessionID: root, message: { type: "user", createdAtOrAfter: 100 } })).toEqual(
      result,
    )
  }),
)
