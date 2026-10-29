import { expect } from "bun:test"
import { Context, Deferred, Effect, Fiber, Layer } from "effect"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { Bus } from "@opencode/core/bus"
import { Form } from "@opencode/core/form"
import { Job } from "@opencode/core/job"
import { KV } from "@opencode/core/kv"
import { Location } from "@opencode/core/location"
import { LocationServiceMap } from "@opencode/core/location-service-map"
import { Permission } from "@opencode/core/permission"
import { PersistentPty } from "@opencode/core/persistent-pty"
import { Plugin } from "@opencode/core/plugin"
import { PluginHost } from "@opencode/core/plugin/host"
import { Session } from "@opencode/core/session"
import { SessionFamily } from "@opencode/core/session/family"
import { SessionRunCoordinator } from "@opencode/core/session/run-coordinator"
import { AbsolutePath } from "@opencode/core/schema"
import { Worktree } from "@opencode/core/worktree"
import { Global } from "@opencode/util/global"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { tempGlobalLayer } from "../fixture/global"
import { offlineModels } from "../fixture/models"
import { tmpdirScoped } from "../fixture/tmpdir"
import { testEffect } from "../lib/effect"
import { OfflinePluginTestLayer } from "./fixture"

testEffect(OfflinePluginTestLayer).live(
  "plugin active snapshots map real coordinator ownership without starting execution",
  () =>
    Effect.gen(function* () {
      const plugins = yield* Plugin.Service
      const sessions = yield* Session.Service
      const entered = yield* Deferred.make<void>()
      const release = yield* Deferred.make<void>()
      const coordinator = yield* SessionRunCoordinator.make<Session.ID, never>({
        drain: () => Deferred.succeed(entered, undefined).pipe(Effect.andThen(Deferred.await(release))),
      })
      const ctx = yield* PluginHost.make(plugins).pipe(
        Effect.provideService(Session.Service, { ...sessions, active: coordinator.active }),
      )
      const session = yield* ctx.session.create({ title: "Active boundary" })
      expect(yield* ctx.session.active()).toEqual({})
      const running = yield* coordinator.run(session.id).pipe(Effect.forkChild)
      yield* Deferred.await(entered)
      const snapshot = yield* ctx.session.active()
      expect(snapshot).toEqual({ [session.id]: { type: "running" } })
      yield* Deferred.succeed(release, undefined)
      yield* Fiber.join(running)
      expect(yield* ctx.session.active()).toEqual({})
      expect(snapshot).toEqual({ [session.id]: { type: "running" } })
    }),
)

testEffect(Layer.empty).live(
  "plugin replies resolve the target Location and preserve native form and permission ownership",
  () =>
    Effect.gen(function* () {
      const layer = AppNodeBuilder.build(
        LayerNode.group([
          LocationServiceMap.node,
          Bus.node,
          Job.node,
          KV.node,
          Session.node,
          SessionFamily.node,
          PersistentPty.node,
          Worktree.node,
        ]),
        [Global.node.replace(tempGlobalLayer), offlineModels],
      )
      yield* Effect.gen(function* () {
        const local = yield* tmpdirScoped()
        const remote = yield* tmpdirScoped()
        const locations = yield* LocationServiceMap.Service
        const localServices = yield* locations.contextEffect(
          Location.Ref.make({ directory: AbsolutePath.make(local.path) }),
        )
        const remoteServices = yield* locations.contextEffect(
          Location.Ref.make({ directory: AbsolutePath.make(remote.path) }),
        )
        const ctx = yield* PluginHost.make({ list: () => Effect.succeed([]) }).pipe(Effect.provide(localServices))
        const target = yield* ctx.session.create({
          location: { directory: AbsolutePath.make(remote.path) },
          permissions: [{ action: "reply-test", resource: "*", effect: "ask" }],
        })
        const other = yield* ctx.session.create({ location: { directory: AbsolutePath.make(remote.path) } })
        const forms = Context.get(remoteServices, Form.Service)
        const permissions = Context.get(remoteServices, Permission.Service)
        const form = yield* forms.create({
          sessionID: target.id,
          title: "Choice",
          fields: [{ key: "choice", type: "string", required: true, options: [{ value: "ok", label: "OK" }] }],
        })
        expect(
          yield* ctx.session.form
            .reply({ sessionID: other.id, formID: form.id, answer: { choice: "ok" } })
            .pipe(Effect.flip),
        ).toMatchObject({ _tag: "Form.NotFoundError" })
        expect(
          yield* ctx.session.form
            .reply({ sessionID: target.id, formID: form.id, answer: { choice: "invalid" } })
            .pipe(Effect.flip),
        ).toMatchObject({ _tag: "Form.InvalidAnswerError" })
        expect(yield* forms.state(form.id)).toEqual({ status: "pending" })
        yield* ctx.session.form.reply({ sessionID: target.id, formID: form.id, answer: { choice: "ok" } })
        expect(yield* forms.state(form.id)).toEqual({ status: "answered", answer: { choice: "ok" } })
        expect(
          yield* ctx.session.form
            .reply({ sessionID: target.id, formID: form.id, answer: { choice: "ok" } })
            .pipe(Effect.flip),
        ).toMatchObject({ _tag: "Form.AlreadySettledError" })
        const permission = yield* permissions.ask({
          sessionID: target.id,
          action: "reply-test",
          resources: [remote.path],
        })
        expect(permission.effect).toBe("ask")
        expect(
          yield* ctx.permission
            .reply({ sessionID: other.id, requestID: permission.id, decision: "once" })
            .pipe(Effect.flip),
        ).toBeInstanceOf(Error)
        expect(yield* permissions.get(permission.id)).toMatchObject({ sessionID: target.id })
        yield* ctx.permission.reply({ sessionID: target.id, requestID: permission.id, decision: "once" })
        expect(yield* permissions.get(permission.id)).toBeUndefined()
        expect(
          yield* ctx.session.form
            .reply({ sessionID: Session.ID.create(), formID: form.id, answer: {} })
            .pipe(Effect.flip),
        ).toMatchObject({ _tag: "Session.NotFoundError" })
      }).pipe(Effect.provide(layer))
    }),
)
