import { expect } from "bun:test"
import { Effect, Fiber, Schema } from "effect"
import { TestClock } from "effect/testing"
import type { ToolEditor } from "@opencode/plugin/effect/tool"
import { Agent } from "@opencode/schema/agent"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Tool } from "@opencode/schema/tool"
import { it } from "../../core/test/lib/effect"
import { configureMaster, instructions, limits, makeDevice, registerTools } from "../src/device"
import { Device } from "../src/device/rpc"
import { agentID, configureAgent } from "../src/master"

/** One plugin storage shared by every Location's instance, as the host's KV namespace is. */
function storage() {
  const values = new Map<string, Schema.Json>()
  return {
    values,
    get: (key: string) => Effect.sync(() => values.get(key)),
    update: <A>(key: string, update: (current: Schema.Json | undefined) => readonly [Schema.Json, A]) =>
      Effect.sync(() => {
        const [next, result] = update(values.get(key))
        values.set(key, next)
        return result
      }),
  }
}

function instance(shared: ReturnType<typeof storage>, directory: string) {
  const emitted: Device.Request[] = []
  const device = makeDevice({
    storage: shared,
    directory,
    emit: (request) => Effect.sync(() => void emitted.push(request)),
  })
  return { device, emitted }
}

const iphone: Device.Attach = {
  deviceID: "iphone-14",
  name: "iPhone de teste",
  model: "iPhone14,7",
  system: "iOS 27.0.1",
  sources: [
    { source: "device", enabled: true, authorization: "authorized" },
    { source: "health", enabled: true, authorization: "requested" },
    { source: "photos", enabled: false, authorization: "notDetermined" },
  ],
}

const pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

it.effect("presence attached through one Location is visible to another and expires with its lease", () =>
  Effect.gen(function* () {
    const shared = storage()
    const chats = instance(shared, "/chats")
    const repository = instance(shared, "/repo")
    expect((yield* repository.device.status()).online).toBe(false)
    expect(yield* chats.device.attach(iphone)).toEqual({ leaseSeconds: limits.leaseSeconds })
    const status = yield* repository.device.status()
    expect(status.online).toBe(true)
    expect(status.devices[0]).toMatchObject({ deviceID: "iphone-14", name: "iPhone de teste", online: true })
    yield* TestClock.adjust(`${limits.leaseSeconds + 1} seconds`)
    const expired = yield* repository.device.status()
    expect(expired.online).toBe(false)
    expect(expired.devices[0]?.lastSeen).toBe(0)
  }),
)

it.effect("offline and disabled answer immediately, without emitting a request", () =>
  Effect.gen(function* () {
    const shared = storage()
    const node = instance(shared, "/chats")
    expect((yield* node.device.query({ source: "device" })).output).toMatchObject({
      source: "device",
      status: "offline",
      note: "No iPhone has connected to this server yet.",
    })
    yield* node.device.attach(iphone)
    yield* TestClock.adjust("10 seconds")
    yield* node.device.detach({ deviceID: "iphone-14" })
    expect((yield* node.device.query({ source: "device" })).output).toEqual({
      source: "device",
      status: "offline",
      device: "iPhone de teste",
      lastSeen: 10_000,
      note: "The OpenCode app is not running on the iPhone (closed, suspended or disconnected).",
    })
    yield* node.device.attach(iphone)
    expect((yield* node.device.query({ source: "photos", limit: 3 })).output.status).toBe("disabled")
    expect(node.emitted).toEqual([])
  }),
)

it.effect("a request reaches the app with its Location and resolves with the routed answer and images", () =>
  Effect.gen(function* () {
    const shared = storage()
    const chats = instance(shared, "/chats")
    const repository = instance(shared, "/repo")
    yield* repository.device.attach(iphone)
    const call = yield* chats.device
      .query({ source: "health", metrics: ["steps"], from: "2026-10-19", to: "2026-10-25", timeoutSeconds: 10 })
      .pipe(Effect.forkChild)
    yield* Effect.yieldNow
    const request = chats.emitted[0]!
    expect(request).toMatchObject({
      deviceID: "iphone-14",
      directory: "/chats",
      deadline: 10_000,
      query: { source: "health", metrics: ["steps"], from: "2026-10-19", to: "2026-10-25" },
    })
    expect("timeoutSeconds" in request.query).toBe(false)
    // The other Location's instance does not own the request; the app answers through the request's directory.
    expect(
      yield* repository.device.respond({
        deviceID: "iphone-14",
        requestID: request.requestID,
        answer: { status: "ok" },
      }),
    ).toEqual({ accepted: false })
    expect(
      yield* chats.device.respond({ deviceID: "other", requestID: request.requestID, answer: { status: "ok" } }),
    ).toEqual({ accepted: false })
    expect(
      yield* chats.device.respond({
        deviceID: "iphone-14",
        requestID: request.requestID,
        answer: {
          status: "ok",
          collectedAt: 5,
          data: { days: [{ day: "2026-10-25", steps: 8123 }] },
          files: [{ name: "IMG_1.jpg", mime: "image/png", data: pixel }],
        },
      }),
    ).toEqual({ accepted: true })
    const result = yield* Fiber.join(call)
    expect(result.output).toEqual({
      source: "health",
      device: "iPhone de teste",
      status: "ok",
      collectedAt: 5,
      data: { days: [{ day: "2026-10-25", steps: 8123 }] },
      files: [{ name: "IMG_1.jpg", mime: "image/png" }],
    })
    expect(result.images).toHaveLength(1)
    expect(chats.device.pending.size).toBe(0)
    expect(
      yield* chats.device.respond({ deviceID: "iphone-14", requestID: request.requestID, answer: { status: "ok" } }),
    ).toEqual({ accepted: false })
  }),
)

