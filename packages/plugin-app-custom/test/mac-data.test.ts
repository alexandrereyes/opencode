import { afterAll, describe, expect, test } from "bun:test"
import { chmod, mkdtemp, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Agent } from "@opencode/schema/agent"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Tool } from "@opencode/schema/tool"
import { Effect, Exit, Schema } from "effect"
import { Input, Output, registerTools, toolName } from "../src/mac-data"
import { agentID } from "../src/master"

const directory = await mkdtemp(path.join(os.tmpdir(), "mac-data-"))
const helper = path.join(directory, "helper")
// The simulated helper records its JSON argument and prints a canned reply.
await Bun.write(helper, `#!/bin/sh\nprintf '%s' "$1" > "$0.request"\ncat "$0.reply"\nexit "$(cat "$0.code")"\n`)
await chmod(helper, 0o755)
afterAll(() => rm(directory, { recursive: true, force: true }))

function tool(executable = helper) {
  const tools: Tool.Info[] = []
  registerTools(
    {
      namespace: () => {},
      list: () => [],
      get: () => undefined,
      add: (tool) => {
        tools.push(tool)
      },
      update: () => {},
      remove: () => {},
    },
    executable,
  )
  return tools[0]
}

async function run(input: unknown, reply: unknown, options: { code?: number; agent?: Agent.ID; raw?: string } = {}) {
  await Bun.write(`${helper}.reply`, options.raw ?? JSON.stringify(reply))
  await Bun.write(`${helper}.code`, String(options.code ?? 0))
  const exit = await Effect.runPromiseExit(
    tool().execute(input, {
      agent: options.agent ?? agentID,
      sessionID: Session.ID.make("ses_master"),
      messageID: SessionMessage.ID.make("msg_master"),
      id: Tool.CallID.make("call"),
      progress: () => Effect.void,
    }),
  )
  return { exit, request: await Bun.file(`${helper}.request`).json() }
}

function failure(exit: Exit.Exit<unknown, unknown>) {
  if (Exit.isSuccess(exit)) throw new Error("Expected failure")
  const error = exit.cause.reasons.find((reason) => reason._tag === "Fail")?.error
  if (!(error instanceof Tool.Error)) throw new Error("Expected Tool.Error")
  return error
}

