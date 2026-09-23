import { describe, expect, test } from "bun:test"
import { OpenCode } from "@opencode/client/promise"
import { btwQuestion, createBtwState } from "./state"

function setup() {
  const requests: { request: Request; reply: (response: Response) => void }[] = []
  const api = OpenCode.make({
    baseUrl: "http://btw.test",
    fetch: Object.assign(
      (resource: RequestInfo | URL, init?: RequestInit) =>
        new Promise<Response>((reply) => {
          requests.push({ request: new Request(resource, init), reply })
        }),
      { preconnect() {} },
    ),
  })
  return { requests, btw: createBtwState("session-1", api.session.generate) }
}

describe("side questions", () => {
  test("recognizes only the exact slash command and retains multiline arguments", () => {
    expect(btwQuestion(" /btw ")).toBe("")
    expect(btwQuestion("/btw why?\nand how?")).toBe("why?\nand how?")
    expect(btwQuestion("/btwhatever question")).toBeUndefined()
    expect(btwQuestion("text /btw")).toBeUndefined()
  })

  test("uses the real generate client without history writes, preserving an answer through collapse", async () => {
    const { btw, requests } = setup()
    expect(btw.submitSlash("/btw")).toBe(true)
    expect(requests).toHaveLength(0)
    const pending = btw.ask("  Why this design?  ")
    expect(btw.state.pending).toBe(true)
    expect(requests).toHaveLength(1)
    expect(requests[0].request.url).toBe("http://btw.test/api/session/session-1/generate")
    const body = await requests[0].request.json()
    expect(Object.keys(body)).toEqual(["prompt"])
    expect(body.prompt).toContain("Do not call any tools")
    expect(body.prompt).toEndWith("Why this design?")
    btw.collapse()
    requests[0].reply(Response.json({ data: { text: " **Because** it is simpler. " } }))
    await pending
    expect(btw.state).toMatchObject({
      collapsed: true,
      pending: false,
      error: false,
      answer: "**Because** it is simpler.",
    })
    btw.open()
    expect(btw.state.collapsed).toBe(false)
    expect(btw.state.answer).toBe("**Because** it is simpler.")
    btw.dismiss()
    expect(btw.state).toMatchObject({ open: false, answer: "", draft: "" })
  })

  test("displays errors and retries; treats an empty tool-only answer as an error", async () => {
    const { btw, requests } = setup()
    const failed = btw.ask("question")
    requests[0].reply(new Response("unavailable", { status: 503 }))
    await failed
    expect(btw.state).toMatchObject({ pending: false, error: true, question: "question" })
    const empty = btw.ask(btw.state.question)
    requests[1].reply(Response.json({ data: { text: " " } }))
    await empty
    expect(btw.state.error).toBe(true)
    const success = btw.ask()
    requests[2].reply(Response.json({ data: { text: "answer" } }))
    await success
    expect(btw.state).toMatchObject({ pending: false, error: false, answer: "answer" })
  })

  test("dismissal and a replacement question invalidate in-flight responses", async () => {
    const { btw, requests } = setup()
    const first = btw.ask("first")
    const second = btw.ask("second")
    expect(requests[0].request.signal.aborted).toBe(true)
    requests[0].reply(Response.json({ data: { text: "stale" } }))
    await first
    expect(btw.state).toMatchObject({ question: "second", pending: true, answer: "" })
    btw.dismiss()
    expect(requests[1].request.signal.aborted).toBe(true)
    requests[1].reply(Response.json({ data: { text: "dismissed" } }))
    await second
    expect(btw.state).toMatchObject({ open: false, answer: "", pending: false })
  })

  test("each session has independent transient presentation", async () => {
    const first = setup()
    const second = setup()
    const pending = first.btw.ask("first")
    second.btw.open("second")
    first.requests[0].reply(Response.json({ data: { text: "answer" } }))
    await pending
    expect(second.btw.state).toMatchObject({ draft: "second", answer: "", pending: false })
  })
})
