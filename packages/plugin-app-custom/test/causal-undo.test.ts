import { describe, expect, test } from "bun:test"
import { CausalRevert } from "@opencode/plugin/session-revert"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { plan } from "../src/causal-undo/index.js"

const root = Session.ID.make("ses_root")
const child = Session.ID.make("ses_child")
const grandchild = Session.ID.make("ses_grandchild")
const rootBoundary = SessionMessage.ID.make("msg_root_boundary")
const rootAssistant = SessionMessage.ID.make("msg_root_assistant")
const childInput = SessionMessage.ID.make("msg_child_input")
const childAssistant = SessionMessage.ID.make("msg_child_assistant")
const childPending = SessionMessage.ID.make("msg_child_pending")
const grandchildInput = SessionMessage.ID.make("msg_grandchild_input")

describe("causal undo planner", () => {
  test("reexports the canonical Schema contracts", async () => {
    const schema = await import("@opencode/schema/causal-revert")
    expect(CausalRevert.Plan).toBe(schema.CausalRevert.Plan)
    expect(CausalRevert.Facts).toBe(schema.CausalRevert.Facts)
  })

  test("selects delivered and pending descendants without side effects", () => {
    const facts = CausalRevert.Facts.make({
      boundary: { sessionID: root, messageID: rootBoundary, seq: 10 },
      sessions: [
        { sessionID: root, location: { directory: AbsolutePath.make("/root") }, firstMessageSeq: 1 },
        {
          sessionID: child,
          parentID: root,
          location: { directory: AbsolutePath.make("/root") },
          firstMessageSeq: 20,
          firstInboxSeq: 25,
        },
        {
          sessionID: grandchild,
          parentID: child,
          location: { directory: AbsolutePath.make("/other") },
          firstMessageSeq: 40,
        },
      ],
      assignments: [
        {
          inputID: childInput,
          parentSessionID: root,
          childSessionID: child,
          assignedSeq: 12,
          origin: { parentSessionID: root, messageID: rootAssistant, toolCallID: "child" },
          input: { state: "message", seq: 20 },
        },
        {
          inputID: childPending,
          parentSessionID: root,
          childSessionID: child,
          assignedSeq: 13,
          origin: { parentSessionID: root, messageID: rootAssistant, toolCallID: "pending" },
          input: { state: "inbox", seq: 25 },
        },
        {
          inputID: grandchildInput,
          parentSessionID: child,
          childSessionID: grandchild,
          assignedSeq: 22,
          origin: { parentSessionID: child, messageID: childAssistant, toolCallID: "grandchild" },
          input: { state: "message", seq: 40 },
        },
      ],
      tools: [
        {
          sessionID: root,
          seq: 11,
          origin: { parentSessionID: root, messageID: rootAssistant, toolCallID: "shell" },
        },
        {
          sessionID: child,
          seq: 21,
          origin: { parentSessionID: child, messageID: childAssistant, toolCallID: "grandchild" },
        },
      ],
    })

    const before = structuredClone(facts)
    expect(plan(facts)).toEqual({
      participants: [
        { sessionID: child, messageID: childInput, pendingIDs: [childPending] },
        { sessionID: grandchild, messageID: grandchildInput, pendingIDs: [] },
      ],
      origins: [
        { parentSessionID: child, messageID: childAssistant, toolCallID: "grandchild" },
        { parentSessionID: root, messageID: rootAssistant, toolCallID: "child" },
        { parentSessionID: root, messageID: rootAssistant, toolCallID: "shell" },
      ],
      pendingOrigins: [{ parentSessionID: root, messageID: rootAssistant, toolCallID: "pending" }],
      discardedSessionIDs: [child, grandchild],
    })
    expect(facts).toEqual(before)
  })

  test("returns a root-only plan when no causal facts cross the boundary", () => {
    expect(
      plan(
        CausalRevert.Facts.make({
          boundary: { sessionID: root, messageID: rootBoundary, seq: 10 },
          sessions: [{ sessionID: root, location: { directory: AbsolutePath.make("/root") } }],
          assignments: [],
          tools: [],
        }),
      ),
    ).toEqual({ participants: [], origins: [], pendingOrigins: [], discardedSessionIDs: [] })
  })
})
