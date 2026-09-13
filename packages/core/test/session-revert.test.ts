import { $ } from "bun"
import { describe, expect } from "bun:test"
import { eq } from "drizzle-orm"
import fs from "fs/promises"
import path from "path"
import { Effect } from "effect"
import { Agent } from "@opencode/core/agent"
import { Bus } from "@opencode/core/bus"
import { Database } from "@opencode/core/database/database"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { LocationServiceMap } from "@opencode/core/location-service-map"
import { Job } from "@opencode/core/job"
import { Model } from "@opencode/core/model"
import { Plugin } from "@opencode/core/plugin"
import { PluginHooks } from "@opencode/core/plugin/hooks"
import { Provider } from "@opencode/core/provider"
import { AbsolutePath } from "@opencode/core/schema"
import { Session } from "@opencode/core/session"
import { SessionEvent } from "@opencode/core/session/event"
import { SessionExecution } from "@opencode/core/session/execution"
import { SessionInbox } from "@opencode/core/session/inbox"
import { SessionMessage } from "@opencode/core/session/message"
import { SessionProjector } from "@opencode/core/session/projector"
import { SessionTable } from "@opencode/core/session/sql"
import { Snapshot } from "@opencode/core/snapshot"
import { Money } from "@opencode/schema/money"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Global } from "@opencode/util/global"
import { tempGlobalLayer } from "./fixture/global"
import { offlineModels } from "./fixture/models"
import { tmpdirScoped } from "./fixture/tmpdir"
import { testEffect } from "./lib/effect"
import { plan } from "../../plugin-app-custom/src/causal-undo/index.js"

const it = testEffect(
  AppNodeBuilder.build(
    LayerNode.group([Database.node, Bus.node, Job.node, SessionProjector.node, Session.node, LocationServiceMap.node]),
    [
      Bus.node.replace(Bus.configured({ persist: true })),
      Global.node.replace(tempGlobalLayer),
      SessionExecution.node.replace(SessionExecution.noopLayer),
      offlineModels,
    ],
  ),
)

const installCausalPlanner = (session: Session.Info) =>
  PluginHooks.Service.use((hooks) =>
    hooks.register("session", "revert.plan", (event) =>
      Effect.sync(() => {
        event.plan = plan(event.facts)
      }),
    ),
  ).pipe(Effect.provide(LocationServiceMap.Service.get(session.location)))

