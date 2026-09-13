import { describe, expect } from "bun:test"
import { Effect, Layer, RcMap, Scope } from "effect"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Database } from "@opencode/core/database/database"
import { Bus } from "@opencode/core/bus"
import { Instance } from "@opencode/core/instance/service"
import { Location } from "@opencode/core/location"
import { Project } from "@opencode/core/project"
import { AbsolutePath } from "@opencode/core/schema"
import { Session } from "@opencode/core/session"
import { SessionExecution } from "@opencode/core/session/execution"
import { SessionRunCoordinator } from "@opencode/core/session/run-coordinator"
import { SessionModelTransport } from "@opencode/core/session/model-transport"
import { SessionProjector } from "@opencode/core/session/projector"
import { SessionStore } from "@opencode/core/session/store"
import { SessionEnvironment } from "@opencode/core/session/environment"
import { LocationServiceMap } from "@opencode/core/location-services"
import { testEffect } from "./lib/effect"
import { globalProjectNode } from "./lib/project"
import { offlineModels } from "./fixture/models"
import { tmpdirScoped } from "./fixture/tmpdir"

const closed: Session.ID[] = []
const transportScopes = new Set<Scope.Scope>()
const transport = Layer.effect(
  SessionModelTransport.Service,
  Effect.gen(function* () {
    const scope = yield* Scope.Scope
    transportScopes.add(scope)
    yield* Effect.addFinalizer(() => Effect.sync(() => transportScopes.delete(scope)))
    return SessionModelTransport.Service.of({
      bind: () => ({ execute: () => Effect.die("Unexpected WebSocket execution") }),
      close: (sessionID) => Effect.sync(() => closed.push(sessionID)),
      closeAll: Effect.void,
    })
  }),
)
const activeExecution = Layer.effect(
  SessionExecution.Service,
  SessionRunCoordinator.make<Session.ID, never, "user">({
    started: () => Effect.void,
    drain: () => Effect.never,
    settled: () => Effect.void,
  }).pipe(
    Effect.map((coordinator) =>
      SessionExecution.Service.of({
        active: coordinator.active,
        isActive: coordinator.isActive,
        resume: coordinator.run,
        wake: coordinator.wake,
        interrupt: (sessionID, options) =>
          coordinator.interrupt(
            sessionID,
            "user",
            options?.awaitSettlement ? { awaitSettlement: true } : undefined,
          ),
        awaitIdle: coordinator.awaitIdle,
      }),
    ),
  ),
)
const it = testEffect(
  AppNodeBuilder.build(
    LayerNode.group([
      Database.node,
      Bus.node,
      SessionProjector.node,
      SessionStore.node,
      SessionEnvironment.node,
      Session.node,
      Instance.node,
      LocationServiceMap.node,
    ]),
    [
      Project.node.replace(globalProjectNode),
      SessionExecution.node.replace(SessionExecution.noopLayer),
      SessionModelTransport.node.replace(transport),
      offlineModels,
    ],
  ),
)
const activeIt = testEffect(
  AppNodeBuilder.build(
    LayerNode.group([
      Database.node,
      Bus.node,
      SessionProjector.node,
      SessionStore.node,
      SessionEnvironment.node,
      Session.node,
      Instance.node,
      LocationServiceMap.node,
    ]),
    [
      Project.node.replace(globalProjectNode),
      SessionExecution.node.replace(activeExecution),
      SessionModelTransport.node.replace(transport),
      offlineModels,
    ],
  ),
)

