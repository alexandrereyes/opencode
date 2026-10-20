import { expect, test } from "bun:test"
import { Effect, Schema } from "effect"
import { SessionMessage } from "@opencode/schema/session-message"
import { Session } from "@opencode/schema/session"
import { list } from "../src/transcript"
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
  expect(screenshot?.type === "tool" && screenshot.state.status === "error" ? screenshot.state.content : undefined).toEqual(
    [{ type: "file", uri: "data:image/jpeg;base64,", mime: "image/jpeg" }],
  )
  expect(await Transcript.Definition.methods.list.output["~standard"].validate(page)).toEqual({ value: page })
})
