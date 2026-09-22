import { describe, expect, test } from "bun:test"
import type { SessionMessageUser } from "@opencode/client/promise"
import { createMemoryComposerState, type RevertProgress } from "@/composer/state"
import { createSessionRevertActions, stageSessionRevert } from "./revert"

const user = (id: string): SessionMessageUser => ({ id, type: "user", text: id, time: { created: 0 } })
const timedUser = (id: string, created: number): SessionMessageUser => ({
  id,
  type: "user",
  text: id,
  time: { created },
})
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
    boundaries?: { sessionID: string; messageID: string }[]
    active?: string[]
    failStage?: string[]
    failPlan?: Error
    serverBoundary?: string
  }) {
    const composer = createMemoryComposerState()
    const calls: Array<{ action: string; sessionID: string; messageID?: string; files?: boolean; cutoff?: number }> = []
    const failed: unknown[] = []
    const progress: (RevertProgress | undefined)[] = []
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
              progress.push(composer.revert.progress())
              if (input?.failStage?.includes(sessionID)) throw new Error(`failed ${sessionID}`)
              if (sessionID === "parent") serverBoundary = messageID
              return { messageID }
            },
            clear: async ({ sessionID }) => {
              calls.push({ action: "clear", sessionID })
              if (sessionID === "parent") serverBoundary = undefined
            },
          },
          inbox: { list: async () => [], cancel: async () => undefined },
        },
        cascade: {
          revert: async (request) => {
            calls.push({ action: "plan", ...request })
            if (input?.failPlan) throw input.failPlan
            return input?.boundaries ?? []
          },
          clear: async (request) => {
            calls.push({ action: "clear-plan", ...request })
            return input?.boundaries ?? []
          },
          status: (sessionID) => (input?.active?.includes(sessionID) ? "busy" : "idle"),
        },
      },
    )
    return { actions, calls, composer, failed, progress }
  }

  test("uses one aggregate read when the family has no eligible boundaries", async () => {
    const fixture = setup()
    expect(await fixture.actions.to("parent-user")).toBe(true)
    expect(fixture.calls).toEqual([
      { action: "plan", sessionID: "parent", cutoff: 100 },
      { action: "interrupt", sessionID: "parent" },
      { action: "wait", sessionID: "parent" },
      { action: "stage", sessionID: "parent", messageID: "parent-user", files: undefined },
    ])
    expect(fixture.actions.pending()).toBe(false)
    expect(fixture.composer.revert.progress()).toBeUndefined()
  })

  test("keeps aggregate child and grandchild order, interrupts busy children and never restores their files", async () => {
    const fixture = setup({
      boundaries: [
        { sessionID: "child", messageID: "child-user" },
        { sessionID: "grandchild", messageID: "grandchild-user" },
      ],
      active: ["child"],
    })
    await fixture.actions.to("parent-user")
    expect(fixture.progress).toEqual([
      { phase: "descendants", completed: 0, total: 2 },
      { phase: "descendants", completed: 1, total: 2 },
      { phase: "session" },
    ])
    expect(fixture.calls.slice(1)).toEqual([
      { action: "interrupt", sessionID: "child" },
      { action: "wait", sessionID: "child" },
      { action: "stage", sessionID: "child", messageID: "child-user", files: false },
      { action: "stage", sessionID: "grandchild", messageID: "grandchild-user", files: false },
      { action: "interrupt", sessionID: "parent" },
      { action: "wait", sessionID: "parent" },
      { action: "stage", sessionID: "parent", messageID: "parent-user", files: undefined },
    ])
  })

  test("continues other descendants and root after a partial failure", async () => {
    const fixture = setup({
      boundaries: [
        { sessionID: "broken", messageID: "broken-user" },
        { sessionID: "healthy", messageID: "healthy-user" },
      ],
      failStage: ["broken"],
    })
    expect(await fixture.actions.to("parent-user")).toBe(true)
    expect(fixture.calls.filter((c) => c.action === "stage").map((c) => c.sessionID)).toEqual([
      "broken",
      "healthy",
      "parent",
    ])
    expect(fixture.failed).toHaveLength(1)
  })

  test("preserves root fallback on a failed aggregate read and releases progress after root failure", async () => {
    const failStage = ["parent"]
    const fixture = setup({ failPlan: new DOMException("Cancelled", "AbortError"), failStage })
    expect(await fixture.actions.to("parent-user")).toBe(false)
    expect(fixture.failed).toHaveLength(2)
    expect(fixture.actions.pending()).toBe(false)
    expect(fixture.composer.revert.progress()).toBeUndefined()
    expect(fixture.actions.boundary()).toBeUndefined()
    failStage.length = 0
    expect(await fixture.actions.to("parent-user")).toBe(true)
    expect(fixture.actions.pending()).toBe(false)
  })

  test("full redo uses one clear plan then clears descendants before root", async () => {
    const fixture = setup({
      serverBoundary: "parent-user",
      boundaries: [
        { sessionID: "child", messageID: "child-user" },
        { sessionID: "grandchild", messageID: "grandchild-user" },
      ],
      active: ["grandchild"],
    })
    await fixture.actions.redo()
    expect(fixture.calls.filter((c) => c.action === "clear").map((c) => c.sessionID)).toEqual([
      "child",
      "grandchild",
      "parent",
    ])
    expect(fixture.calls[0]).toEqual({ action: "clear-plan", sessionID: "parent" })
    expect(fixture.composer.revert.progress()).toBeUndefined()
  })
})

test("button and undo command targeting the same boundary join once without overwriting an edited draft", async () => {
  const fixture = setupRevert()
  const staging = fixture.nextStage()
  const command = fixture.actions.undo()
  await staging
  fixture.composer.set([{ type: "text", content: "Edited while waiting", start: 0, end: 20 }])
  const button = fixture.actions.to("message-c")
  expect(button).toBe(command)
  expect(fixture.composer.current()[0]).toMatchObject({ content: "Edited while waiting" })
  expect(fixture.composer.revert.progress()).toEqual({ phase: "session" })
  fixture.gates[0].resolve()
  expect(await button).toBe(true)
  expect(fixture.staged).toEqual(["message-c"])
  expect(fixture.composer.revert.progress()).toBeUndefined()
})
