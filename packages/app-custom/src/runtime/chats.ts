import { Chats } from "@opencode/plugin-app-custom/chats/rpc"
import type { ServerSDK } from "@/runtime/server/client"
import { pathKey } from "@/workspaces/path-key"
import { createStore } from "solid-js/store"

type ChatCapabilityState =
  | { status: "idle" | "loading"; root?: undefined }
  | { status: "available"; root: string }
  | { status: "unavailable"; root?: undefined }

const capabilities = new WeakMap<ServerSDK, ReturnType<typeof createChatCapability>>()

export function chatCapability(sdk: ServerSDK) {
  const existing = capabilities.get(sdk)
  if (existing) return existing
  const capability = createChatCapability(() => sdk.api.rpc(Chats.Definition).info({}))
  capabilities.set(sdk, capability)
  return capability
}

export function createChatCapability(load: () => Promise<{ root: string }>) {
  const [state, setState] = createStore<ChatCapabilityState>({ status: "idle" })
  let request: Promise<void> | undefined
  return {
    state,
    load() {
      if (request) return request
      setState({ status: "loading" })
      request = load()
        .then(
          (result) => setState({ status: "available", root: result.root }),
          () => setState({ status: "unavailable" }),
        )
        .finally(() => {
          request = undefined
        })
      return request
    },
    retry() {
      if (state.status === "loading") return request
      setState({ status: "idle" })
      return this.load()
    },
  }
}

export function isChatDirectory(directory: string, root: string | undefined) {
  if (!root) return false
  const target = pathKey(directory)
  const base = pathKey(root)
  return target !== base && target.startsWith(base.endsWith("/") ? base : `${base}/`)
}

export function resolvedChatIdentity(directory: string, root: string | undefined, fallback = false) {
  return root === undefined ? fallback : isChatDirectory(directory, root)
}

export function chatRoot(sdk: ServerSDK) {
  const capability = chatCapability(sdk)
  return capability.load().then(() => capability.state.root)
}

export function knownChatRoot(sdk: ServerSDK) {
  return chatCapability(sdk).state.root
}

export function resolveChatRoot(load: () => Promise<{ root: string }>) {
  return load().then(
    (result) => result.root,
    () => undefined,
  )
}

export function shouldRegisterProject(directory: string, root: string | undefined, explicit = false) {
  return !explicit && !isChatDirectory(directory, root)
}

export async function resolveChatIdentity(sdk: ServerSDK, directory: string, fallback = false) {
  return resolveCapabilityIdentity(chatCapability(sdk), directory, fallback)
}

export async function resolveCapabilityIdentity(
  capability: ReturnType<typeof createChatCapability>,
  directory: string,
  fallback = false,
) {
  const current = resolveCapabilityState(capability.state, directory, fallback)
  if (current !== undefined) return current
  await capability.load()
  return resolveCapabilityState(capability.state, directory, fallback) ?? fallback
}

function resolveCapabilityState(state: ChatCapabilityState, directory: string, fallback: boolean) {
  if (state.status === "available") return isChatDirectory(directory, state.root)
  if (state.status === "unavailable") return fallback
  if (state.status === "loading" || state.status === "idle") return undefined
  return fallback
}

export async function shouldRegisterSessionProject(
  sdk: ServerSDK,
  directory: string,
  fallbackChat = false,
) {
  return shouldRegisterCapabilityProject(chatCapability(sdk), directory, fallbackChat)
}

export async function shouldRegisterCapabilityProject(
  capability: ReturnType<typeof createChatCapability>,
  directory: string,
  fallbackChat = false,
) {
  return !(await resolveCapabilityIdentity(capability, directory, fallbackChat))
}

export function allocateChat(sdk: ServerSDK) {
  return sdk.api.rpc(Chats.Definition).allocate({})
}

export function claimChat(sdk: ServerSDK, input: { id: string; directory: string; sessionID: string }) {
  return sdk.api.rpc(Chats.Definition).claim(input)
}

export function confirmChat(sdk: ServerSDK, input: { id: string; directory: string; sessionID: string }) {
  return sdk.api.rpc(Chats.Definition).confirm(input)
}