describe("Session.archive", () => {
  it.effect("archives one session, preserves related sessions, and can be repeated before deletion", () =>
    Effect.gen(function* () {
      const temporary = yield* tmpdirScoped()
      const session = yield* Session.Service
      const parent = yield* session.create({
        location: Location.Ref.make({ directory: AbsolutePath.make(temporary.path) }),
      })
      const child = yield* session.create({ parentID: parent.id })
      const grandchild = yield* session.create({ parentID: child.id })
      const unrelated = yield* session.create({ location: parent.location })
      yield* session.rename({ sessionID: parent.id, title: "Retained history" })
      const updated = (yield* session.get(parent.id)).time.updated
      closed.length = 0

      yield* session.archive(parent.id)

      expect(closed).toEqual([parent.id])
      const archived = yield* session.get(parent.id)
      expect(archived.time.archived).toBeDefined()
      expect(archived.time.updated).toEqual(updated)
      expect(archived.title).toBe("Retained history")
      expect((yield* session.get(child.id)).time.archived).toBeUndefined()
      expect((yield* session.get(grandchild.id)).time.archived).toBeUndefined()
      expect((yield* session.get(unrelated.id)).time.archived).toBeUndefined()
      expect((yield* session.list()).data).toHaveLength(4)

      yield* session.archive(parent.id)
      expect((yield* session.get(parent.id)).time.archived).toEqual(archived.time.archived)
      expect(closed).toEqual([parent.id, parent.id])
      yield* session.remove(parent.id)
      expect((yield* session.list()).data.map((item) => item.id)).toEqual([unrelated.id])
    }),
  )

  it.effect("rejects an unknown session", () =>
    Effect.gen(function* () {
      const session = yield* Session.Service
      expect(yield* Effect.result(session.archive(Session.ID.make("ses_missing")))).toMatchObject({
        _tag: "Failure",
        failure: { _tag: "Session.NotFoundError" },
      })
    }),
  )

  activeIt.effect("interrupts an active execution and waits for settlement", () =>
    Effect.gen(function* () {
      const temporary = yield* tmpdirScoped()
      const session = yield* Session.Service
      const created = yield* session.create({
        location: Location.Ref.make({ directory: AbsolutePath.make(temporary.path) }),
      })
      yield* session.resume(created.id).pipe(Effect.forkChild)
      yield* Effect.yieldNow
      expect((yield* session.active).has(created.id)).toBe(true)

      yield* session.archive(created.id)

      expect((yield* session.active).has(created.id)).toBe(false)
      expect((yield* session.get(created.id)).time.archived).toBeDefined()
    }),
  )
})

describe("Session.remove", () => {
  it.effect("removes a session and its children", () =>
    Effect.gen(function* () {
      const temporary = yield* tmpdirScoped()
      const location = Location.Ref.make({ directory: AbsolutePath.make(temporary.path) })
      const session = yield* Session.Service
      const parent = yield* session.create({ location })
      const child = yield* session.create({ parentID: parent.id })
      const grandchild = yield* session.create({ parentID: child.id })
      yield* session.environment({ sessionID: parent.id, variables: { SESSION_ENV: "parent" } })
      yield* session.environment({ sessionID: child.id, variables: { SESSION_ENV: "child" } })
      const locations = yield* LocationServiceMap.Service
      yield* Effect.acquireRelease(locations.contextEffect(location), () => locations.invalidate(location))
      closed.length = 0

      yield* session.remove(parent.id)

      expect((yield* session.list()).data).toEqual([])
      expect(closed).toEqual([parent.id, child.id, grandchild.id])
      const environments = yield* SessionEnvironment.Service
      expect(yield* environments.get(parent.id)).toBeUndefined()
      expect(yield* environments.get(child.id)).toBeUndefined()
      expect(yield* Effect.result(session.get(parent.id))).toMatchObject({ _tag: "Failure" })
      expect(yield* Effect.result(session.get(child.id))).toMatchObject({ _tag: "Failure" })
      expect(yield* Effect.result(session.get(grandchild.id))).toMatchObject({ _tag: "Failure" })
    }),
  )

  it.live("removes unloaded sessions and children without initializing an instance", () =>
    Effect.gen(function* () {
      const temporary = yield* tmpdirScoped()
      const sessions = yield* Session.Service
      const locations = yield* LocationServiceMap.Service
      const parent = yield* sessions.create({
        location: Location.Ref.make({ directory: AbsolutePath.make(temporary.path) }),
      })
      const child = yield* sessions.create({ parentID: parent.id })
      closed.length = 0
      expect(Array.from(yield* RcMap.keys(locations.rcMap))).toEqual([])

      yield* sessions.remove(parent.id)

      expect(closed).toEqual([parent.id, child.id])
      expect(transportScopes.size).toBe(1)
      expect(Array.from(yield* RcMap.keys(locations.rcMap))).toEqual([])
      expect((yield* sessions.list()).data).toEqual([])
    }),
  )

  it.effect("fails when the session does not exist", () =>
    Effect.gen(function* () {
      const session = yield* Session.Service
      const sessionID = Session.ID.make("ses_missing")

      expect(yield* Effect.result(session.remove(sessionID))).toMatchObject({
        _tag: "Failure",
        failure: { _tag: "Session.NotFoundError", sessionID },
      })
    }),
  )
})