describe("Session.revert files", () => {
  it.live(
    "undoes and restores a file rename without losing either path",
    () =>
      Effect.gen(function* () {
        const tmp = yield* tmpdirScoped()
        const directory = path.join(tmp.path, "project")
        const original = path.join(directory, "old name.txt")
        const renamed = path.join(directory, "new name.txt")
        yield* Effect.promise(async () => {
          await fs.mkdir(directory)
          await Bun.write(original, "Preserve this content.\n")
          await Bun.write(path.join(directory, "unrelated.txt"), "Unrelated content.\n")
          await $`git init -q`.cwd(directory).quiet()
          await $`git -c core.fsmonitor=false add .`.cwd(directory).quiet()
        })

        const session = yield* Session.Service
        const database = yield* Database.Service
        const bus = yield* Bus.Service
        const created = yield* session.create({ location: { directory: AbsolutePath.make(directory) } })
        const prompt = yield* session.prompt({ sessionID: created.id, text: "Rename the file", resume: false })
        yield* SessionInbox.promote(database.db, bus, created.id, "steer")

        yield* Effect.gen(function* () {
          const plugins = yield* Plugin.Service
          yield* plugins.awaitActivation
          const snapshot = yield* Snapshot.Service
          const before = yield* snapshot.capture()
          if (!before) throw new Error("Initial snapshot missing")
          const assistantMessageID = SessionMessage.ID.create()
          yield* bus.publish(SessionEvent.Step.Started, {
            sessionID: created.id,
            assistantMessageID,
            agent: Agent.defaultID,
            model: { id: Model.ID.make("test-model"), providerID: Provider.ID.make("test-provider") },
            snapshot: before,
          })
          yield* Effect.promise(() => fs.rename(original, renamed))
          const after = yield* snapshot.capture()
          if (!after) throw new Error("Renamed snapshot missing")
          yield* bus.publish(SessionEvent.Step.Ended, {
            sessionID: created.id,
            assistantMessageID,
            finish: "stop",
            cost: Money.USD.zero,
            tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
            snapshot: after,
            files: yield* snapshot.files({ from: before, to: after }),
          })

          yield* Effect.promise(() => Bun.write(path.join(directory, "unrelated.txt"), "Keep this later edit.\n"))
          const reverted = yield* session.revert.stage({ sessionID: created.id, messageID: prompt.id })
          expect({
            original: yield* Effect.promise(() => Bun.file(original).exists()),
            renamed: yield* Effect.promise(() => Bun.file(renamed).exists()),
          }).toEqual({ original: true, renamed: false })
          expect(yield* Effect.promise(() => Bun.file(original).text())).toBe("Preserve this content.\n")
          expect(reverted.files?.map((file) => [file.file, file.status])).toEqual([
            ["new name.txt", "deleted"],
            ["old name.txt", "added"],
          ])
          expect(yield* Effect.promise(() => Bun.file(path.join(directory, "unrelated.txt")).text())).toBe(
            "Keep this later edit.\n",
          )

          yield* session.revert.clear(created.id)
          expect(yield* Effect.promise(() => Bun.file(original).exists())).toBe(false)
          expect(yield* Effect.promise(() => Bun.file(renamed).text())).toBe("Preserve this content.\n")
          expect(yield* Effect.promise(() => Bun.file(path.join(directory, "unrelated.txt")).text())).toBe(
            "Keep this later edit.\n",
          )
          expect((yield* session.get(created.id)).revert).toBeUndefined()
        }).pipe(Effect.provide(LocationServiceMap.Service.get(created.location)))
      }),
    // Real Location/plugin startup and Git snapshots can exceed five seconds under CI load.
    { timeout: 15_000 },
  )

  it.live(
    "uses the globally earliest affected snapshot when child and parent change the same file",
    () =>
      Effect.gen(function* () {
        const tmp = yield* tmpdirScoped()
        const directory = path.join(tmp.path, "project")
        const changed = path.join(directory, "shared.txt")
        yield* Effect.promise(async () => {
          await fs.mkdir(directory)
          await $`git init -q`.cwd(directory).quiet()
          await Bun.write(changed, "base\n")
          await $`git -c core.fsmonitor=false add .`.cwd(directory).quiet()
        })
        const sessions = yield* Session.Service
        const database = yield* Database.Service
        const bus = yield* Bus.Service
        const parent = yield* sessions.create({ location: { directory: AbsolutePath.make(directory) } })
        yield* installCausalPlanner(parent)
        const child = yield* sessions.create({ parentID: parent.id })
        const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "delegate edit", resume: false })
        yield* SessionInbox.promote(database.db, bus, parent.id, "steer")
        const childInputID = SessionMessage.ID.create()
        yield* sessions.prompt({
          id: childInputID,
          sessionID: child.id,
          text: "edit file",
          resume: false,
          causal: {
            parentSessionID: parent.id,
            messageID: SessionMessage.ID.create(),
            toolCallID: "edit-child-file",
          },
        })
        yield* SessionInbox.promote(database.db, bus, child.id, "steer")
        yield* Effect.forEach(
          Array.from({ length: 30 }),
          (_, idle) => bus.publish(SessionEvent.Viewed, { sessionID: child.id, idle }),
          { discard: true },
        )

        yield* Effect.gen(function* () {
          const snapshot = yield* Snapshot.Service
          const before = yield* snapshot.capture()
          if (!before) return yield* Effect.die("Expected child start snapshot")
          const assistantMessageID = SessionMessage.ID.create()
          yield* bus.publish(SessionEvent.Step.Started, {
            sessionID: child.id,
            assistantMessageID,
            agent: Agent.defaultID,
            model: { id: Model.ID.make("test-model"), providerID: Provider.ID.make("test-provider") },
            snapshot: before,
          })
          yield* Effect.promise(() => Bun.write(changed, "from child\n"))
          const after = yield* snapshot.capture()
          if (!after) return yield* Effect.die("Expected child end snapshot")
          yield* bus.publish(SessionEvent.Step.Ended, {
            sessionID: child.id,
            assistantMessageID,
            finish: "stop",
            cost: Money.USD.zero,
            tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
            snapshot: after,
            files: yield* snapshot.files({ from: before, to: after }),
          })
        }).pipe(Effect.provide(LocationServiceMap.Service.get(child.location)))

        yield* Effect.gen(function* () {
          const snapshot = yield* Snapshot.Service
          const before = yield* snapshot.capture()
          if (!before) return yield* Effect.die("Expected parent start snapshot")
          const assistantMessageID = SessionMessage.ID.create()
          yield* bus.publish(SessionEvent.Step.Started, {
            sessionID: parent.id,
            assistantMessageID,
            agent: Agent.defaultID,
            model: { id: Model.ID.make("test-model"), providerID: Provider.ID.make("test-provider") },
            snapshot: before,
          })
          yield* Effect.promise(() => Bun.write(changed, "from parent\n"))
          const after = yield* snapshot.capture()
          if (!after) return yield* Effect.die("Expected parent end snapshot")
          yield* bus.publish(SessionEvent.Step.Ended, {
            sessionID: parent.id,
            assistantMessageID,
            finish: "stop",
            cost: Money.USD.zero,
            tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
            snapshot: after,
            files: yield* snapshot.files({ from: before, to: after }),
          })
        }).pipe(Effect.provide(LocationServiceMap.Service.get(parent.location)))

        yield* sessions.revert.stage({ sessionID: parent.id, messageID: boundary.id })
        expect(yield* Effect.promise(() => Bun.file(changed).text())).toBe("base\n")
        yield* sessions.revert.clear(parent.id)
        expect(yield* Effect.promise(() => Bun.file(changed).text())).toBe("from parent\n")
      }),
    { timeout: 15_000 },
  )
})

