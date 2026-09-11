import { expect } from "bun:test"
import { eq } from "drizzle-orm"
import { Effect } from "effect"
import { Bus } from "@opencode/core/bus"
import { SessionProjector } from "@opencode/core/session/projector"
import { SessionEvent } from "@opencode/schema/session-event"
import { Event } from "@opencode/schema/event"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { Database } from "@opencode/core/database/database"
import { ProjectTable } from "@opencode/core/project/sql"
import { SessionTable, SessionMessageTable } from "@opencode/core/session/sql"
import { SessionNavigation } from "@opencode/core/session/navigation"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { testEffect } from "./lib/effect"

const it = testEffect(AppNodeBuilder.build(Database.node))
const projected = testEffect(
  AppNodeBuilder.build(LayerNode.group([Database.node, Bus.node, SessionProjector.node]), [
    Bus.node.replace(Bus.configured({ persist: true })),
  ]),
)

it.effect("navigation clocks come from actual messages; metadata and ID pagination cannot move them", () =>
  Effect.gen(function* () {
    const database = yield* Database.Service
    yield* database.db
      .insert(ProjectTable)
      .values({ id: Project.ID.global, worktree: AbsolutePath.make("/repo"), sandboxes: [] })
      .run()
    yield* database.db
      .insert(SessionTable)
      .values(
        ["a", "b", "c"].map((id) => ({
          id: Session.ID.make(`ses_${id}`),
          project_id: Project.ID.global,
          slug: id,
          directory: AbsolutePath.make("/repo"),
          version: "test",
          time_created: 1,
          time_updated: 1,
        })),
      )
      .run()
    yield* database.db
      .insert(SessionMessageTable)
      .values([
        {
          id: SessionMessage.ID.make("msg_user"),
          session_id: Session.ID.make("ses_a"),
          type: "user",
          seq: 1,
          time_created: 10,
          data: { time: { created: 10 }, text: "hello" },
        },
        {
          id: SessionMessage.ID.make("msg_assistant"),
          session_id: Session.ID.make("ses_a"),
          type: "assistant",
          seq: 2,
          time_created: 20,
          data: { time: { created: 20 }, agent: "build", model: { providerID: "test", id: "test" }, content: [] },
        },
        {
          id: SessionMessage.ID.make("msg_system"),
          session_id: Session.ID.make("ses_a"),
          type: "system",
          seq: 3,
          time_created: 100,
          data: { time: { created: 100 }, text: "instructions changed" },
        },
      ])
      .run()
    const before = yield* SessionNavigation.list({ limit: 1 })
    expect(before.data[0].messageAt).toBe(20)
    expect(String(before.next)).toBe("ses_a")
    yield* database.db
      .update(SessionTable)
      .set({ title: "Renamed", model: { id: "new-model", providerID: "provider" }, time_updated: 1000 })
      .where(eq(SessionTable.id, Session.ID.make("ses_a")))
      .run()
    expect((yield* SessionNavigation.list({ sessionID: Session.ID.make("ses_a") })).data[0].messageAt).toBe(20)
    const second = yield* SessionNavigation.list({ after: before.next, limit: 1 })
    expect(second.data.map((item) => String(item.session.id))).toEqual(["ses_b"])
    expect(second.data[0].messageAt).toBeUndefined()
    const last = yield* SessionNavigation.list({ after: second.next, limit: 1 })
    expect(last.data.map((item) => String(item.session.id))).toEqual(["ses_c"])
    expect(last.next).toBeUndefined()
    yield* database.db
      .update(SessionTable)
      .set({ time_archived: 99 })
      .where(eq(SessionTable.id, Session.ID.make("ses_c")))
      .run()
    expect((yield* SessionNavigation.list()).data.map((item) => String(item.session.id))).toEqual(["ses_a", "ses_b"])
  }),
)

projected.effect("unread attention uses the latest unresolved root completion and ignores child completions", () =>
  Effect.gen(function* () {
    const database = yield* Database.Service
    const bus = yield* Bus.Service
    const sessionID = Session.ID.make("ses_attention")
    yield* database.db
      .insert(ProjectTable)
      .values({ id: Project.ID.global, worktree: AbsolutePath.make("/repo"), sandboxes: [] })
      .run()
    yield* bus.publish(SessionEvent.Created, {
      sessionID,
      projectID: Project.ID.global,
      slug: "attention",
      location: { directory: AbsolutePath.make("/repo") },
      version: "test",
    })
    yield* bus.replay({
      id: Event.ID.create(),
      aggregateID: sessionID,
      seq: 1,
      created: 10,
      type: Bus.versionedType(SessionEvent.Execution.Succeeded.type, 1),
      data: { sessionID },
    })
    yield* bus.replay({
      id: Event.ID.create(),
      aggregateID: sessionID,
      seq: 2,
      created: 20,
      type: Bus.versionedType(SessionEvent.Execution.Succeeded.type, 1),
      data: { sessionID },
    })
    expect((yield* SessionNavigation.list()).data[0].unreadAt).toBe(20)
    yield* bus.publish(SessionEvent.Viewed, { sessionID, idle: 10 })
    expect((yield* SessionNavigation.list()).data[0].unreadAt).toBe(20)
    yield* bus.publish(SessionEvent.Viewed, { sessionID, idle: 20 })
    expect((yield* SessionNavigation.list()).data[0].unreadAt).toBeUndefined()
    const childID = Session.ID.make("ses_child")
    yield* bus.publish(SessionEvent.Created, {
      sessionID: childID,
      parentID: sessionID,
      projectID: Project.ID.global,
      slug: "child",
      location: { directory: AbsolutePath.make("/repo") },
      version: "test",
    })
    yield* bus.publish(SessionEvent.Execution.Succeeded, { sessionID: childID })
    const child = (yield* SessionNavigation.list({ sessionID: childID })).data[0]
    expect(child.session.parentID).toBe(sessionID)
    expect(child.unreadAt).toBeUndefined()
  }),
)
