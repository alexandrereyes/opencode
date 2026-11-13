import { expect, test } from "bun:test"
import { Effect, Layer, Schema } from "effect"
import { CodeModeTool } from "@opencode/core/codemode/tool"
import { Permission } from "@opencode/core/permission"
import { definition, execute } from "@opencode/core/tool/runtime"
import { GrepTool } from "@opencode/core/tool/plugin/grep"
import { ShellTool } from "@opencode/core/tool/plugin/shell"
import { Tool } from "@opencode/schema/tool"
import { describeTools, fields } from "../src/tool-descriptions/index"

/** The three tools as the core registers them, with an executor that only reports the input it received. */
const received: unknown[] = []
const echo = (name: string, input: Tool.Info["input"]): Tool.Info => ({
  name,
  description: name,
  input,
  execute: (value) => Effect.sync(() => void received.push(value)).pipe(Effect.as({ content: "ok" })),
})
const tools = {
  shell: echo("shell", ShellTool.Input),
  grep: echo("grep", GrepTool.Input),
  // Code Mode's own tool, whose input the core builds; its runtime is not under test here.
  execute: {
    ...CodeModeTool.create(
      { tools: new Map() },
      () => Effect.die("unused"),
      Effect.runSync(Permission.Service.pipe(Effect.provide(Layer.mock(Permission.Service, {})))),
    ),
    output: undefined,
    execute: echo("execute", Schema.Struct({ code: Schema.String })).execute,
  },
}
/** What the session's `context` hook receives: a deep copy of each definition's JSON schema. */
const request = () =>
  Object.fromEntries(
    Object.entries(tools).map(([name, tool]) => {
      const made = definition(tool as Tool.Info)
      return [name, { description: made.description, input: JSON.parse(JSON.stringify(made.inputSchema)) }]
    }),
  )

test("the model's schema gets an optional description right after each tool's main argument", () => {
  const before = request()
  const after = request()
  describeTools(after)
  for (const [name, field] of Object.entries(fields)) {
    const schema = after[name]!.input as {
      properties: Record<string, { type: string; description: string }>
      required?: string[]
      additionalProperties?: unknown
    }
    const keys = Object.keys(schema.properties)
    expect(keys[keys.indexOf(field.after) + 1]).toBe("description")
    expect(schema.properties.description).toEqual({ type: "string", description: field.text })
    // Required of the model, and nothing else changes: the other arguments, no extra keys allowed.
    const original = before[name]!.input as typeof schema
    expect(schema.required).toEqual([...(original.required ?? []), "description"])
    expect(schema.additionalProperties).toEqual(original.additionalProperties)
    expect({ ...schema.properties, description: undefined }).toEqual({ ...original.properties, description: undefined })
  }
  // The rules each text asks for.
  for (const field of Object.values(fields)) expect(field.text).toContain("de 2 a 6 palavras")
})

test("every request gets the same bytes, a schema with its own description is left alone, others are untouched", () => {
  const first = request()
  const second = request()
  describeTools(first)
  describeTools(second)
  expect(JSON.stringify(second)).toBe(JSON.stringify(first))
  // Applied twice (another hook, a later request on the same copy): still once.
  const again = JSON.parse(JSON.stringify(first))
  describeTools(again)
  expect(JSON.stringify(again)).toBe(JSON.stringify(first))
  const own = {
    shell: {
      description: "",
      input: { type: "object", properties: { command: {}, description: { type: "string", description: "upstream" } } },
    },
    read: { description: "", input: { type: "object", properties: { path: {} } } },
  }
  describeTools(own)
  expect(own.shell.input.properties.description.description).toBe("upstream")
  expect(Object.keys(own.read.input.properties)).toEqual(["path"])
})

test("the tools accept a call with the description and run without it, and one without it as well", async () => {
  const context: Tool.Context = {
    sessionID: "ses_test" as never,
    agent: "build" as never,
    messageID: "msg_test" as never,
    id: Tool.CallID.make("call_test"),
    progress: () => Effect.void,
  }
  received.length = 0
  const description = "Conferindo o estado do repositório"
  await Effect.runPromise(execute(tools.shell, { command: "git status", description }, context))
  await Effect.runPromise(execute(tools.grep, { pattern: "TODO", description }, context))
  await Effect.runPromise(execute(tools.execute as Tool.Info, { code: "return 1", description }, context))
  // Required only of the model: a call without it still runs.
  await Effect.runPromise(execute(tools.shell, { command: "pwd" }, context))
  expect(received).toEqual([{ command: "git status" }, { pattern: "TODO" }, { code: "return 1" }, { command: "pwd" }])
})