function success(exit: Exit.Exit<unknown, unknown>) {
  if (Exit.isFailure(exit)) throw new Error(String(exit.cause))
  return Schema.decodeUnknownSync(Schema.Struct({ output: Output, content: Schema.String }))(exit.value)
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

function calendar(events: unknown[]) {
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

test("only Mestra gets the tool, in the mac namespace", () => {
  expect(tool().name).toBe(toolName)
  expect(tool().options).toEqual({ namespace: "mac", codemode: true, agents: [agentID] })
})

test("input rejects malformed dates, limits and contact searches", () => {
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
    expect(() => Schema.decodeUnknownSync(Input)(input)).toThrow()
  expect(
    Schema.decodeUnknownSync(Input)({ source: "calendar", from: "2026-10-26", to: "2026-10-27T18:30-03:00" }),
  ).toBeDefined()
})

// The simulated helper is a POSIX shell script.
describe.skipIf(process.platform === "win32")("helper", () => {
  test("other agents are rejected before the helper runs", async () => {
    await rm(`${helper}.request`, { force: true })
    await Bun.write(`${helper}.reply`, "{}")
    const exit = await Effect.runPromiseExit(
      tool().execute(
        { source: "status" },
        {
          agent: Agent.ID.make("build"),
          sessionID: Session.ID.make("ses_build"),
          messageID: SessionMessage.ID.make("msg_build"),
          id: Tool.CallID.make("call"),
          progress: () => Effect.void,
        },
      ),
    )
    expect(failure(exit).message).toContain("Only the Mestra")
    expect(await Bun.file(`${helper}.request`).exists()).toBe(false)
  })

  test("calendar forwards typed parameters and applies the item limit", async () => {
    const input = {
      source: "calendar",
      from: "2026-10-26",
      to: "2026-10-26",
      calendars: ["Casa"],
      query: "x",
      limit: 2,
    }
    const result = await run(input, calendar([event(1), event(2), event(3)]))
    expect(result.request).toEqual(input)
    expect(success(result.exit).output).toMatchObject({
      source: "calendar",
      timeZone: "America/Sao_Paulo",
      total: 3,
      truncated: true,
      events: [{ title: "Event 1" }, { title: "Event 2" }],
    })
  })

  test("serialized lists stay under the character ceiling", async () => {
    const events = Array.from({ length: 40 }, (_, index) => event(index, "n".repeat(1000)))
    const result = success((await run({ source: "calendar" }, calendar(events))).exit)
    if (result.output.source !== "calendar") throw new Error("Expected calendar")
    expect(result.output.truncated).toBe(true)
    expect(result.output.events.length).toBeLessThan(40)
    expect(JSON.stringify(result.output.events).length).toBeLessThanOrEqual(20_000)
  })

  test("reminders, contacts and status keep their formats", async () => {
    const reminders = {
      source: "reminders",
      timeZone: "America/Sao_Paulo",
      status: "pending",
      availableLists: ["Compras"],
      total: 1,
      reminders: [{ title: "Leite", list: "Compras", completed: false, due: "2026-10-26", priority: "high" }],
    } as const
    expect(success((await run({ source: "reminders" }, reminders)).exit).output).toEqual({
      ...reminders,
      truncated: false,
    })
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
    const found = success((await run({ source: "contacts", query: "Ana" }, contacts)).exit).output
    expect(found).toMatchObject({ total: 12, truncated: true })
    if (found.source !== "contacts") throw new Error("Expected contacts")
    expect(found.contacts).toHaveLength(10)
    const status = {
      source: "status",
      permissions: { calendar: "granted", reminders: "denied", contacts: "notDetermined" },
    } as const
    expect(success((await run({ source: "status" }, status)).exit).output).toEqual(status)
  })

  test("permission errors explain where to grant access", async () => {
    const denied = failure(
      (await run({ source: "calendar" }, { error: "denied", source: "calendar", message: "macOS denied access" })).exit,
    )
    expect(denied.message).toContain("Privacy & Security → Calendars")
    expect(denied.message).toContain("Privacidade e Segurança → Calendários")
    expect(denied.message).toContain("Full Access")
    expect(denied.metadata).toEqual({ reason: "denied", source: "calendar" })
    const pending = failure(
      (await run({ source: "contacts", query: "Ana" }, { error: "notDetermined", source: "contacts", message: "" }))
        .exit,
    )
    expect(pending.message).toContain("click Allow")
    const invalid = failure(
      (await run({ source: "calendar" }, { error: "invalid", source: "calendar", message: "No calendar named X" }))
        .exit,
    )
    expect(invalid.message).toBe("No calendar named X")
  })

  test("malformed output, failed exits and a missing helper fail clearly", async () => {
    expect(failure((await run({ source: "status" }, undefined, { raw: "boom", code: 3 })).exit).message).toBe(
      "The Mac data helper failed (exit 3): boom",
    )
    const missing = await Effect.runPromiseExit(
      tool(path.join(directory, "missing")).execute(
        { source: "status" },
        {
          agent: agentID,
          sessionID: Session.ID.make("ses_master"),
          messageID: SessionMessage.ID.make("msg_master"),
          id: Tool.CallID.make("call"),
          progress: () => Effect.void,
        },
      ),
    )
    expect(failure(missing).message).toContain("Could not run the OpenCode Mac Data helper")
  })
})

// Opt-in: OPENCODE_MAC_DATA_HELPER=<built OpenCode Mac Data.app/Contents/MacOS/opencode-mac-data> reads real data.
test.skipIf(!process.env.OPENCODE_MAC_DATA_HELPER)(
  "real helper reports permissions and reads granted sources",
  async () => {
    const real = tool(process.env.OPENCODE_MAC_DATA_HELPER)
    const context = {
      agent: agentID,
      sessionID: Session.ID.make("ses_master"),
      messageID: SessionMessage.ID.make("msg_master"),
      id: Tool.CallID.make("call"),
      progress: () => Effect.void,
    }
    const status = success(await Effect.runPromiseExit(real.execute({ source: "status" }, context))).output
    if (status.source !== "status") throw new Error("Expected status")
    for (const [source, input] of [
      ["calendar", { source: "calendar" }],
      ["reminders", { source: "reminders" }],
      ["contacts", { source: "contacts", query: "a", limit: 1 }],
    ] as const) {
      if (status.permissions[source] !== "granted") continue
      expect(success(await Effect.runPromiseExit(real.execute(input, context))).output.source).toBe(source)
    }
  },
  { timeout: 30_000 },
)
