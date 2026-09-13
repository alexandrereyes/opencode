import { describe, expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Database } from "bun:sqlite"
import { FileStorage } from "../poc/ui-undo/file-storage.js"
import { readLegacyAssignments } from "../poc/ui-undo/legacy-migrate.js"
import {
  PublicApiUndo,
  type MessageInfo,
  type Provenance,
  type PublicApi,
  type SessionInfo,
  type Storage,
} from "../poc/ui-undo/index.js"

const location = { directory: "/repo" }

describe("public API family undo POC", () => {
  test("discovers cold descendants through every page and stages exact recorded cuts", async () => {
    const fixture = makeFixture({ pageSize: 1 })
    fixture.sessions.push(
      session("root"),
      session("child", "root"),
      session("grandchild", "child", { directory: "/other" }),
    )
    fixture.messages.set("root", [message("root-cut", "user", 1), message("root-tool", "assistant", 2)])
    fixture.messages.set("child", [
      message("child-independent", "user", 10),
      toolMessage("child-prior-tool", 10, "sh_prior"),
      message("child-causal", "user", 10),
      toolMessage("child-tool", 11, "sh_child"),
    ])
    fixture.messages.set("grandchild", [message("grandchild-causal", "user", 10)])
    fixture.inbox.set("child", [{ id: "child-pending", type: "user" }])
    fixture.shells.push({ id: "sh_prior", metadata: { sessionID: "child" }, location })
    fixture.shells.push({ id: "sh_child", metadata: { sessionID: "child" }, location })
    await record(fixture.storage, [
      provenance("child", "child-independent", null),
      provenance("child", "child-causal", ["root", "root-tool"]),
      provenance("child", "child-pending", ["root", "root-tool"]),
      provenance("grandchild", "grandchild-causal", ["child", "child-tool"]),
    ])

    const operation = await new PublicApiUndo(fixture.api, fixture.storage).stage({
      rootSessionID: "root",
      rootMessageID: "root-cut",
    })

    expect(operation.participants).toEqual([
      { sessionID: "child", messageID: "child-causal", pendingIDs: ["child-pending"], files: true, depth: 1 },
      { sessionID: "grandchild", messageID: "grandchild-causal", pendingIDs: [], files: false, depth: 2 },
    ])
    expect(fixture.calls.filter((call) => call.startsWith("stage:"))).toEqual([
      "stage:grandchild:grandchild-causal:false",
      "stage:child:child-causal:true",
      "stage:root:root-cut:true",
    ])
    expect(fixture.calls).toContain("shell.remove:sh_child:/repo")
    expect(fixture.calls).not.toContain("shell.remove:sh_prior:/repo")
    expect(fixture.calls).not.toContain("inbox.cancel:child:child-pending")
  })

  test("persists enough state to redo after constructing a new orchestrator", async () => {
    const fixture = makeFixture()
    fixture.sessions.push(session("root"), session("child", "root"))
    fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
    fixture.messages.set("child", [message("input", "user", 3)])
    await record(fixture.storage, [provenance("child", "input", ["root", "tool"])])
    await new PublicApiUndo(fixture.api, fixture.storage).stage({ rootSessionID: "root", rootMessageID: "cut" })

    await new PublicApiUndo(fixture.api, fixture.storage).redo("root")

    expect(fixture.calls.filter((call) => call.startsWith("clear:"))).toEqual(["clear:root", "clear:child"])
  })

  test("commits the stored family when a prompt hook names the root or child", async () => {
    for (const member of ["root", "child"]) {
      const fixture = makeFixture()
      fixture.sessions.push(session("root"), session("child", "root"))
      fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
      fixture.messages.set("child", [message("input", "user", 3)])
      await record(fixture.storage, [provenance("child", "input", ["root", "tool"])])
      const undo = new PublicApiUndo(fixture.api, fixture.storage)
      await undo.stage({ rootSessionID: "root", rootMessageID: "cut" })

      await new PublicApiUndo(fixture.api, fixture.storage).commitForMember(member, { nativeWillCommit: true })

      expect(fixture.calls.filter((call) => call.startsWith("commit:"))).toEqual([
        member === "root" ? "commit:child" : "commit:root",
      ])
    }
  })

  test("reopens operation state written by a separate process", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "opencode-ui-undo-"))
    const file = path.join(directory, "state.json")
    try {
      const process = Bun.spawn(["bun", "test/fixture/ui-undo-storage-writer.ts", file], {
        cwd: path.resolve(import.meta.dir, ".."),
        stdout: "pipe",
        stderr: "pipe",
      })
      expect(await process.exited).toBe(0)
      const fixture = makeFixture()
      await new PublicApiUndo(fixture.api, new FileStorage(file)).redo("root")
      expect(fixture.calls.filter((call) => call.startsWith("clear:"))).toEqual(["clear:root", "clear:child"])
    } finally {
      await rm(directory, { recursive: true })
    }
  })

  test("rejects malformed persisted operation DTOs at the read boundary", async () => {
    const fixture = makeFixture()
    fixture.values.set("ui-undo/operation/root", { version: 1, phase: "staged" })

    await expect(new PublicApiUndo(fixture.api, fixture.storage).redo("root")).rejects.toMatchObject({
      code: "operation-missing",
    })
    expect(fixture.calls).toEqual([])
  })

  test("refuses child history before provenance is supplied or migrated", async () => {
    const fixture = makeFixture()
    fixture.sessions.push(session("root"), session("child", "root"))
    fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
    fixture.messages.set("child", [message("unknown", "user", 2)])

    await expect(
      new PublicApiUndo(fixture.api, fixture.storage).stage({ rootSessionID: "root", rootMessageID: "cut" }),
    ).rejects.toMatchObject({ code: "provenance-unavailable" })
    expect(fixture.calls.some((call) => call.startsWith("interrupt:"))).toBe(false)
  })

  test("migrates exact provenance from the custom backend public event log", async () => {
    const fixture = makeFixture()
    fixture.sessions.push(session("root"), session("child", "root"))
    fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
    fixture.messages.set("child", [message("independent", "user", 2), message("causal", "user", 2)])
    fixture.logs.set("root", [
      {
        id: "evt_assignment",
        created: 2,
        type: "session.subagent.input.assigned",
        durable: { aggregateID: "root", seq: 3, version: 1 },
        data: {
          sessionID: "root",
          childSessionID: "child",
          inputID: "causal",
          origin: { messageID: "tool", toolCallID: "call" },
        },
      },
    ])

    const undo = new PublicApiUndo(fixture.api, fixture.storage)
    await undo.migrateProvenance("root", { assignmentEvents: true })
    const plan = await undo.plan({ rootSessionID: "root", rootMessageID: "cut" })

    expect(plan.participants).toEqual([
      { sessionID: "child", messageID: "causal", pendingIDs: [], files: true, depth: 1 },
    ])
  })

  test("does not claim migration when the public log retained no durable history", async () => {
    const fixture = makeFixture({ persistLogs: false })
    fixture.sessions.push(session("root"))

    await expect(
      new PublicApiUndo(fixture.api, fixture.storage).migrateProvenance("root", { assignmentEvents: true }),
    ).rejects.toMatchObject({ code: "migration-history-unavailable" })
  })

  test("imports the legacy causal table once and plans from its durable ledger", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "opencode-ui-undo-migration-"))
    const databasePath = path.join(directory, "legacy.db")
    try {
      const database = new Database(databasePath)
      database.run(`CREATE TABLE session_causal (
        input_id text PRIMARY KEY,
        parent_session_id text NOT NULL,
        child_session_id text NOT NULL,
        seq integer NOT NULL,
        message_id text NOT NULL,
        tool_call_id text NOT NULL
      )`)
      database
        .query("INSERT INTO session_causal VALUES (?, ?, ?, ?, ?, ?)")
        .run("input", "root", "child", 7, "tool", "call")
      database.close()
      const fixture = makeFixture({ persistLogs: false })
      fixture.sessions.push(session("root"), session("child", "root"))
      fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
      fixture.messages.set("child", [message("input", "user", 3)])
      const storage = new FileStorage(path.join(directory, "plugin-storage.json"))
      const undo = new PublicApiUndo(fixture.api, storage)

      expect(await undo.importLegacy(readLegacyAssignments(databasePath))).toEqual({
        migrated: 1,
        alreadyApplied: false,
      })
      expect(await undo.importLegacy(readLegacyAssignments(databasePath))).toEqual({
        migrated: 0,
        alreadyApplied: true,
      })
      expect(await storage.get("ui-undo/provenance/child/input")).toEqual({
        childSessionID: "child",
        inputID: "input",
        assignedSeq: 7,
        origin: { parentSessionID: "root", parentMessageID: "tool", toolCallID: "call" },
      })
      expect((await undo.plan({ rootSessionID: "root", rootMessageID: "cut" })).participants[0]).toMatchObject({
        sessionID: "child",
        messageID: "input",
      })
    } finally {
      await rm(directory, { recursive: true })
    }
  })

  test("matches the oracle suffix cut when independent work follows the causal input", async () => {
    const fixture = makeFixture()
    fixture.sessions.push(session("root"), session("child", "root"))
    fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
    fixture.messages.set("child", [message("causal", "user", 3), message("independent", "user", 4)])
    await record(fixture.storage, [
      provenance("child", "causal", ["root", "tool"]),
      provenance("child", "independent", null),
    ])

    const plan = await new PublicApiUndo(fixture.api, fixture.storage).plan({
      rootSessionID: "root",
      rootMessageID: "cut",
    })
    expect(plan.participants[0]?.messageID).toBe("causal")
  })

  test("preserves an independently staged child revert by refusing to replace it", async () => {
    const fixture = makeFixture()
    fixture.sessions.push(session("root"), { ...session("child", "root"), revert: { messageID: "older-cut" } })
    fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
    fixture.messages.set("child", [message("input", "user", 3)])
    await record(fixture.storage, [provenance("child", "input", ["root", "tool"])])

    await expect(
      new PublicApiUndo(fixture.api, fixture.storage).stage({ rootSessionID: "root", rootMessageID: "cut" }),
    ).rejects.toMatchObject({ code: "independent-revert-present" })
  })

  test("does not block on a reverted descendant outside the selected causal plan", async () => {
    const fixture = makeFixture()
    fixture.sessions.push(session("root"), { ...session("unrelated", "root"), revert: { messageID: "older-cut" } })
    fixture.messages.set("root", [message("cut", "user", 1)])

    await new PublicApiUndo(fixture.api, fixture.storage).stage({ rootSessionID: "root", rootMessageID: "cut" })

    expect(fixture.calls.filter((call) => call.startsWith("stage:"))).toEqual(["stage:root:cut:true"])
  })

  test("moves a boundary for a child owned by the candidate operation", async () => {
    const fixture = makeFixture()
    fixture.sessions.push(session("root"), session("child", "root"))
    fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
    fixture.messages.set("child", [message("input", "user", 3)])
    await record(fixture.storage, [provenance("child", "input", ["root", "tool"])])
    const undo = new PublicApiUndo(fixture.api, fixture.storage)
    await undo.stage({ rootSessionID: "root", rootMessageID: "cut" })
    fixture.sessions.splice(
      0,
      fixture.sessions.length,
      { ...session("root"), revert: { messageID: "cut" } },
      { ...session("child", "root"), revert: { messageID: "input" } },
    )

    await undo.stage({ rootSessionID: "root", rootMessageID: "cut" })

    expect(fixture.calls.filter((call) => call === "stage:child:input:true")).toHaveLength(2)
  })

  test("rolls back already staged sessions when a middle stage fails", async () => {
    const fixture = makeFixture({ failStage: "child" })
    fixture.sessions.push(session("root"), session("child", "root"), session("grandchild", "child"))
    fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
    fixture.messages.set("child", [message("input", "user", 3), message("child-tool", "assistant", 4)])
    fixture.messages.set("grandchild", [message("grand-input", "user", 5)])
    await record(fixture.storage, [
      provenance("child", "input", ["root", "tool"]),
      provenance("grandchild", "grand-input", ["child", "child-tool"]),
    ])

    await expect(
      new PublicApiUndo(fixture.api, fixture.storage).stage({ rootSessionID: "root", rootMessageID: "cut" }),
    ).rejects.toThrow("stage failed")
    expect(fixture.calls.filter((call) => call.startsWith("clear:"))).toEqual(["clear:grandchild"])
    expect(await fixture.storage.get("ui-undo/operation/root")).toMatchObject({ phase: "failed" })
  })

  test("exposes irreversible partial inbox cancellation instead of claiming atomicity", async () => {
    const fixture = makeFixture({ failCancel: "pending-2" })
    fixture.sessions.push(session("root"), session("child", "root"))
    fixture.messages.set("root", [message("cut", "user", 1), message("tool", "assistant", 2)])
    fixture.messages.set("child", [message("input", "user", 3)])
    fixture.inbox.set("child", [
      { id: "pending-1", type: "user" },
      { id: "pending-2", type: "user" },
    ])
    await record(fixture.storage, [
      provenance("child", "input", ["root", "tool"]),
      provenance("child", "pending-1", ["root", "tool"]),
      provenance("child", "pending-2", ["root", "tool"]),
    ])

    const undo = new PublicApiUndo(fixture.api, fixture.storage)
    await undo.stage({ rootSessionID: "root", rootMessageID: "cut" })
    expect(fixture.inbox.get("child")?.map((item) => item.id)).toEqual(["pending-1", "pending-2"])
    await expect(undo.commit("root")).rejects.toThrow("cancel failed")
    expect(fixture.calls).toContain("inbox.cancel:child:pending-1")
    expect(fixture.inbox.get("child")?.map((item) => item.id)).toEqual(["pending-2"])
  })
})

