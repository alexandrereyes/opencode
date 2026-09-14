import { describe, expect, test } from "bun:test"
import type { SessionInfo, SessionMessageInfo, SessionMessageUser } from "@opencode/client/promise"
import { createMemoryComposerState } from "@/composer/state"
import { createSessionRevertActions, stageSessionRevert } from "./revert"

const user = (id: string): SessionMessageUser => ({ id, type: "user", text: id, time: { created: 0 } })
const timedUser = (id: string, created: number): SessionMessageUser => ({
  id,
  type: "user",
  text: id,
  time: { created },
})
const session = (id: string, parentID?: string, reverted = false) =>
  ({ id, parentID, revert: reverted ? { messageID: `${id}-boundary` } : undefined }) as SessionInfo

function setupRevert(messages = [user("message-a"), user("message-b"), user("message-c")]) {
  const composer = createMemoryComposerState()
  let history = messages
  const staged: string[] = []
  const gates: ReturnType<typeof Promise.withResolvers<void>>[] = []
  let serverBoundary: string | undefined
  const staging: (() => void)[] = []
  const actions = createSessionRevertActions(
    {
      session: {
        identity: { params: { id: "session-1" } },
        history: { userMessages: () => history },
        data: { revertMessageID: () => serverBoundary },
      },
      setActiveMessage() {},
    },
    {
      prompt: composer,
      directory: () => "/repo",
      failed: () => undefined,
      pending: { list: () => [] },
      api: {
        interrupt: async () => ({ interrupted: true }),
        wait: async () => undefined,
        revert: {
          stage: async (input) => {
            staged.push(input.messageID)
            const gate = Promise.withResolvers<void>()
            gates.push(gate)
            staging.shift()?.()
            await gate.promise
            serverBoundary = input.messageID
            return { messageID: input.messageID }
          },
          clear: async () => {
            serverBoundary = undefined
          },
        },
        inbox: {
          list: async () => [],
          cancel: async () => undefined,
        },
      },
    },
  )
  return {
    actions,
    composer,
    staged,
    gates,
    nextStage: () => new Promise<void>((resolve) => staging.push(resolve)),
    commit: (messages: SessionMessageUser[]) => {
      history = messages
      serverBoundary = undefined
    },
  }
}