describe("Session.revert causal history", () => {
  it.live("uses the root planner while retaining a cross-Location history participant", () =>
    Effect.gen(function* () {
      const rootDirectory = yield* tmpdirScoped()
      const childDirectory = yield* tmpdirScoped()
      const sessions = yield* Session.Service
      const database = yield* Database.Service
      const bus = yield* Bus.Service
      const parent = yield* sessions.create({ location: { directory: AbsolutePath.make(rootDirectory.path) } })
      const child = yield* sessions.create({
        parentID: parent.id,
      })
      yield* database.db
        .update(SessionTable)
        .set({ directory: AbsolutePath.make(childDirectory.path) })
        .where(eq(SessionTable.id, child.id))
        .run()
      let rootCalls = 0
      let plannedLocation: unknown
      let plannedChildLocation: unknown
      yield* PluginHooks.Service.use((hooks) =>
        hooks.register("session", "revert.plan", (event) =>
          Effect.sync(() => {
            rootCalls++
            plannedLocation = event.facts.sessions.find(
              (session) => session.sessionID === event.facts.boundary.sessionID,
            )?.location
            plannedChildLocation = event.facts.sessions.find((session) => session.sessionID === child.id)?.location
            event.plan = plan(event.facts)
          }),
        ),
      ).pipe(Effect.provide(LocationServiceMap.Service.get(parent.location)))
      const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "boundary", resume: false })
      yield* SessionInbox.promote(database.db, bus, parent.id, "steer")
      const input = yield* admitSubagent(sessions, {
        parentSessionID: parent.id,
        childSessionID: child.id,
        messageID: SessionMessage.ID.create(),
        toolCallID: "cross-location",
        text: "child input",
      })
      yield* SessionInbox.promote(database.db, bus, child.id, "steer")
      rootCalls = 0

      const staged = yield* sessions.revert.stage({ sessionID: parent.id, messageID: boundary.id, files: false })
      expect(staged.children).toEqual([{ sessionID: child.id, messageID: input.id, pendingIDs: [] }])
      expect(rootCalls).toBe(1)
      expect(plannedLocation).toEqual(parent.location)
      expect(plannedChildLocation).toMatchObject({ directory: childDirectory.path })
      yield* sessions.revert.commit(parent.id)
      expect(yield* sessions.messages({ sessionID: child.id })).toEqual([])
    }),
  )

  it.live("rejects a parent stage that would overwrite an independent child stage", () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped()
      const sessions = yield* Session.Service
      const database = yield* Database.Service
      const bus = yield* Bus.Service
      const parent = yield* sessions.create({ location: { directory: AbsolutePath.make(tmp.path) } })
      yield* installCausalPlanner(parent)
      const child = yield* sessions.create({ parentID: parent.id })
      const childBoundary = yield* sessions.prompt({ sessionID: child.id, text: "child boundary", resume: false })
      yield* SessionInbox.promote(database.db, bus, child.id, "steer")
      const parentBoundary = yield* sessions.prompt({ sessionID: parent.id, text: "parent boundary", resume: false })
      yield* SessionInbox.promote(database.db, bus, parent.id, "steer")
      const childInput = yield* admitSubagent(sessions, {
        parentSessionID: parent.id,
        childSessionID: child.id,
        messageID: SessionMessage.ID.create(),
        toolCallID: "parent-child",
        text: "child causal suffix",
      })
      yield* SessionInbox.promote(database.db, bus, child.id, "steer")
      yield* sessions.revert.stage({ sessionID: child.id, messageID: childBoundary.id, files: false })
      const childRevert = (yield* sessions.get(child.id)).revert

      expect(
        yield* Effect.flip(sessions.revert.stage({ sessionID: parent.id, messageID: parentBoundary.id, files: false })),
      ).toMatchObject({ _tag: "Session.BusyError", sessionID: child.id })
      expect((yield* sessions.get(child.id)).revert).toEqual(childRevert)
      expect((yield* sessions.messages({ sessionID: child.id })).map((message) => message.id)).toContain(childInput.id)
    }),
  )

  it.live("rejects a pending root boundary without leaving a staged revert", () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped()
      const sessions = yield* Session.Service
      const parent = yield* sessions.create({ location: { directory: AbsolutePath.make(tmp.path) } })
      const pending = yield* sessions.prompt({ sessionID: parent.id, text: "pending root", resume: false })

      expect(
        yield* Effect.flip(sessions.revert.stage({ sessionID: parent.id, messageID: pending.id, files: false })),
      ).toMatchObject({ _tag: "Session.MessageNotFoundError", messageID: pending.id })
      expect((yield* sessions.get(parent.id)).revert).toBeUndefined()
      expect((yield* sessions.prompt({ sessionID: parent.id, text: "still valid", resume: false })).payload.text).toBe(
        "still valid",
      )
    }),
  )

  it.live("tracks promoted and every pending causal input independently for one child", () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped()
      const sessions = yield* Session.Service
      const database = yield* Database.Service
      const bus = yield* Bus.Service
      const parent = yield* sessions.create({ location: { directory: AbsolutePath.make(tmp.path) } })
      yield* installCausalPlanner(parent)
      const child = yield* sessions.create({ parentID: parent.id })
      yield* sessions.prompt({ sessionID: child.id, text: "preserved prefix", resume: false })
      yield* SessionInbox.promote(database.db, bus, child.id, "steer")
      const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "mixed inputs", resume: false })
      yield* SessionInbox.promote(database.db, bus, parent.id, "steer")
      const first = yield* admitSubagent(sessions, {
        parentSessionID: parent.id,
        childSessionID: child.id,
        messageID: SessionMessage.ID.create(),
        toolCallID: "queue-first",
        text: "queued first",
        delivery: "queue",
      })
      const promoted = yield* admitSubagent(sessions, {
        parentSessionID: parent.id,
        childSessionID: child.id,
        messageID: SessionMessage.ID.create(),
        toolCallID: "steer-promoted",
        text: "promoted second",
      })
      yield* SessionInbox.promote(database.db, bus, child.id, "steer")
      const last = yield* admitSubagent(sessions, {
        parentSessionID: parent.id,
        childSessionID: child.id,
        messageID: SessionMessage.ID.create(),
        toolCallID: "queue-last",
        text: "queued last",
        delivery: "queue",
      })

      const staged = yield* sessions.revert.stage({ sessionID: parent.id, messageID: boundary.id, files: false })
      expect(staged.children).toEqual([
        { sessionID: child.id, messageID: promoted.id, pendingIDs: [first.id, last.id] },
      ])
      yield* sessions.revert.commit(parent.id)
      expect(yield* sessions.inbox(child.id)).toEqual([])
      expect(JSON.stringify(yield* sessions.messages({ sessionID: child.id }))).not.toContain("promoted second")
      expect(JSON.stringify(yield* sessions.messages({ sessionID: child.id }))).toContain("preserved prefix")
    }),
  )

  it.live("does not treat work produced by an earlier step after a pending child input as its causal suffix", () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped()
      const sessions = yield* Session.Service
      const database = yield* Database.Service
      const bus = yield* Bus.Service
      const parent = yield* sessions.create({ location: { directory: AbsolutePath.make(tmp.path) } })
      yield* installCausalPlanner(parent)
      const child = yield* sessions.create({ parentID: parent.id })
      yield* sessions.prompt({ sessionID: child.id, text: "step A", resume: false })
      yield* SessionInbox.promote(database.db, bus, child.id, "steer")
      const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "pending B", resume: false })
      yield* SessionInbox.promote(database.db, bus, parent.id, "steer")
      const pendingOriginMessageID = SessionMessage.ID.create()
      yield* bus.publish(SessionEvent.Step.Started, {
        sessionID: parent.id,
        assistantMessageID: pendingOriginMessageID,
        agent: Agent.defaultID,
        model: { id: Model.ID.make("test-model"), providerID: Provider.ID.make("test-provider") },
      })
      yield* publishSubagentCall(bus, parent.id, pendingOriginMessageID, "pending-B")
      const pending = yield* admitSubagent(sessions, {
        parentSessionID: parent.id,
        childSessionID: child.id,
        messageID: pendingOriginMessageID,
        toolCallID: "pending-B",
        text: "input B",
      })
      const jobs = yield* Job.Service
      const earlierOrigin = {
        parentSessionID: child.id,
        messageID: SessionMessage.ID.create(),
        toolCallID: "step-A",
      }
      yield* jobs.start({
        id: child.id,
        type: "subagent",
        origins: [
          earlierOrigin,
          { parentSessionID: parent.id, messageID: pendingOriginMessageID, toolCallID: "pending-B" },
        ],
        run: Effect.never,
      })

      const assistantMessageID = SessionMessage.ID.create()
      yield* bus.publish(SessionEvent.Step.Started, {
        sessionID: child.id,
        assistantMessageID,
        agent: Agent.defaultID,
        model: { id: Model.ID.make("test-model"), providerID: Provider.ID.make("test-provider") },
      })
      const grandchild = yield* sessions.create({ parentID: child.id })
      const grandchildInput = yield* admitSubagent(sessions, {
        parentSessionID: child.id,
        childSessionID: grandchild.id,
        messageID: assistantMessageID,
        toolCallID: "step-A-grandchild",
        text: "work from step A",
      })
      yield* SessionInbox.promote(database.db, bus, grandchild.id, "steer")

      const staged = yield* sessions.revert.stage({ sessionID: parent.id, messageID: boundary.id, files: false })
      expect(staged.children).toEqual([{ sessionID: child.id, pendingIDs: [pending.id] }])
      expect(yield* jobs.get(child.id)).toMatchObject({ status: "running", origins: [earlierOrigin] })
      yield* sessions.revert.commit(parent.id)

      expect((yield* sessions.messages({ sessionID: child.id })).map((message) => message.id)).toContain(
        assistantMessageID,
      )
      expect((yield* sessions.messages({ sessionID: grandchild.id })).map((message) => message.id)).toEqual([
        grandchildInput.id,
      ])
      yield* jobs.cancel(child.id)
    }),
  )

  it.live("rewinds reused children, retains new child records, and clears without changing child history", () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped()
      const sessions = yield* Session.Service
      const database = yield* Database.Service
      const bus = yield* Bus.Service
      const parent = yield* sessions.create({ location: { directory: AbsolutePath.make(tmp.path) } })
      yield* installCausalPlanner(parent)
      const reused = yield* sessions.create({ parentID: parent.id })
      const earlier = yield* sessions.prompt({ sessionID: reused.id, text: "earlier independent work", resume: false })
      yield* SessionInbox.promote(database.db, bus, reused.id, "steer")
      const earlierAssistantID = SessionMessage.ID.create()
      yield* bus.publish(SessionEvent.Step.Started, {
        sessionID: reused.id,
        assistantMessageID: earlierAssistantID,
        agent: Agent.defaultID,
        model: { id: Model.ID.make("test-model"), providerID: Provider.ID.make("test-provider") },
      })
      yield* publishSubagentCall(bus, reused.id, earlierAssistantID, "earlier-nested")
      const earlierGrandchild = yield* sessions.create({ parentID: reused.id })
      const earlierGrandchildInput = yield* admitSubagent(sessions, {
        parentSessionID: reused.id,
        childSessionID: earlierGrandchild.id,
        messageID: earlierAssistantID,
        toolCallID: "earlier-nested",
        text: "earlier nested work",
      })
      yield* SessionInbox.promote(database.db, bus, earlierGrandchild.id, "steer")
      const pendingChild = yield* sessions.create({ parentID: parent.id })
      const pendingEarlier = yield* sessions.prompt({
        sessionID: pendingChild.id,
        text: "pending child prefix",
        resume: false,
      })
      yield* SessionInbox.promote(database.db, bus, pendingChild.id, "steer")
      const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "delegate both tasks", resume: false })
      yield* SessionInbox.promote(database.db, bus, parent.id, "steer")

      const assistantMessageID = SessionMessage.ID.create()
      yield* bus.publish(SessionEvent.Step.Started, {
        sessionID: parent.id,
        assistantMessageID,
        agent: Agent.defaultID,
        model: { id: Model.ID.make("test-model"), providerID: Provider.ID.make("test-provider") },
      })
      yield* publishSubagentCall(bus, parent.id, assistantMessageID, "reuse")
      yield* publishSubagentCall(bus, parent.id, assistantMessageID, "pending")
      yield* publishSubagentCall(bus, parent.id, assistantMessageID, "create")

      const reusedInput = yield* admitSubagent(sessions, {
        parentSessionID: parent.id,
        childSessionID: reused.id,
        messageID: assistantMessageID,
        toolCallID: "reuse",
        text: "causal continuation",
      })
      yield* SessionInbox.promote(database.db, bus, reused.id, "steer")
      const reusedAssistantID = SessionMessage.ID.create()
      yield* bus.publish(SessionEvent.Step.Started, {
        sessionID: reused.id,
        assistantMessageID: reusedAssistantID,
        agent: Agent.defaultID,
        model: { id: Model.ID.make("test-model"), providerID: Provider.ID.make("test-provider") },
      })
      yield* publishSubagentCall(bus, reused.id, reusedAssistantID, "nested")
      const grandchild = yield* sessions.create({ parentID: reused.id })
      const grandchildInput = yield* admitSubagent(sessions, {
        parentSessionID: reused.id,
        childSessionID: grandchild.id,
        messageID: reusedAssistantID,
        toolCallID: "nested",
        text: "nested child work",
      })
      yield* SessionInbox.promote(database.db, bus, grandchild.id, "steer")
      yield* sessions.prompt({ sessionID: reused.id, text: "later dependent work", resume: false })

      const pendingInput = yield* admitSubagent(sessions, {
        parentSessionID: parent.id,
        childSessionID: pendingChild.id,
        messageID: assistantMessageID,
        toolCallID: "pending",
        text: "causal input still pending",
      })

      const created = yield* sessions.create({ parentID: parent.id })
      const createdInput = yield* admitSubagent(sessions, {
        parentSessionID: parent.id,
        childSessionID: created.id,
        messageID: assistantMessageID,
        toolCallID: "create",
        text: "new child work",
      })
      yield* SessionInbox.promote(database.db, bus, created.id, "steer")
      const forward = yield* sessions.prompt({ sessionID: parent.id, text: "later parent boundary", resume: false })
      yield* SessionInbox.promote(database.db, bus, parent.id, "steer")

      const staged = yield* sessions.revert.stage({ sessionID: parent.id, messageID: boundary.id, files: false })
      expect(staged.children).toHaveLength(4)
      expect(staged.children).not.toContainEqual({
        sessionID: earlierGrandchild.id,
        messageID: earlierGrandchildInput.id,
        pendingIDs: [],
      })
      expect(staged.children).toContainEqual({ sessionID: reused.id, messageID: reusedInput.id, pendingIDs: [] })
      expect(staged.children).toContainEqual({
        sessionID: grandchild.id,
        messageID: grandchildInput.id,
        pendingIDs: [],
      })
      expect(staged.children).toContainEqual({
        sessionID: pendingChild.id,
        pendingIDs: [pendingInput.id],
      })
      expect(staged.children).toContainEqual({ sessionID: created.id, messageID: createdInput.id, pendingIDs: [] })
      expect((yield* sessions.get(reused.id)).revert).toMatchObject({
        messageID: reusedInput.id,
        parentID: parent.id,
      })
      expect(
        yield* Effect.flip(sessions.revert.stage({ sessionID: reused.id, messageID: reusedInput.id, files: false })),
      ).toMatchObject({ _tag: "Session.BusyError", sessionID: reused.id })
      expect((yield* sessions.get(reused.id)).revert).toMatchObject({
        messageID: reusedInput.id,
        parentID: parent.id,
      })
      const advanced = yield* sessions.revert.stage({ sessionID: parent.id, messageID: forward.id, files: false })
      expect(advanced.children ?? []).toEqual([])
      expect((yield* sessions.get(reused.id)).revert).toBeUndefined()
      yield* sessions.revert.stage({ sessionID: parent.id, messageID: boundary.id, files: false })
      expect((yield* sessions.get(reused.id)).revert).toBeDefined()
      yield* sessions.revert.clear(parent.id)
      expect((yield* sessions.get(reused.id)).revert).toBeUndefined()
      const clearedMessages = (yield* sessions.messages({ sessionID: reused.id, order: "asc" })).map(
        (message) => message.id,
      )
      expect(clearedMessages).toContain(earlier.id)
      expect(clearedMessages).toContain(reusedInput.id)
      expect(clearedMessages).toContain(reusedAssistantID)
      expect(yield* sessions.inbox(reused.id)).toHaveLength(1)
      expect(yield* sessions.messages({ sessionID: created.id })).toHaveLength(1)

      yield* sessions.revert.stage({ sessionID: parent.id, messageID: boundary.id, files: false })
      yield* sessions.cancelInbox({ sessionID: pendingChild.id, inboxID: pendingInput.id })
      const direct = yield* sessions.prompt({
        sessionID: reused.id,
        text: "new direct child branch",
        resume: false,
      })

      const reusedMessages = (yield* sessions.messages({ sessionID: reused.id })).map((message) => message.id)
      expect(reusedMessages).toContain(earlier.id)
      expect(reusedMessages).toContain(earlierAssistantID)
      expect(reusedMessages).not.toContainAnyValues([reusedInput.id, reusedAssistantID])
      expect((yield* sessions.inbox(reused.id)).map((message) => message.id)).toEqual([direct.id])
      expect((yield* sessions.get(parent.id)).revert).toBeUndefined()
      expect((yield* sessions.get(reused.id)).revert).toBeUndefined()
      expect((yield* sessions.messages({ sessionID: pendingChild.id })).map((message) => message.id)).toEqual([
        pendingEarlier.id,
      ])
      expect(yield* sessions.inbox(pendingChild.id)).toEqual([])
      expect(yield* sessions.messages({ sessionID: created.id })).toEqual([])
      expect((yield* sessions.get(created.id)).parentID).toBe(parent.id)
      expect(yield* sessions.messages({ sessionID: grandchild.id })).toEqual([])
      expect((yield* sessions.get(grandchild.id)).parentID).toBe(reused.id)
      expect((yield* sessions.messages({ sessionID: earlierGrandchild.id })).map((message) => message.id)).toEqual([
        earlierGrandchildInput.id,
      ])
    }),
  )
})

const publishSubagentCall = Effect.fnUntraced(function* (
  bus: Bus.Interface,
  sessionID: Session.Info["id"],
  assistantMessageID: SessionMessage.ID,
  id: string,
) {
  yield* bus.publish(SessionEvent.Tool.Input.Started, {
    sessionID,
    assistantMessageID,
    id,
    name: "subagent",
  })
  yield* bus.publish(SessionEvent.Tool.Called, {
    sessionID,
    assistantMessageID,
    id,
    input: {},
    executed: false,
  })
})

const admitSubagent = Effect.fnUntraced(function* (
  sessions: Session.Interface,
  input: {
    parentSessionID: Session.Info["id"]
    childSessionID: Session.Info["id"]
    messageID: SessionMessage.ID
    toolCallID: string
    text: string
    delivery?: SessionInbox.Delivery
  },
) {
  const inputID = SessionMessage.ID.create()
  return yield* sessions.prompt({
    id: inputID,
    sessionID: input.childSessionID,
    text: input.text,
    delivery: input.delivery,
    resume: false,
    causal: {
      parentSessionID: input.parentSessionID,
      messageID: input.messageID,
      toolCallID: input.toolCallID,
    },
  })
})
