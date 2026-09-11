import { expect } from "bun:test"
import { Effect, Deferred } from "effect"
import { AppNodeBuilder } from "../src/effect/app-node-builder"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Job } from "../src/job"
import { KV } from "../src/kv"
import { JobMaintenance } from "../src/job-maintenance"
import { Maintenance } from "../src/maintenance"
import { SessionMessage } from "../src/session/message"
import { SessionSchema } from "../src/session/schema"
import { testEffect } from "./lib/effect"

const it = testEffect(AppNodeBuilder.build(LayerNode.group([Job.node, KV.node])))
const recovery: Job.Recovery = {
  kind: "shell",
  sessionID: SessionSchema.ID.make("ses_owner"),
  shellID: "sh_missing",
  command: "test",
}

it.live("missing shell and cancelled child markers survive a maintenance decision for startup recovery", () =>
  Effect.gen(function* () {
    const jobs = yield* Job.Service
    const kv = yield* KV.Service
    const shell = { id: "sh_missing", notificationID: SessionMessage.ID.create(), recovery, status: "running" as const }
    const child = {
      id: "ses_child",
      notificationID: SessionMessage.ID.create(),
      recovery: {
        kind: "subagent" as const,
        parentSessionID: recovery.sessionID,
        childSessionID: SessionSchema.ID.make("ses_child"),
        agent: "general",
        description: "work",
      },
      status: "cancelled" as const,
    }
    yield* kv.set(`job.background/${shell.notificationID}`, shell)
    yield* kv.set(`job.background/${child.notificationID}`, child)
    expect(yield* JobMaintenance.pending({ jobs, activity: () => Effect.succeed("missing") })).toBe(false)
    expect(yield* jobs.pendingBackground).toEqual(expect.arrayContaining([shell, child]))
  }),
)

it.live("genuine shell or subagent activity remains blocking even without a parent execution", () =>
  Effect.gen(function* () {
    const jobs = yield* Job.Service
    const kv = yield* KV.Service
    const notificationID = SessionMessage.ID.create()
    yield* kv.set(`job.background/${notificationID}`, { id: "sh_missing", notificationID, recovery, status: "running" })
    expect(yield* JobMaintenance.pending({ jobs, activity: () => Effect.succeed("running") })).toBe(true)
    const done = yield* Deferred.make<string>()
    const live = yield* jobs.start({
      id: "live-child",
      type: "subagent",
      recovery: {
        kind: "subagent",
        parentSessionID: recovery.sessionID,
        childSessionID: SessionSchema.ID.make("ses_live"),
        agent: "general",
        description: "work",
      },
      run: Deferred.await(done),
    })
    yield* jobs.background(live.id)
    expect(Maintenance.process.lease()).toBeUndefined()
    expect(yield* JobMaintenance.pending({ jobs, activity: () => Effect.succeed("missing") })).toBe(true)
    yield* jobs.cancel(live.id)
  }),
)

it.live("completed notification is not discarded or treated as orphan activity", () =>
  Effect.gen(function* () {
    const jobs = yield* Job.Service
    const kv = yield* KV.Service
    const notificationID = SessionMessage.ID.create()
    const record = { id: "sh_finished", notificationID, recovery, status: "completed", output: "valuable result" }
    yield* kv.set(`job.background/${notificationID}`, record)
    expect(
      yield* JobMaintenance.pending({ jobs, activity: () => Effect.die("should not probe completed output") }),
    ).toBe(true)
    expect(yield* kv.get(`job.background/${notificationID}`)).toEqual(record)
  }),
)

it.live("unknown shell ownership fails closed rather than consuming a marker", () =>
  Effect.gen(function* () {
    const jobs = yield* Job.Service
    const kv = yield* KV.Service
    const notificationID = SessionMessage.ID.create()
    yield* kv.set(`job.background/${notificationID}`, { id: "sh_unknown", notificationID, recovery, status: "running" })
    const result = yield* JobMaintenance.pending({
      jobs,
      activity: () => Effect.fail(new Error("location unavailable")),
    }).pipe(Effect.result)
    expect(result._tag).toBe("Failure")
    expect((yield* jobs.pendingBackground).length).toBe(1)
  }),
)