function session(id: string, parentID?: string, value = location): SessionInfo {
  return { id, parentID, location: value }
}

function message(id: string, type: string, created: number): MessageInfo {
  return { id, type, time: { created } }
}

function toolMessage(id: string, created: number, shellID: string): MessageInfo {
  return { id, type: "assistant", time: { created }, content: [{ type: "tool", state: { metadata: { shellID } } }] }
}

function provenance(childSessionID: string, inputID: string, origin: readonly [string, string] | null): Provenance {
  return {
    childSessionID,
    inputID,
    assignedSeq: 0,
    origin: origin ? { parentSessionID: origin[0], parentMessageID: origin[1], toolCallID: "call" } : null,
  }
}

async function record(storage: Storage, values: ReadonlyArray<Provenance>) {
  for (const value of values) await storage.set(`ui-undo/provenance/${value.childSessionID}/${value.inputID}`, value)
}

function makeFixture(
  options: { pageSize?: number; failStage?: string; failCancel?: string; persistLogs?: boolean } = {},
) {
  const sessions: SessionInfo[] = []
  const messages = new Map<string, MessageInfo[]>()
  const inbox = new Map<string, Array<{ id: string; type: string }>>()
  const shells: Array<{ id: string; metadata: Record<string, unknown>; location: SessionInfo["location"] }> = []
  const calls: string[] = []
  const logs = new Map<string, unknown[]>()
  const values = new Map<string, unknown>()
  const storage: Storage = {
    get: async (key) => values.get(key),
    set: async (key, value) => void values.set(key, structuredClone(value)),
    remove: async (key) => void values.delete(key),
    scan: async ({ prefix, after, limit = 100 }) => {
      const keys = [...values.keys()].filter((key) => key.startsWith(prefix) && (!after || key > after)).sort()
      const page = keys.slice(0, limit)
      return {
        entries: page.map((key) => ({ key, value: values.get(key) })),
        next: keys.length > page.length ? page.at(-1) : undefined,
      }
    },
  }
  const api: PublicApi = {
    session: {
      list: async ({ parentID, cursor }) => {
        const all = sessions.filter((item) => item.parentID === parentID)
        const start = cursor ? Number(cursor) : 0
        const size = options.pageSize ?? 100
        return {
          data: all.slice(start, start + size),
          cursor: { next: start + size < all.length ? String(start + size) : undefined },
        }
      },
      get: async ({ sessionID }) => sessions.find((item) => item.id === sessionID)!,
      interrupt: async ({ sessionID }) => void calls.push(`interrupt:${sessionID}`),
      wait: async ({ sessionID }) => void calls.push(`wait:${sessionID}`),
      revert: {
        stage: async ({ sessionID, messageID, files }) => {
          calls.push(`stage:${sessionID}:${messageID}:${files}`)
          if (options.failStage === sessionID) throw new Error("stage failed")
        },
        clear: async ({ sessionID }) => void calls.push(`clear:${sessionID}`),
        commit: async ({ sessionID }) => void calls.push(`commit:${sessionID}`),
      },
      inbox: {
        list: async ({ sessionID }) => inbox.get(sessionID) ?? [],
        cancel: async ({ sessionID, inboxID }) => {
          calls.push(`inbox.cancel:${sessionID}:${inboxID}`)
          if (options.failCancel === inboxID) throw new Error("cancel failed")
          inbox.set(
            sessionID,
            (inbox.get(sessionID) ?? []).filter((item) => item.id !== inboxID),
          )
        },
      },
      log: async function* ({ sessionID }) {
        yield* logs.get(sessionID) ?? []
        if (options.persistLogs !== false)
          yield { type: "session.fixture", durable: { aggregateID: sessionID, seq: 0 } }
        yield { type: "log.synced", aggregateID: sessionID }
      },
    },
    message: {
      list: async ({ sessionID, cursor }) => {
        const all = messages.get(sessionID) ?? []
        const start = cursor ? Number(cursor) : 0
        const size = options.pageSize ?? 100
        return {
          data: all.slice(start, start + size),
          cursor: { next: start + size < all.length ? String(start + size) : undefined },
        }
      },
    },
    shell: {
      list: async ({ location: target }) => ({
        data: shells.filter((item) => item.location.directory === target.directory),
      }),
      remove: async ({ id, location: target }) => {
        calls.push(`shell.remove:${id}:${target.directory}`)
        const index = shells.findIndex((item) => item.id === id)
        if (index >= 0) shells.splice(index, 1)
      },
    },
  }
  return { api, storage, sessions, messages, inbox, shells, calls, logs, values }
}