describe("session revert requests", () => {
  test("waits for interruption settlement before staging the revert", async () => {
    const interrupt = Promise.withResolvers<void>()
    const wait = Promise.withResolvers<void>()
    const stage = Promise.withResolvers<void>()
    const waiting = Promise.withResolvers<void>()
    const staging = Promise.withResolvers<void>()
    const calls: string[] = []
    const request = stageSessionRevert(
      {
        interrupt: async () => {
          calls.push("interrupt")
          await interrupt.promise
          return { interrupted: true }
        },
        wait: async () => {
          calls.push("wait")
          waiting.resolve()
          await wait.promise
        },
        revert: {
          stage: async () => {
            calls.push("stage")
            staging.resolve()
            await stage.promise
            return { messageID: "message-1" }
          },
        },
      },
      { sessionID: "session-1", messageID: "message-1" },
    )

    expect(calls).toEqual(["interrupt"])
    interrupt.resolve()
    await waiting.promise
    expect(calls).toEqual(["interrupt", "wait"])
    wait.resolve()
    await staging.promise
    expect(calls).toEqual(["interrupt", "wait", "stage"])

    stage.resolve()
    await request
  })

  test("does not stage when waiting for settlement fails", async () => {
    const calls: string[] = []
    const request = stageSessionRevert(
      {
        interrupt: async () => {
          calls.push("interrupt")
          return { interrupted: true }
        },
        wait: async () => {
          calls.push("wait")
          throw new Error("settlement failed")
        },
        revert: {
          stage: async () => {
            calls.push("stage")
            return { messageID: "message-1" }
          },
        },
      },
      { sessionID: "session-1", messageID: "message-1" },
    )

    await expect(request).rejects.toThrow("settlement failed")
    expect(calls).toEqual(["interrupt", "wait"])
  })

  test("projects the selected message before the staged request completes", async () => {
    const fixture = setupRevert()
    const staging = fixture.nextStage()
    const request = fixture.actions.to("message-b")

    expect(fixture.composer.current()).toEqual([{ type: "text", content: "message-b", start: 0, end: 9 }])
    await staging
    expect(fixture.staged).toEqual(["message-b"])

    fixture.gates[0]?.resolve()
    await request
  })

  test("ends a queued edit before projecting the optimistic prompt", async () => {
    const fixture = setupRevert()
    let editing = true
    fixture.composer.revert.onProject(() => {
      editing = false
      fixture.composer.set([{ type: "text", content: "stashed draft", start: 0, end: 13 }])
    })
    const staging = fixture.nextStage()
    const request = fixture.actions.undo()

    expect(editing).toBe(false)
    expect(fixture.composer.current()).toEqual([{ type: "text", content: "message-c", start: 0, end: 9 }])
    expect(fixture.composer.revert.pending()).toBe(true)
    await staging
    fixture.gates[0]?.resolve()
    await request
  })

  test("serializes two pending undos and a partial redo using the local effective boundary", async () => {
    const fixture = setupRevert()
    const firstStage = fixture.nextStage()
    const first = fixture.actions.undo()
    expect(fixture.composer.current()).toEqual([{ type: "text", content: "message-c", start: 0, end: 9 }])
    const second = fixture.actions.undo()
    expect(fixture.composer.current()).toEqual([{ type: "text", content: "message-b", start: 0, end: 9 }])
    const redo = fixture.actions.redo()

    expect(fixture.composer.current()).toEqual([{ type: "text", content: "message-c", start: 0, end: 9 }])
    await firstStage
    expect(fixture.staged).toEqual(["message-c"])

    const secondStage = fixture.nextStage()
    fixture.gates[0]?.resolve()
    await secondStage
    expect(fixture.staged).toEqual(["message-c", "message-b"])

    const redoStage = fixture.nextStage()
    fixture.gates[1]?.resolve()
    await redoStage
    expect(fixture.staged).toEqual(["message-c", "message-b", "message-c"])

    fixture.gates[2]?.resolve()
    await Promise.all([first, second, redo])
  })

  test("discards a staged boundary removed by a new admission before undoing again", async () => {
    const fixture = setupRevert()
    const firstStage = fixture.nextStage()
    const first = fixture.actions.undo()
    await firstStage
    fixture.gates[0]?.resolve()
    await first

    fixture.commit([user("message-a"), user("message-b"), user("message-d")])
    const nextStage = fixture.nextStage()
    const next = fixture.actions.undo()

    expect(fixture.composer.current()).toEqual([{ type: "text", content: "message-d", start: 0, end: 9 }])
    await nextStage
    expect(fixture.staged).toEqual(["message-c", "message-d"])
    fixture.gates[1]?.resolve()
    await next
  })

  test("undoes a new admission after a full redo clears the previous boundary", async () => {
    const fixture = setupRevert()
    const firstStage = fixture.nextStage()
    const first = fixture.actions.undo()
    await firstStage
    fixture.gates[0]?.resolve()
    await first
    await fixture.actions.redo()

    fixture.commit([user("message-a"), user("message-b"), user("message-c"), user("message-d")])
    const nextStage = fixture.nextStage()
    const next = fixture.actions.undo()

    expect(fixture.composer.current()).toEqual([{ type: "text", content: "message-d", start: 0, end: 9 }])
    await nextStage
    expect(fixture.staged).toEqual(["message-c", "message-d"])
    fixture.gates[1]?.resolve()
    await next
  })

  test("enables undo from the effective boundary while redo is still pending", async () => {
    const fixture = setupRevert([user("message-a"), user("message-b")])
    const stageB = fixture.nextStage()
    const undoB = fixture.actions.undo()
    await stageB
    fixture.gates[0]?.resolve()
    await undoB

    const stageA = fixture.nextStage()
    const undoA = fixture.actions.undo()
    await stageA
    fixture.gates[1]?.resolve()
    await undoA
    expect(fixture.actions.canUndo()).toBe(false)

    const stageRedo = fixture.nextStage()
    const redo = fixture.actions.redo()
    expect(fixture.actions.canUndo()).toBe(true)
    await stageRedo
    fixture.gates[2]?.resolve()
    await redo
  })
})

