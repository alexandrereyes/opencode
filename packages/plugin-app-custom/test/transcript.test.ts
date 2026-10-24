import { expect, test } from "bun:test"
import { Effect, Schema } from "effect"
import { SessionMessage } from "@opencode/schema/session-message"
import { Session } from "@opencode/schema/session"
import { list, skills } from "../src/transcript"
import { Transcript } from "../src/transcript/rpc"

const sessionID = Session.ID.make("ses_transcript")
const image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
const decode = Schema.decodeUnknownSync(SessionMessage.Info)

const user = decode({
  id: "msg_user",
  type: "user",
  time: { created: 1 },
  text: "Compare these",
  files: [{ data: image, mime: "image/png", name: "pasted.png", source: { type: "inline" } }],
})

const assistant = decode({
  id: "msg_assistant",
  type: "assistant",
  time: { created: 2 },
  agent: "build",
  model: { providerID: "test", id: "test" },
  content: [
    { type: "text", text: "Reading" },
    {
      type: "tool",
      id: "tool_read",
      name: "read",
      time: { created: 2 },
      state: {
        status: "completed",
        input: { path: "/repo/chart.png" },
        content: [
          { type: "text", text: "Image read successfully" },
          { type: "file", uri: `data:image/png;base64,${image}`, mime: "image/png", name: "/repo/chart.png" },
          { type: "file", uri: "file:///repo/notes.md", mime: "text/markdown" },
        ],
        metadata: { truncated: false },
      },
    },
    {
      type: "tool",
      id: "tool_screenshot",
      name: "screenshot",
      time: { created: 3 },
      state: {
        status: "error",
        input: {},
        error: { type: "unknown", message: "Timed out" },
        content: [{ type: "file", uri: `data:image/jpeg;base64,${image}`, mime: "image/jpeg" }],
      },
    },
  ],
})

test("lists the requested page with inline tool-result media emptied and everything else intact", async () => {
  const requests: unknown[] = []
  const page = await Effect.runPromise(
    list(
      {
        list: (input) =>
          Effect.sync(() => {
            requests.push(input)
            return { data: [user, assistant], cursor: { previous: "cursor-previous", next: undefined } }
          }),
      },
      { sessionID, cursor: "cursor-current", limit: 20 },
    ),
  )

  expect(requests).toEqual([{ sessionID, cursor: "cursor-current", limit: 20 }])
  expect(page.cursor).toEqual({ previous: "cursor-previous" })
  expect(page.data[0]).toEqual(Schema.encodeSync(SessionMessage.Info)(user))
  const [text, read, screenshot] = page.data[1]?.type === "assistant" ? page.data[1].content : []
  expect(text).toEqual({ type: "text", text: "Reading" })
  expect(read?.type === "tool" && read.state.status === "completed" ? read.state.content : undefined).toEqual([
    { type: "text", text: "Image read successfully" },
    { type: "file", uri: "data:image/png;base64,", mime: "image/png", name: "/repo/chart.png" },
    { type: "file", uri: "file:///repo/notes.md", mime: "text/markdown" },
  ])
  expect(
    screenshot?.type === "tool" && screenshot.state.status === "error" ? screenshot.state.content : undefined,
  ).toEqual([{ type: "file", uri: "data:image/jpeg;base64,", mime: "image/jpeg" }])
  expect(await Transcript.Definition.methods.list.output["~standard"].validate(page)).toEqual({ value: page })
})

test("lists skills loaded into the session in first-load order, across every page", async () => {
  const skillMessage = (id: string, created: number, skill: string, name: string) =>
    decode({ id, type: "skill", time: { created }, skill, name, text: "instructions" })
  const tool = (id: string, created: number, status: "completed" | "error", skill: string) =>
    status === "completed"
      ? {
          type: "tool",
          id,
          name: "skill",
          time: { created },
          state: {
            status,
            input: { id: skill },
            content: [{ type: "text", text: "loaded" }],
            metadata: { name: `${skill} name` },
          },
        }
      : {
          type: "tool",
          id,
          name: "skill",
          time: { created },
          state: { status, input: { id: skill }, error: { type: "unknown", message: "denied" } },
        }
  const pages: Record<string, SessionMessage.Info[][]> = {
    skill: [
      Array.from({ length: 200 }, (_, index) => skillMessage(`msg_s${index}`, 10 + index, "review", "Review")),
      [skillMessage("msg_late", 900, "late", "Late")],
    ],
    user: [
      [
        user,
        decode({
          id: "msg_user_skill",
          type: "user",
          time: { created: 5 },
          text: "$effect",
          skills: [{ id: "effect", name: "Effect", text: "body" }],
        }),
      ],
    ],
    assistant: [
      [
        assistant,
        decode({
          id: "msg_tools",
          type: "assistant",
          time: { created: 3 },
          agent: "build",
          model: { providerID: "test", id: "test" },
          content: [
            tool("tool_ok", 4, "completed", "docx"),
            tool("tool_denied", 2, "error", "pdf"),
            tool("tool_dup", 950, "completed", "effect"),
          ],
        }),
      ],
    ],
  }
  const requests: Array<{ type?: string; cursor?: string; order?: string }> = []
  const loaded = await Effect.runPromise(
    skills(
      {
        list: (input) =>
          Effect.sync(() => {
            requests.push({ type: input.type, cursor: input.cursor, order: input.order })
            const index = input.cursor ? Number(input.cursor.split(":")[1]) : 0
            return { data: pages[input.type ?? ""]?.[index] ?? [], cursor: { next: `${input.type}:${index + 1}` } }
          }),
      },
      sessionID,
    ),
  )

  expect(loaded).toEqual({
    data: [
      { id: "docx", name: "docx name" },
      { id: "effect", name: "Effect" },
      { id: "review", name: "Review" },
      { id: "late", name: "Late" },
    ],
  })
  expect(requests.filter((request) => request.type === "skill")).toEqual([
    { type: "skill", cursor: undefined, order: "asc" },
    { type: "skill", cursor: "skill:1", order: undefined },
  ])
  expect(requests.filter((request) => request.type !== "skill")).toHaveLength(2)
  expect(await Transcript.Definition.methods.skills.output["~standard"].validate(loaded)).toEqual({ value: loaded })
})
