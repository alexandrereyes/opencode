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
import { SessionStore } from "@opencode/core/session/store"
import { SessionTable, SessionMessageTable } from "@opencode/core/session/sql"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { testEffect } from "./lib/effect"

const it = testEffect(AppNodeBuilder.build(LayerNode.group([Database.node, SessionStore.node])))
const projected = testEffect(
  AppNodeBuilder.build(LayerNode.group([Database.node, Bus.node, SessionProjector.node, SessionStore.node]), [
    Bus.node.replace(Bus.configured({ persist: true })),
  ]),
)

it.effect("scans stable ID pages with message activity and tri-state archive filtering", () =>
  Effect.gen(function* () {
    const database = yield* Database.Service
    const sessions = yield* SessionStore.Service
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
    const first = yield* sessions.scan({ limit: 1 })
    expect(first.data[0].messageAt).toBe(20)
    expect(String(first.next)).toBe("ses_a")
    yield* database.db
      .update(SessionTable)
      .set({ title: "Renamed", model: { id: "new-model", providerID: "provider" }, time_updated: 1000 })
      .where(eq(SessionTable.id, Session.ID.make("ses_a")))
      .run()
    expect((yield* sessions.scan({ sessionID: Session.ID.make("ses_a") })).data[0].messageAt).toBe(20)
    const second = yield* sessions.scan({ after: first.next, limit: 1 })
    expect(second.data.map((item) => String(item.session.id))).toEqual(["ses_b"])
    yield* database.db
      .update(SessionTable)
      .set({ time_archived: 99 })
      .where(eq(SessionTable.id, Session.ID.make("ses_c")))
      .run()
    expect((yield* sessions.scan({ archived: false })).data.map((item) => String(item.session.id))).toEqual([
      "ses_a",
      "ses_b",
    ])
    expect((yield* sessions.scan({ archived: true })).data.map((item) => String(item.session.id))).toEqual(["ses_c"])
    expect((yield* sessions.scan()).data.map((item) => String(item.session.id))).toEqual(["ses_a", "ses_b", "ses_c"])
  }),
)

it.effect("defaults scan pages to 200 rows and caps them at 1000", () =>
  Effect.gen(function* () {
    const database = yield* Database.Service
    const sessions = yield* SessionStore.Service
    yield* database.db
      .insert(ProjectTable)
      .values({ id: Project.ID.global, worktree: AbsolutePath.make("/repo"), sandboxes: [] })
      .run()
    yield* database.db
      .insert(SessionTable)
      .values(
        Array.from({ length: 1002 }, (_, index) => ({
          id: Session.ID.make(`ses_${String(index).padStart(4, "0")}`),
          project_id: Project.ID.global,
          slug: String(index),
          directory: AbsolutePath.make("/repo"),
          version: "test",
          time_created: 1,
          time_updated: 1,
        })),
      )
      .run()
    expect((yield* sessions.scan()).data).toHaveLength(200)
    const capped = yield* sessions.scan({ limit: 2000 })
    expect(capped.data).toHaveLength(1000)
    expect(capped.next).toBe(capped.data.at(-1)?.session.id)
  }),
)

projected.effect("completion activity only reflects durable succeeded and failed events", () =>
  Effect.gen(function* () {
    const database = yield* Database.Service
    const bus = yield* Bus.Service
    const sessions = yield* SessionStore.Service
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
      created: 20,
      type: Bus.versionedType(SessionEvent.Execution.Succeeded.type, 1),
      data: { sessionID },
    })
    yield* bus.replay({
      id: Event.ID.create(),
      aggregateID: sessionID,
      seq: 2,
      created: 30,
      type: Bus.versionedType(SessionEvent.Execution.Interrupted.type, 1),
      data: { sessionID, reason: "user" },
    })
    expect((yield* sessions.scan({ sessionID })).data[0].completionAt).toBe(20)
  }),
)
