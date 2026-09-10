import { describe, expect, test } from "bun:test"
import type { SessionMessageUser } from "@opencode/client/promise"
import { createMemoryComposerState } from "@/composer/state"
import { createSessionRevertActions, stageSessionRevert } from "./revert"

const user = (id: string): SessionMessageUser => ({ id, type: "user", text: id, time: { created: 0 } })

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
