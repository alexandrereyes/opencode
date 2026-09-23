import { describe, expect, test } from "bun:test"
import { OpenCode } from "@opencode/client/promise"
import { btwQuestion, createBtwSessions, createBtwState } from "./state"

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
  return {
    requests,
    btw: createBtwState("session-1", api.session.generate),
    sessions: createBtwSessions(api.session.generate),
  }
}

describe("side questions", () => {
  test("rich draft survives cancellation/navigation while generate receives expanded text", async () => {
    const input = setup()
    const btw = input.sessions("rich")
    btw.draft("#why", [
      { type: "snippet", id: "why", name: "why", content: "#why", expansion: "Explain this", start: 0, end: 4 },
    ])
    const pending = btw.ask("Explain this", true)
    expect(btw.state.draft).toBe("#why")
    expect(btw.state.draftPrompt?.[0].type).toBe("snippet")
    btw.cancel()
    input.requests[0].reply(Response.json({ data: { text: "discarded" } }))
    await pending
    expect(input.sessions("rich").state.draftPrompt?.[0].type).toBe("snippet")
    const retry = btw.ask("Explain this", true)
    input.requests[1].reply(Response.json({ data: { text: "answer" } }))
    await retry
    expect(btw.state.draft).toBe("")
    expect(btw.state.draftPrompt).toBeUndefined()
  })
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

  test("follow-ups include bounded local context and retain only the last five pairs", async () => {
    const input = setup()
    for (const index of [0, 1, 2, 3, 4, 5]) {
      const pending = input.btw.ask(`question ${index}`)
      const body = await input.requests[index].request.json()
      if (index) expect(body.prompt).toContain(`answer ${index - 1}`)
      expect(body.prompt).toEndWith(`question ${index}`)
      input.requests[index].reply(Response.json({ data: { text: `answer ${index}` } }))
      await pending
    }
    expect(input.btw.state.history.map((entry) => entry.question)).toEqual([
      "question 1",
      "question 2",
      "question 3",
      "question 4",
      "question 5",
    ])
    expect(input.btw.state.draft).toBe("")
    input.btw.dismiss()
    expect(input.btw.state.history).toEqual([])
  })

  test("session-keyed state survives navigation, cancels pending work, and isolates servers", async () => {
    const input = setup()
    const first = input.sessions("first")
    const completed = first.ask("remember me")
    input.requests[0].reply(Response.json({ data: { text: "remembered" } }))
    await completed
    const pending = first.ask("cancel on leave")
    first.cancel()
    expect(input.requests[1].request.signal.aborted).toBe(true)
    input.sessions("second").open("other draft")
    input.requests[1].reply(Response.json({ data: { text: "too late" } }))
    await pending
    expect(input.sessions("first")).toBe(first)
    expect(first.state.history).toEqual([{ question: "remember me", answer: "remembered" }])
    expect(first.state).toMatchObject({ cancelled: true, pending: false, draft: "cancel on leave" })
    expect(input.sessions("second").state.history).toEqual([])
    expect(setup().sessions("first").state.history).toEqual([])
  })

  test("completion preserves edits made while waiting and excludes failed answers from context", async () => {
    const input = setup()
    const pending = input.btw.ask("one")
    input.btw.draft("next draft")
    input.requests[0].reply(Response.json({ data: { text: "one answer" } }))
    await pending
    expect(input.btw.state.draft).toBe("next draft")
    const failed = input.btw.ask("failed question")
    input.requests[1].reply(new Response("error", { status: 503 }))
    await failed
    expect(input.btw.state.history).toEqual([{ question: "one", answer: "one answer" }])
  })
})