describe("session revert cascade", () => {
  function setup(input?: {
    sessions?: SessionInfo[]
    children?: Record<string, SessionInfo[]>
    messages?: Record<string, SessionMessageInfo[]>
    messagePages?: Record<string, SessionMessageInfo[][]>
    active?: string[]
    failStage?: string[]
    serverBoundary?: string
  }) {
    const composer = createMemoryComposerState()
    const calls: Array<{ action: string; sessionID: string; messageID?: string; files?: boolean }> = []
    const failed: unknown[] = []
    const sessions = input?.sessions ?? []
    const messages = input?.messages ?? {}
    const messageRequests: Array<{
      sessionID: string
      cursor?: string
      limit?: number
      order?: "asc" | "desc"
      type?: string
    }> = []
    let serverBoundary = input?.serverBoundary
    const actions = createSessionRevertActions(
      {
        session: {
          identity: { params: { id: "parent" } },
          history: { userMessages: () => [timedUser("parent-user", 100)] },
          data: { revertMessageID: () => serverBoundary },
        },
        setActiveMessage() {},
      },
      {
        prompt: composer,
        directory: () => "/repo",
        failed: (error) => failed.push(error),
        pending: { list: () => [] },
        api: {
          interrupt: async ({ sessionID }) => {
            calls.push({ action: "interrupt", sessionID })
            return { interrupted: true }
          },
          wait: async ({ sessionID }) => {
            calls.push({ action: "wait", sessionID })
          },
          revert: {
            stage: async ({ sessionID, messageID, files }) => {
              calls.push({ action: "stage", sessionID, messageID, files })
              if (input?.failStage?.includes(sessionID)) throw new Error(`failed ${sessionID}`)
              if (sessionID === "parent") serverBoundary = messageID
              return { messageID }
            },
            clear: async ({ sessionID }) => {
              calls.push({ action: "clear", sessionID })
              if (sessionID === "parent") serverBoundary = undefined
            },
          },
          inbox: {
            list: async () => [],
            cancel: async () => undefined,
          },
        },
        cascade: {
          sessions: async ({ parentID }) => ({
            data: input?.children?.[parentID] ?? sessions.filter((item) => item.parentID === parentID),
            cursor: {},
          }),
          messages: async (request) => {
            messageRequests.push(request)
            const pages = input?.messagePages?.[request.sessionID]
            if (!pages) return { data: messages[request.sessionID] ?? [], cursor: {} }
            const index = request.cursor ? Number(request.cursor) : 0
            return { data: pages[index] ?? [], cursor: { next: index + 1 < pages.length ? String(index + 1) : undefined } }
          },
          status: (sessionID) => (input?.active?.includes(sessionID) ? "busy" : "idle"),
        },
      },
    )
    return { actions, calls, composer, failed, messageRequests }
  }

  test("reverts children and grandchildren at the first user message on or after the cutoff", async () => {
    const fixture = setup({
      sessions: [session("child", "parent"), session("grandchild", "child")],
      messages: {
        child: [timedUser("child-before", 99), timedUser("child-equal", 100), timedUser("child-after", 101)],
        grandchild: [timedUser("grandchild-after", 120)],
      },
    })

    await fixture.actions.to("parent-user")

    expect(fixture.calls.filter((call) => call.action === "stage")).toEqual([
      { action: "stage", sessionID: "child", messageID: "child-equal", files: false },
      { action: "stage", sessionID: "grandchild", messageID: "grandchild-after", files: false },
      { action: "stage", sessionID: "parent", messageID: "parent-user", files: undefined },
    ])
    expect(fixture.composer.current()).toEqual([{ type: "text", content: "parent-user", start: 0, end: 11 }])
  })

  test("does not use an assistant message as a descendant boundary", async () => {
    const fixture = setup({
      sessions: [session("child", "parent")],
      messages: {
        child: [{ id: "assistant", type: "assistant", time: { created: 100 } } as SessionMessageInfo],
      },
    })

    await fixture.actions.to("parent-user")

    expect(fixture.calls.filter((call) => call.action === "stage").map((call) => call.sessionID)).toEqual(["parent"])
  })

  test("follows the user-message cursor without repeating first-page ordering", async () => {
    const fixture = setup({
      sessions: [session("child", "parent")],
      messagePages: { child: [[timedUser("child-before", 99)], [timedUser("child-boundary", 100)]] },
    })

    await fixture.actions.to("parent-user")

    expect(fixture.messageRequests).toEqual([
      { sessionID: "child", limit: 200, order: "asc", type: "user" },
      { sessionID: "child", cursor: "1", type: "user" },
    ])
    expect(fixture.calls.filter((call) => call.action === "stage")).toContainEqual({
      action: "stage",
      sessionID: "child",
      messageID: "child-boundary",
      files: false,
    })
  })

  test("visits duplicate descendants once and terminates a cycle back to the parent", async () => {
    const child = session("child", "parent")
    const grandchild = session("grandchild", "child")
    const fixture = setup({
      children: {
        parent: [child, child],
        child: [grandchild, session("parent", "grandchild")],
        grandchild: [child],
      },
      messages: {
        child: [timedUser("child-user", 100)],
        grandchild: [timedUser("grandchild-user", 100)],
      },
    })

    await fixture.actions.to("parent-user")

    expect(fixture.calls.filter((call) => call.action === "stage").map((call) => call.sessionID)).toEqual([
      "child",
      "grandchild",
      "parent",
    ])
  })

  test("continues with other descendants and the parent when one descendant fails", async () => {
    const fixture = setup({
      sessions: [session("broken", "parent"), session("healthy", "parent")],
      messages: {
        broken: [timedUser("broken-user", 100)],
        healthy: [timedUser("healthy-user", 100)],
      },
      failStage: ["broken"],
    })

    expect(await fixture.actions.to("parent-user")).toBe(true)
    expect(fixture.calls.filter((call) => call.action === "stage").map((call) => call.sessionID)).toEqual([
      "broken",
      "healthy",
      "parent",
    ])
    expect(fixture.failed).toHaveLength(1)
  })

  test("interrupts an active descendant before reverting it without restoring its files", async () => {
    const fixture = setup({
      sessions: [session("child", "parent")],
      messages: { child: [timedUser("child-user", 100)] },
      active: ["child"],
    })

    await fixture.actions.to("parent-user")

    expect(fixture.calls.slice(0, 3)).toEqual([
      { action: "interrupt", sessionID: "child" },
      { action: "wait", sessionID: "child" },
      { action: "stage", sessionID: "child", messageID: "child-user", files: false },
    ])
  })

  test("clears marked descendants before clearing the parent", async () => {
    const fixture = setup({
      sessions: [session("child", "parent", true), session("grandchild", "child", true)],
      serverBoundary: "parent-user",
      active: ["grandchild"],
    })

    await fixture.actions.redo()

    expect(fixture.calls.filter((call) => call.action === "clear").map((call) => call.sessionID)).toEqual([
      "child",
      "grandchild",
      "parent",
    ])
    expect(fixture.calls.findIndex((call) => call.action === "interrupt" && call.sessionID === "grandchild")).toBeLessThan(
      fixture.calls.findIndex((call) => call.action === "clear" && call.sessionID === "grandchild"),
    )
  })
})
