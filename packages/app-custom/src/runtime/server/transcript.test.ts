import { expect, test } from "bun:test"
import type { OpenCodeEvent, SessionMessagesResponse } from "@opencode/client/promise"
import { createApiForServer } from "./api"
import { omitEventMedia, withLeanTranscript } from "./transcript"

const sessionID = "ses_transcript"
const endpointPage: SessionMessagesResponse = { data: [], cursor: { next: "endpoint-next" } }
const pluginPage: SessionMessagesResponse = { data: [], cursor: { next: "plugin-next" } }

function setup(rpc: Response) {
  const requests: Array<{ path: string; body?: unknown }> = []
  const api = createApiForServer({
    server: { url: "https://server.example:4096" },
    fetch: (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : input)
      const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined
      requests.push({ path: `${url.pathname}${url.search}`, ...(body === undefined ? {} : { body }) })
      return url.pathname.startsWith("/api/rpc/") ? rpc.clone() : Response.json(endpointPage)
    }) as typeof fetch,
  })
  return { api: withLeanTranscript(api), requests }
}

test("reads transcript pages through the plugin and falls back to the endpoint without it", async () => {
  const lean = setup(Response.json({ output: pluginPage }))
  expect(await lean.api.message.list({ sessionID, limit: 20, order: "desc" })).toEqual(pluginPage)
  expect(lean.requests).toEqual([
    { path: "/api/rpc/custom.transcript/list", body: { input: { sessionID, limit: 20, order: "desc" } } },
  ])

  const missing = setup(
    Response.json(
      { _tag: "RpcError", type: "rpc.unavailable", message: "RPC is unavailable: custom.transcript" },
      { status: 400 },
    ),
  )
  expect(await missing.api.message.list({ sessionID, cursor: "older" })).toEqual(endpointPage)
  expect(missing.requests.map((request) => request.path)).toEqual([
    "/api/rpc/custom.transcript/list",
    `/api/session/${sessionID}/message?cursor=older`,
  ])

  const filtered = setup(Response.json({ output: pluginPage }))
  expect(await filtered.api.message.list({ sessionID, type: "location-switched", limit: 200 })).toEqual(endpointPage)
  expect(filtered.requests.map((request) => request.path)).toEqual([
    `/api/session/${sessionID}/message?limit=200&type=location-switched`,
  ])
})

test("empties inline media from live tool results only", () => {
  const envelope = { id: "evt_tool", created: 1, durable: { aggregateID: sessionID, seq: 1, version: 2 as const } }
  const tool = { sessionID, assistantMessageID: "msg_tool", id: "tool_read", executed: true }
  const inline = { type: "file" as const, uri: "data:image/png;base64,iVBORw0KGgo=", mime: "image/png", name: "a.png" }
  const linked = { type: "file" as const, uri: "file:///repo/a.png", mime: "image/png" }
  const success: OpenCodeEvent = {
    ...envelope,
    type: "session.tool.success",
    data: { ...tool, content: [{ type: "text", text: "Image read successfully" }, inline, linked] },
  }
  const failed: OpenCodeEvent = {
    ...envelope,
    type: "session.tool.failed",
    data: { ...tool, error: { type: "unknown", message: "Timed out" }, content: [inline] },
  }
  const text: OpenCodeEvent = {
    ...envelope,
    type: "session.text.delta",
    data: { sessionID, assistantMessageID: "msg_tool", ordinal: 0, delta: "data:image/png;base64,iVBORw0KGgo=" },
  }

  expect(omitEventMedia(success)).toEqual({
    ...success,
    data: {
      ...tool,
      content: [
        { type: "text", text: "Image read successfully" },
        { ...inline, uri: "data:image/png;base64," },
        linked,
      ],
    },
  })
  expect(omitEventMedia(failed)).toEqual({
    ...failed,
    data: { ...tool, error: failed.data.error, content: [{ ...inline, uri: "data:image/png;base64," }] },
  })
  expect(omitEventMedia(text)).toBe(text)
})
