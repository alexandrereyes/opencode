import { expect, test } from "bun:test"
import {
  createChatCapability,
  resolveCapabilityIdentity,
  resolveChatRoot,
  resolvedChatIdentity,
  shouldRegisterProject,
  shouldRegisterCapabilityProject,
} from "./chats"

test("missing Chats RPC is an unavailable capability", async () => {
  await expect(resolveChatRoot(() => Promise.reject(new Error("method not found")))).resolves.toBeUndefined()
})

test("managed chat directories never register as projects after reload", () => {
  expect(shouldRegisterProject("/data/chats/2026-09-15/session-one", undefined, true)).toBe(false)
  expect(shouldRegisterProject("/data/chats/2026-09-15/session-one", "/data/chats")).toBe(false)
  expect(shouldRegisterProject("/data/project", "/data/chats")).toBe(true)
})

test("delayed capability loading reactively invalidates consumers", async () => {
  let resolve!: (value: { root: string }) => void
  const capability = createChatCapability(() => new Promise((done) => (resolve = done)))
  expect(capability.state.status).toBe("idle")
  const loading = capability.load()
  expect(capability.state.status).toBe("loading")
  resolve({ root: "/data/chats" })
  await loading
  expect(capability.state.status).toBe("available")
  expect(capability.state.root).toBe("/data/chats")
})

test("explicit identity waits for delayed classification and authoritative location clears stale flags", async () => {
  let resolve!: (value: { root: string }) => void
  const capability = createChatCapability(() => new Promise((done) => (resolve = done)))
  const chat = resolveCapabilityIdentity(capability, "/data/chats/day/session-one", true)
  resolve({ root: "/data/chats" })
  await expect(chat).resolves.toBe(true)
  expect(resolvedChatIdentity("/projects/repo", "/data/chats", true)).toBe(false)
})

test("palette-style registration waits for delayed info when explicit identity is present", async () => {
  let resolve!: (value: { root: string }) => void
  const capability = createChatCapability(() => new Promise((done) => (resolve = done)))
  const registration = shouldRegisterCapabilityProject(capability, "/data/chats/day/session-one", true)
  resolve({ root: "/data/chats" })
  await expect(registration).resolves.toBe(false)
})

test("unavailable capability preserves explicit identity and leaves unidentified sessions common", async () => {
  const capability = createChatCapability(() => Promise.reject(new Error("method not found")))
  await expect(resolveCapabilityIdentity(capability, "/scratch/chat", true)).resolves.toBe(true)
  await expect(shouldRegisterCapabilityProject(capability, "/scratch/chat", true)).resolves.toBe(false)
  await expect(resolveCapabilityIdentity(capability, "/projects/repo", false)).resolves.toBe(false)
  await expect(shouldRegisterCapabilityProject(capability, "/projects/repo", false)).resolves.toBe(true)
})

test("temporary info failure keeps explicit Chat identity so a new root cannot reuse its scratch", async () => {
  const capability = createChatCapability(() => Promise.reject(new Error("temporary failure")))
  const current = "/scratch/session-one"
  expect(await resolveCapabilityIdentity(capability, current, true)).toBe(true)
  expect(await shouldRegisterCapabilityProject(capability, current, true)).toBe(false)
  expect(await resolveCapabilityIdentity(capability, current, false)).toBe(false)
})