it.effect("an unanswered request times out after the default 5 seconds and is forgotten", () =>
  Effect.gen(function* () {
    const node = instance(storage(), "/chats")
    yield* node.device.attach(iphone)
    const call = yield* node.device.query({ source: "device" }).pipe(Effect.forkChild)
    yield* TestClock.adjust("4999 millis")
    expect(node.device.pending.size).toBe(1)
    yield* TestClock.adjust("1 millis")
    expect((yield* Fiber.join(call)).output).toMatchObject({
      source: "device",
      status: "timeout",
      note: "The iPhone did not answer within 5 seconds.",
    })
    expect(node.device.pending.size).toBe(0)
  }),
)

it.effect("invalid ranges fail before contacting the iPhone", () =>
  Effect.gen(function* () {
    const node = instance(storage(), "/chats")
    yield* node.device.attach(iphone)
    const errors = yield* Effect.forEach(
      [
        { source: "health" as const, from: "2026-01-01", to: "2026-10-25" },
        { source: "motion" as const, from: "2026-10-01", to: "2026-10-25" },
        { source: "health" as const, from: "2026-10-25", to: "2026-10-20" },
      ],
      (input) => node.device.query(input).pipe(Effect.flip),
    )
    expect(errors.map((error) => error.message)).toEqual([
      "health queries cover at most 90 days",
      "motion history covers at most the last 7 days",
      "from must not be after to",
    ])
    expect(node.emitted).toEqual([])
  }),
)

it.effect("the tools are direct, Mestra-only, and attach images as tool file content", () =>
  Effect.gen(function* () {
    const shared = storage()
    const node = instance(shared, "/chats")
    const tools = new Map<string, Tool.Info>()
    registerTools({ add: (tool: Tool.Info) => void tools.set(tool.name, tool) } as unknown as ToolEditor, node.device)
    expect([...tools.keys()]).toEqual(["iphone_status", "iphone_query"])
    for (const tool of tools.values()) expect(tool.options).toEqual({ codemode: false, agents: [agentID] })
    const context = (agent: string): Tool.Context => ({
      sessionID: Session.ID.make("ses_test"),
      agent: Agent.ID.make(agent),
      messageID: SessionMessage.ID.make("msg_test"),
      id: Tool.CallID.make("call_test"),
      progress: () => Effect.void,
    })
    const query = tools.get("iphone_query")!
    const denied = yield* query.execute({ source: "device" }, context("build")).pipe(Effect.flip)
    expect(denied.message).toBe("Only the Mestra agent may read iPhone data")
    yield* node.device.attach(iphone)
    const call = yield* query.execute({ source: "device" }, context(agentID)).pipe(Effect.forkChild)
    yield* Effect.yieldNow
    yield* node.device.respond({
      deviceID: "iphone-14",
      requestID: node.emitted[0]!.requestID,
      answer: { status: "ok", data: { battery: 0.8 }, files: [{ name: "a.png", mime: "image/png", data: pixel }] },
    })
    const result = yield* Fiber.join(call)
    expect(result.content).toEqual([
      {
        type: "text",
        text: JSON.stringify({
          source: "device",
          device: "iPhone de teste",
          status: "ok",
          data: { battery: 0.8 },
          files: [{ name: "a.png", mime: "image/png" }],
        }),
      },
      { type: "file", uri: `data:image/png;base64,${pixel}`, mime: "image/png", name: "a.png" },
    ])
  }),
)

it.effect("the Mestra instruction is appended once after the master's own configuration", () =>
  Effect.sync(() => {
    const agents = new Map<string, { system?: string }>()
    const editor = {
      update: (id: string, update: (agent: { system?: string }) => void) => {
        const agent = agents.get(id) ?? {}
        update(agent)
        agents.set(id, agent)
      },
    }
    configureAgent(editor as never)
    configureMaster(editor as never)
    configureMaster(editor as never)
    const system = agents.get(agentID)?.system ?? ""
    expect(system.endsWith(`\n${instructions}`)).toBe(true)
    expect(system.split(instructions)).toHaveLength(2)
  }),
)
