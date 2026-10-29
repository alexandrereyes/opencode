import { expect } from "bun:test"
import { Effect, Exit, Fiber, Schema } from "effect"
import { TestClock } from "effect/testing"
import type { ToolEditor } from "@opencode/plugin/effect/tool"
import { Agent } from "@opencode/schema/agent"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Tool } from "@opencode/schema/tool"
import { it } from "../../core/test/lib/effect"
import { limits, makeMac, Output, registerTools, toolName } from "../src/mac-data"
import { MacData } from "../src/mac-data/rpc"

/** One plugin storage shared by every Location's instance, as the host's KV namespace is. */
function storage() {
  const values = new Map<string, Schema.Json>()
  return {
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
  const emitted: MacData.Request[] = []
  const mac = makeMac({ storage: shared, directory, emit: (request) => Effect.sync(() => void emitted.push(request)) })
  const tools: Tool.Info[] = []
  registerTools({ namespace: () => {}, add: (tool: Tool.Info) => void tools.push(tool) } as unknown as ToolEditor, mac)
  return { mac, emitted, tool: tools[0]! }
}

const mac: MacData.Attach = { deviceID: "mac-1", name: "MacBook de teste", model: "Mac16,5", system: "macOS 27.0" }

// Any agent may read; a regular primary agent stands in for all of them.
const build: Tool.Context = {
  agent: Agent.ID.make("build"),
  sessionID: Session.ID.make("ses_build"),
  messageID: SessionMessage.ID.make("msg_build"),
  id: Tool.CallID.make("call"),
  progress: () => Effect.void,
}

/** Runs the tool through one Location while the Mac attached through another answers `reply`. */
function ask(input: unknown, reply: Schema.Json) {
  return Effect.gen(function* () {
    const shared = storage()
    const chats = instance(shared, "/chats")
    yield* instance(shared, "/repo").mac.attach(mac)
    const call = yield* chats.tool.execute(input, build).pipe(Effect.exit, Effect.forkChild)
    yield* Effect.yieldNow
    const request = chats.emitted[0]!
    expect(yield* chats.mac.respond({ deviceID: mac.deviceID, requestID: request.requestID, answer: reply })).toEqual({
      accepted: true,
    })
    return { request, exit: yield* Fiber.join(call) }
  })
}

function failure(exit: Exit.Exit<unknown, unknown>) {
  if (Exit.isSuccess(exit)) throw new Error("Expected failure")
  const error = exit.cause.reasons.find((reason) => reason._tag === "Fail")?.error
  if (!(error instanceof Tool.Error)) throw new Error("Expected Tool.Error")
  return error
}

function success(exit: Exit.Exit<unknown, unknown>) {
  if (Exit.isFailure(exit)) throw new Error(String(exit.cause))
  return Schema.decodeUnknownSync(Schema.Struct({ output: Output, content: Schema.String }))(exit.value).output
}

function event(index: number, notes = "") {
  return {
    title: `Event ${index}`,
    start: "2026-10-26T09:00:00-03:00",
    end: "2026-10-26T10:00:00-03:00",
    allDay: false,
    calendar: "Casa",
    ...(notes ? { notes } : {}),
  }
}

function calendar(events: Schema.Json[]) {
  return {
    source: "calendar",
    timeZone: "America/Sao_Paulo",
    from: "2026-10-26T00:00:00-03:00",
    to: "2026-10-27T00:00:00-03:00",
    availableCalendars: ["Casa", "Trabalho"],
    total: events.length,
    events,
  }
}

it.effect("every agent gets the tool, in the mac namespace", () =>
  Effect.sync(() => {
    const tool = instance(storage(), "/chats").tool
    expect(tool.name).toBe(toolName)
    expect(tool.options).toEqual({ namespace: "mac", codemode: true })
  }),
)

it.effect("input rejects malformed dates, limits and contact searches", () =>
  Effect.sync(() => {
    for (const input of [
      { source: "calendar", from: "26/10/2026" },
      { source: "calendar", to: "2026-10-26T9:00" },
      { source: "calendar", limit: 201 },
      { source: "calendar", calendars: Array.from({ length: 21 }, (_, index) => `c${index}`) },
      { source: "reminders", status: "open" },
      { source: "contacts" },
      { source: "contacts", query: "" },
      { source: "contacts", query: "Ana", limit: 51 },
      { source: "photos" },
    ])
      expect(() => Schema.decodeUnknownSync(MacData.Query)(input)).toThrow()
    expect(
      Schema.decodeUnknownSync(MacData.Query)({ source: "calendar", from: "2026-10-26", to: "2026-10-27T18:30-03:00" }),
    ).toBeDefined()
  }),
)

it.effect("without an online Mac the tool fails at once, without emitting a request", () =>
  Effect.gen(function* () {
    const node = instance(storage(), "/chats")
    const never = failure(yield* node.tool.execute({ source: "status" }, build).pipe(Effect.exit))
    expect(never.message).toContain("has never connected")
    expect(never.metadata).toEqual({ reason: "offline" })
    yield* node.mac.attach(mac)
    yield* TestClock.adjust("10 seconds")
    yield* node.mac.detach({ deviceID: mac.deviceID })
    expect(failure(yield* node.tool.execute({ source: "status" }, build).pipe(Effect.exit)).message).toBe(
      "The OpenCode app is not running on MacBook de teste (closed or disconnected since 1970-01-01T00:00:10.000Z). Ask Alexandre to open it, then retry.",
    )
    yield* node.mac.attach(mac)
    yield* TestClock.adjust(`${limits.leaseSeconds + 1} seconds`)
    expect(failure(yield* node.tool.execute({ source: "status" }, build).pipe(Effect.exit)).metadata).toEqual({
      reason: "offline",
    })
    expect(node.emitted).toEqual([])
  }),
)

it.effect("a request carries the query and its Location; only that instance and Mac can answer it", () =>
  Effect.gen(function* () {
    const shared = storage()
    const chats = instance(shared, "/chats")
    const repository = instance(shared, "/repo")
    yield* repository.mac.attach(mac)
    const input = {
      source: "calendar",
      from: "2026-10-26",
      to: "2026-10-26",
      calendars: ["Casa"],
      query: "x",
      limit: 2,
    }
    const call = yield* chats.tool.execute(input, build).pipe(Effect.forkChild)
    yield* Effect.yieldNow
    const request = chats.emitted[0]!
    expect(request).toMatchObject({
      deviceID: "mac-1",
      directory: "/chats",
      deadline: limits.timeoutSeconds * 1000,
      query: input,
    })
    const answer = calendar([event(1), event(2), event(3)])
    expect(yield* repository.mac.respond({ deviceID: "mac-1", requestID: request.requestID, answer })).toEqual({
      accepted: false,
    })
    expect(yield* chats.mac.respond({ deviceID: "other", requestID: request.requestID, answer })).toEqual({
      accepted: false,
    })
    expect(yield* chats.mac.respond({ deviceID: "mac-1", requestID: request.requestID, answer })).toEqual({
      accepted: true,
    })
    expect((yield* Fiber.join(call)).output).toMatchObject({
      source: "calendar",
      timeZone: "America/Sao_Paulo",
      total: 3,
      truncated: true,
      events: [{ title: "Event 1" }, { title: "Event 2" }],
    })
    expect(chats.mac.pending.size).toBe(0)
  }),
)

it.effect("an unanswered request times out and is forgotten", () =>
  Effect.gen(function* () {
    const node = instance(storage(), "/chats")
    yield* node.mac.attach(mac)
    const call = yield* node.tool.execute({ source: "status" }, build).pipe(Effect.exit, Effect.forkChild)
    yield* Effect.yieldNow
    yield* TestClock.adjust(`${limits.timeoutSeconds * 1000 - 1} millis`)
    expect(node.mac.pending.size).toBe(1)
    yield* TestClock.adjust("1 millis")
    const error = failure(yield* Fiber.join(call))
    expect(error.message).toBe(
      `The OpenCode app on MacBook de teste did not answer within ${limits.timeoutSeconds} seconds.`,
    )
    expect(error.metadata).toEqual({ reason: "timeout" })
    expect(node.mac.pending.size).toBe(0)
  }),
)

it.effect("serialized lists stay under the character ceiling", () =>
  Effect.gen(function* () {
    const events = Array.from({ length: 40 }, (_, index) => event(index, "n".repeat(1000)))
    const output = success((yield* ask({ source: "calendar" }, calendar(events))).exit)
    if (output.source !== "calendar") throw new Error("Expected calendar")
    expect(output.truncated).toBe(true)
    expect(output.events.length).toBeLessThan(40)
    expect(JSON.stringify(output.events).length).toBeLessThanOrEqual(20_000)
  }),
)

it.effect("reminders, contacts and status keep their formats", () =>
  Effect.gen(function* () {
    const reminders = {
      source: "reminders",
      timeZone: "America/Sao_Paulo",
      status: "pending",
      availableLists: ["Compras"],
      total: 1,
      reminders: [{ title: "Leite", list: "Compras", completed: false, due: "2026-10-26", priority: "high" }],
    } as const
    expect(success((yield* ask({ source: "reminders" }, reminders)).exit)).toEqual({ ...reminders, truncated: false })
    const contacts = {
      source: "contacts",
      timeZone: "America/Sao_Paulo",
      total: 12,
      contacts: Array.from({ length: 12 }, (_, index) => ({
        name: `Ana ${index}`,
        phones: [{ label: "celular", value: "+55 11 90000-0000" }],
        emails: [],
        birthday: "--03-14",
      })),
    }
    const found = success((yield* ask({ source: "contacts", query: "Ana" }, contacts)).exit)
    expect(found).toMatchObject({ total: 12, truncated: true })
    if (found.source !== "contacts") throw new Error("Expected contacts")
    expect(found.contacts).toHaveLength(10)
    const status = {
      source: "status",
      permissions: { calendar: "granted", reminders: "denied", contacts: "notDetermined" },
      enabled: { calendar: true, reminders: true, contacts: false },
    } as const
    expect(success((yield* ask({ source: "status" }, status)).exit)).toEqual(status)
  }),
)

it.effect("app failures explain what Alexandre has to do", () =>
  Effect.gen(function* () {
    const denied = failure(
      (yield* ask({ source: "calendar" }, { error: "denied", source: "calendar", message: "macOS denied access" }))
        .exit,
    )
    expect(denied.message).toContain('enable "OpenCode" in System Settings → Privacy & Security → Calendars')
    expect(denied.message).toContain("Privacidade e Segurança → Calendários")
    expect(denied.message).toContain("Full Access")
    expect(denied.metadata).toEqual({ reason: "denied", source: "calendar" })
    const pending = failure(
      (yield* ask({ source: "contacts", query: "Ana" }, { error: "notDetermined", source: "contacts", message: "" }))
        .exit,
    )
    expect(pending.message).toContain("click Allow")
    const disabled = failure(
      (yield* ask({ source: "reminders" }, { error: "disabled", source: "reminders", message: "" })).exit,
    )
    expect(disabled.message).toContain("Ajustes → Dados do Mac")
    const invalid = failure(
      (yield* ask({ source: "calendar" }, { error: "invalid", source: "calendar", message: "No calendar named X" }))
        .exit,
    )
    expect(invalid.message).toBe("No calendar named X")
    const malformed = failure((yield* ask({ source: "status" }, { source: "status" })).exit)
    expect(malformed.message).toStartWith("The OpenCode app on MacBook de teste answered in an unexpected format")
  }),
)
