import { describe, expect, test } from "bun:test"
import { createChatSelectionCoordinator } from "./controller"
import { managedSessionBlocked, resolveManagedSessionDirectory } from "../composer-adapter"
import { chatMatchesSearch } from "./selector"
import { createChatCapability, resolveCapabilityIdentity } from "@/runtime/chats"

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}

describe("chat selection", () => {
  test("Chat fork opens a distinct root draft and submits in its new scratch", async () => {
    const capability = createChatCapability(() => Promise.resolve({ root: "/data/chats" }))
    await capability.load()
    expect(await resolveCapabilityIdentity(capability, "/data/chats/day/original", false)).toBe(true)
    expect(await resolveCapabilityIdentity(capability, "/data/chats/day/original", false)).toBe(true)
    const next = "/data/chats/day/new-root"
    expect(
      await resolveManagedSessionDirectory({
        chat: true,
        projectDirectory: next,
        resolve: async () => "/data/chats/day/original",
      }),
    ).toBe(next)
  })

  test("search keeps Chats in the discriminated option list", () => {
    expect(chatMatchesSearch("Chats", "chat", true)).toBe(true)
    expect(chatMatchesSearch("Chats", "project", true)).toBe(false)
    expect(chatMatchesSearch("Chats", "chat", false)).toBe(false)
  })

  test("uses the exact scratch directory without resolving a worktree", async () => {
    let resolved = false
    expect(
      await resolveManagedSessionDirectory({
        chat: true,
        projectDirectory: "/git-parent/chats/session-one",
        resolve: async () => {
          resolved = true
          return "/worktree"
        },
      }),
    ).toBe("/git-parent/chats/session-one")
    expect(resolved).toBe(false)
  })

  test("blocks while allocation is pending and deduplicates repeated selection", async () => {
    const allocation = deferred<{ id: string; directory: string }>()
    const transition = deferred<void>()
    const pending: boolean[] = []
    let calls = 0
    const selected: string[] = []
    const target = { draftID: "draft", server: "a" }
    const controller = createChatSelectionCoordinator({
      capture: () => target,
      allocate: () => {
        calls++
        return allocation.promise
      },
      apply: async (_, value) => {
        selected.push(value.directory)
        await transition.promise
      },
      setPending: (value) => pending.push(value),
      onError: () => {},
    })
    const first = controller.select()
    const second = controller.select()
    expect(first).toBe(second)
    expect(calls).toBe(1)
    expect(pending).toEqual([true])
    expect(managedSessionBlocked(pending.at(-1)!)).toBe(true)
    allocation.resolve({ id: "allocation", directory: "/chat" })
    await Promise.resolve()
    expect(selected).toEqual(["/chat"])
    expect(pending).toEqual([true])
    transition.resolve()
    await first
    expect(pending).toEqual([true, false])
  })

  test("discards a delayed allocation after a server change", async () => {
    const allocation = deferred<{ id: string; directory: string }>()
    let target = { draftID: "draft", server: "a" }
    const selected: string[] = []
    const controller = createChatSelectionCoordinator({
      capture: () => target,
      allocate: () => allocation.promise,
      apply: async (_, value) => {
        selected.push(value.directory)
      },
      setPending: () => {},
      onError: () => {},
    })
    const request = controller.select()
    target = { draftID: "draft", server: "b" }
    allocation.resolve({ id: "allocation", directory: "/server-a/chat" })
    await request
    expect(selected).toEqual([])
  })

  test("cancellation supersedes a delayed response", async () => {
    const allocation = deferred<{ id: string; directory: string }>()
    const selected: string[] = []
    const controller = createChatSelectionCoordinator({
      capture: () => ({ draftID: "draft", server: "a" }),
      allocate: () => allocation.promise,
      apply: async (_, value) => {
        selected.push(value.directory)
      },
      setPending: () => {},
      onError: () => {},
    })
    const request = controller.select()
    controller.cancel()
    allocation.resolve({ id: "allocation", directory: "/chat" })
    await request
    expect(selected).toEqual([])
  })
})
