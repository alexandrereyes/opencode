import { describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import path from "node:path"
import {
  activateChatRuntime,
  allocateChat,
  applyRemovalResults,
  markMissingOwners,
  markDeleted,
  mutationConflict,
  reconcileAllocations,
  reconcileStates,
  reconcileStatesFromSnapshot,
  removeAllocation,
  statAllocation,
  startChatLifecycle,
  transitionStatus,
  type Allocation,
} from "../src/chats/index"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Chats } from "../src/chats/rpc"
import { Effect, Schema, Stream } from "effect"

const owner = Session.ID.make("ses_owner")
const directory = AbsolutePath.make("/chats/session-one")
const allocation = (status: Allocation["status"]): Allocation => ({
  id: "allocation-one",
  directory,
  createdAt: 1,
  revision: 0,
  status,
  sessionID: status === "reserved" ? undefined : owner,
})

describe("managed chats", () => {
  test("publishes the custom RPC contract", () => {
    expect(Chats.Definition.id).toBe("custom.chats")
    expect(Object.keys(Chats.Definition.methods)).toEqual(["info", "allocate", "claim", "confirm"])
  })

  test("registration and activation complete while the event stream remains open", async () => {
    let registered = false
    await Effect.runPromise(
      Effect.scoped(
        activateChatRuntime(
          Effect.sync(() => {
            registered = true
          }),
          Effect.void,
          Stream.never.pipe(Stream.runDrain),
        ),
      ),
    )
    expect(registered).toBe(true)
  })

  test("allocates distinct empty directories without Git metadata", async () => {
    const root = await fs.mkdtemp(path.join(process.env.TMPDIR ?? "/tmp", "opencode-chats-"))
    try {
      const first = await allocateChat(root, new Date("2026-09-15T12:00:00Z"), "00000000-0000-4000-8000-000000000001")
      const second = await allocateChat(root, new Date("2026-09-15T12:00:00Z"), "00000000-0000-4000-8000-000000000002")
      expect(first.directory).not.toBe(second.directory)
      expect(await fs.readdir(first.directory)).toEqual([])
      expect(await fs.readdir(second.directory)).toEqual([])
      expect(
        await fs.stat(path.join(first.directory, ".git")).then(
          () => true,
          () => false,
        ),
      ).toBe(false)
    } finally {
      await fs.rm(root, { recursive: true, force: true })
    }
  })

  test("pending creation survives failed create, reconcile, reload and same-owner retry", () => {
    const pending = allocation("pending")
    expect(reconcileStates([pending], [])).toEqual([pending])
    expect(markMissingOwners([pending], [])).toEqual([pending])
    expect(mutationConflict(pending, owner, "pending")).toBeUndefined()
    expect(mutationConflict(pending, owner, "confirmed")).toBeUndefined()
    expect(transitionStatus("confirmed", "pending")).toBe("confirmed")
    expect(reconcileStates([pending], [{ id: owner, directory }])).toEqual([{ ...pending, status: "confirmed" }])
  })

  test("delete proves a pending owner existed after confirmation response was lost", () => {
    const pending = allocation("pending")
    expect(markDeleted([pending], owner)).toEqual([{ ...pending, status: "cleanup", revision: 1 }])
  })

  test("scan results cannot overwrite concurrent allocate, claim or confirm", () => {
    const cleanup = allocation("cleanup")
    const added = {
      ...allocation("reserved"),
      id: "allocation-two",
      directory: AbsolutePath.make("/chats/two"),
    }
    const confirmed = { ...cleanup, status: "confirmed" as const, revision: 1 }
    expect(reconcileStatesFromSnapshot([confirmed, added], [cleanup], [])).toEqual([confirmed, added])
    const result = [{ id: cleanup.id, directory: cleanup.directory, removed: true }]
    expect(applyRemovalResults([cleanup, added], result)).toEqual([added])
    expect(applyRemovalResults([confirmed, added], result)).toEqual([confirmed, added])
  })

  test("delayed scan preserves concurrent allocation and confirmation in storage", async () => {
    let state: Schema.Json | undefined = [allocation("confirmed")]
    let enter!: () => void
    let complete!: () => void
    const entered = new Promise<void>((resolve) => (enter = resolve))
    const scan = new Promise<void>((resolve) => (complete = resolve))
    const storage = {
      get: () => Effect.sync(() => state),
      update: <A>(_key: string, update: (current: Schema.Json | undefined) => readonly [Schema.Json, A]) =>
        Effect.sync(() => {
          const [next, result] = update(state)
          state = next
          return result
        }),
    }
    const running = Effect.runPromise(
      reconcileAllocations({
        storage,
        session: {
          scan: () =>
            Effect.promise(async () => {
              enter()
              await scan
              return { data: [] }
            }),
        },
      }),
    )
    await entered
    await Effect.runPromise(
      storage.update("chats:allocations", (current) => [
        [
          { ...allocation("confirmed"), revision: 1 },
          {
            ...allocation("reserved"),
            id: "allocation-two",
            directory: AbsolutePath.make("/chats/two"),
          },
        ],
        undefined,
      ]),
    )
    complete()
    await running
    expect(state).toEqual([
      { ...allocation("confirmed"), revision: 1 },
      {
        ...allocation("reserved"),
        id: "allocation-two",
        directory: AbsolutePath.make("/chats/two"),
      },
    ])
  })

  test("rejects lookalikes and symlink allocations during removal", async () => {
    const data = await fs.mkdtemp(path.join(process.env.TMPDIR ?? "/tmp", "opencode-chat-remove-"))
    try {
      const root = path.join(data, "opencode", "chats")
      await fs.mkdir(root, { recursive: true })
      const lookalike = path.join(data, "opencode", "chats-copy", "session-one")
      await fs.mkdir(lookalike, { recursive: true })
      expect(await removeAllocation(lookalike, root)).toBe(false)
      const external = path.join(data, "external")
      await fs.mkdir(external)
      const link = path.join(root, "session-link")
      await fs.symlink(external, link)
      expect(await removeAllocation(link, root)).toBe(false)
      expect(
        await fs.stat(external).then(
          () => true,
          () => false,
        ),
      ).toBe(true)
    } finally {
      await fs.rm(data, { recursive: true, force: true })
    }
  })

  test("only ENOENT is treated as an absent allocation", async () => {
    const failure = Object.assign(new Error("denied"), { code: "EACCES" })
    await expect(statAllocation("/chat", () => Promise.reject(failure))).rejects.toBe(failure)
    const io = Object.assign(new Error("io"), { code: "EIO" })
    await expect(statAllocation("/chat", () => Promise.reject(io))).rejects.toBe(io)
    await expect(
      statAllocation("/chat", () => Promise.reject(Object.assign(new Error("missing"), { code: "ENOENT" }))),
    ).resolves.toBeUndefined()
  })

  test("removes an unreferenced cleanup allocation from disk", async () => {
    const root = await fs.mkdtemp(path.join(process.env.TMPDIR ?? "/tmp", "opencode-chat-lifecycle-"))
    try {
      const created = await allocateChat(root)
      expect(await removeAllocation(created.directory, root)).toBe(true)
      expect(
        await fs.stat(created.directory).then(
          () => true,
          () => false,
        ),
      ).toBe(false)
    } finally {
      await fs.rm(root, { recursive: true, force: true })
    }
  })
})
