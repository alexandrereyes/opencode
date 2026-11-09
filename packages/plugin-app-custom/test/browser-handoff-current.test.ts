import { describe, expect, test } from "bun:test"
import { createHash } from "node:crypto"
import { readdirSync } from "node:fs"
import path from "node:path"
import { callerSession, makeCurrentSessions, pick, type Observed } from "../src/browser-handoff/current"

const S = "ses_e4476e95fffeVMVHE1ii5pLvt4"
const mine = callerSession(S)
const done = (tool: string, input: object, output?: unknown): Observed => ({
  tool,
  sessionID: S,
  input,
  status: "completed",
  ...(output === undefined ? {} : { result: { output } }),
})
const failed = (tool: string, input: object): Observed => ({ tool, sessionID: S, input, status: "error" })

test("an agent that never chose a browse session acts on browse's default for its OpenCode session", () => {
  expect(mine).toBe(`mcp-${createHash("sha256").update(S).digest("hex").slice(0, 8)}`)
  expect(mine).toMatch(/^mcp-[0-9a-f]{8}$/)
  expect(callerSession("ses_other")).not.toBe(mine)
  const current = makeCurrentSessions()
  expect(current.candidates(S)).toEqual([mine])
  // Calls that change nothing: a bare execute, other tools, other servers.
  current.observe(done("browse_execute", { code: "1" }, { session: mine, value: 1 }))
  current.observe(done("browse_status", {}, { currentSession: mine }))
  current.observe(done("shell", { session: "x" }))
  expect(current.candidates(S)).toEqual([mine])
})

test("the calls that make a session current leave it, and the default, as the candidates", () => {
  const current = makeCurrentSessions()
  current.observe(done("browse_session_new", { allowedOrigins: ["a.example"] }, { session: { id: "nova" } }))
  expect(current.candidates(S)).toEqual([mine, "nova"])
  current.observe(done("browse.session_use", { id: "outra" }, { currentSession: "outra" }))
  expect(current.candidates(S)).toEqual([mine, "outra"])
  current.observe(done("browse_execute", { session: "login", code: "1" }, { session: "login" }))
  expect(current.candidates(S)).toEqual([mine, "login"])
  current.observe(done("browse_session_adopt", {}, { session: { id: "adotada" }, adoptedUrl: "https://a.example" }))
  expect(current.candidates(S)).toEqual([mine, "adotada"])
  current.observe(done("browse_session_reset", { id: "zerada" }))
  expect(current.candidates(S)).toEqual([mine, "zerada"])
  // Deleting it leaves a random id browse tells only in its answer.
  current.observe(done("browse_session_delete", { id: "zerada" }, { deleted: true, currentSession: "mcp-1a2b3c4d" }))
  expect(current.candidates(S)).toEqual([mine, "mcp-1a2b3c4d"])
  // Without that answer, only the default stays.
  current.observe(done("browse_session_use", { id: "x" }))
  current.observe(done("browse_session_delete", { id: "x" }))
  expect(current.candidates(S)).toEqual([mine])
  // Each OpenCode session has its own.
  expect(current.candidates("ses_other")).toEqual([callerSession("ses_other")])
})

test("a failed call that may have made a session current adds it; one that cannot, changes nothing", () => {
  const current = makeCurrentSessions()
  current.observe(done("browse_session_use", { id: "a" }, { currentSession: "a" }))
  // browse makes an execute's session current once the relay answered, even with the script's error.
  current.observe(failed("browse_execute", { session: "b", code: "throw 1" }))
  expect(current.candidates(S)).toEqual([mine, "a", "b"])
  current.observe(failed("browse_session_use", { id: "c" }))
  current.observe(failed("browse_session_new", { id: "d" }))
  current.observe(failed("browse_session_delete", { id: "a" }))
  expect(current.candidates(S)).toEqual([mine, "a", "b"])
  // A bare call that succeeded says which one it ran in.
  current.observe(done("browse_execute", { code: "1" }, { session: "b" }))
  expect(current.candidates(S)).toEqual([mine, "b"])
})

test("the relay picks the one candidate an execute touched since the call began, never one of several", () => {
  const since = 1_000
  const sessions = [
    { id: mine, updatedAt: 1_200 },
    { id: "login", updatedAt: 900 },
    { id: "alheia", updatedAt: 1_500 },
  ]
  expect(pick([mine, "login"], sessions, since)).toBe(mine)
  // Another agent's session, touched meanwhile, is never a candidate.
  expect(pick(["login"], sessions, since)).toBeUndefined()
  // Two candidates touched: either could hold the handoff.
  expect(pick([mine, "alheia"], sessions, since)).toBeUndefined()
  // Not started yet (or never created).
  expect(pick(["nova"], sessions, since)).toBeUndefined()
  expect(pick([mine], sessions, 1_201)).toBeUndefined()
})

describe("browse keeps a current session per OpenCode session", () => {
  const dist = process.env.OPENCODE_BROWSE_PACKAGE ?? "/opt/homebrew/lib/node_modules/@opencode/browse"
  const files = (() => {
    try {
      return readdirSync(path.join(dist, "dist")).filter((file) => file.startsWith("mcp-") && file.endsWith(".mjs"))
    } catch {
      return []
    }
  })()
  // `callerSession` and the calls `makeCurrentSessions` follows are browse 0.0.16's; a browse that changes them fails here.
  test.skipIf(files.length === 0)("the installed MCP server derives and moves it as followed here", async () => {
    const version = (await Bun.file(path.join(dist, "package.json")).json()).version
    const text = (await Promise.all(files.map((file) => Bun.file(path.join(dist, "dist", file)).text()))).join("\n")
    const expected = [
      'var opencodeSessionMetaKey = "ai.opencode/sessionID";',
      'return `mcp-${createHash("sha256").update(opencodeSessionId).digest("hex").slice(0, 8)}`;',
      "const sessionId = args.session ?? caller.id;",
      "ctx.establishCurrentSession(caller, sessionId);",
      "ctx.establishCurrentSession(yield* ctx.caller, session.id);",
      "ctx.establishCurrentSession(caller, id);",
      "ctx.establishCurrentSession(yield* ctx.caller, id);",
      "return { ...result, currentSession: caller.id };",
    ]
    const missing = expected.filter((line) => !text.includes(line))
    expect({ version, missing }).toEqual({ version, missing: [] })
    // No other call moves it.
    expect({ version, moves: text.split("ctx.establishCurrentSession(").length - 1 }).toEqual({ version, moves: 5 })
  })
})
