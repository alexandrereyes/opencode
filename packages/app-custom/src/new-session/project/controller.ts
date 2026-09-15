import { createMemo, createResource } from "solid-js"
import { useDirectoryPicker } from "@/workspaces/selection/picker"
import { useGlobal, useServerCtx } from "@/runtime/server/runtime"
import { useServerSDK } from "@/runtime/server/client"
import { serverName, ServerConnection, useServers } from "@/runtime/server/registry"
import { useWorkspaceLocation } from "@/workspaces/location"
import { useTabs } from "@/shell/tabs/tabs"
import type { PromptProjectControls } from "./selector"
import { allocateChat, chatCapability, isChatDirectory, knownChatRoot } from "@/runtime/chats"
import { useLanguage } from "@/runtime/i18n/language"
import { showToast } from "@/shell/notifications/toast"
import { Session } from "@opencode/schema/session"

export function createComposerProjectControls(props: {
  draftId: string
  pending: () => boolean
  setPending: (pending: boolean) => void
}) {
  const servers = useServers()
  const serverSDK = useServerSDK()
  const location = useWorkspaceLocation()
  const tabs = useTabs()
  const global = useGlobal()
  const language = useLanguage()
  const pickDirectory = useDirectoryPicker()
  const projectServer = () => serverSDK.server
  const projectServerCtx = useServerCtx(projectServer)
  const capability = chatCapability(serverSDK)
  createResource(
    () => (serverSDK.connection.status() === "connected" ? serverSDK.connection.epoch() + 1 : undefined),
    () => capability.retry(),
  )
  const projects = createMemo(() => {
    if (servers.list.length <= 1)
      return projectServerCtx()
        .projects.list()
        .filter((project) => !isChatDirectory(project.worktree, capability.state.root))
    return servers.list.flatMap((connection) => {
      const server = { key: ServerConnection.key(connection), name: serverName(connection) }
      return global
        .ensureServerCtx(connection)
        .projects.list()
        .filter((project) => !isChatDirectory(project.worktree, knownChatRoot(global.ensureServerCtx(connection).sdk)))
        .map((project) => ({ ...project, server }))
    })
  })
  const selection = createChatSelectionCoordinator({
    capture: () => {
      const draft = tabs.draft(props.draftId)
      return { draftID: draft.draftID, server: draft.server }
    },
    allocate: async (target) => {
      const connection = servers.list.find((item) => ServerConnection.key(item) === target.server)
      if (!connection) throw new Error(language.t("session.new.chats.unavailable"))
      return allocateChat(global.ensureServerCtx(connection).sdk)
    },
    apply: (target, allocation) =>
      tabs.updateDraft(target.draftID, {
        server: target.server,
        directory: allocation.directory,
        worktree: undefined,
        branch: undefined,
        chat: { allocationID: allocation.id, sessionID: Session.ID.create() },
      }),
    setPending: props.setPending,
    onError: (error) =>
      showToast({
        variant: "error",
        title: language.t("session.new.chats.failed"),
        description: error instanceof Error ? error.message : language.t("common.requestFailed"),
      }),
  })
  const selectProject = (worktree: string, serverKey?: string) => {
    selection.cancel()
    const connection = serverKey
      ? servers.list.find((item) => ServerConnection.key(item) === serverKey)
      : projectServer()
    if (!connection) return
    const target = global.ensureServerCtx(connection)
    target.projects.open(worktree)
    target.projects.touch(worktree)
    tabs.updateDraft(props.draftId, {
      server: ServerConnection.key(connection),
      directory: worktree,
      worktree: undefined,
      branch: undefined,
      chat: undefined,
    })
  }
  const addProject = (title: string, serverKey?: string) => {
    const connection = serverKey
      ? servers.list.find((item) => ServerConnection.key(item) === serverKey)
      : projectServer()
    if (!connection) return
    pickDirectory({
      server: connection,
      location: ServerConnection.key(connection) === ServerConnection.key(projectServer()) ? location().ref : undefined,
      title,
      onSelect: (result) => {
        const directory = Array.isArray(result) ? result[0] : result
        if (directory) selectProject(directory, serverKey)
      },
    })
  }

  return createMemo<PromptProjectControls>(() => ({
    available: projects(),
    directory: location().directory,
    server: servers.list.length > 1 ? ServerConnection.key(projectServer()) : undefined,
    chat: !!tabs.draft(props.draftId).chat,
    chatAvailable: capability.state.status === "available",
    pending: props.pending(),
    selectChat: selection.select,
    select: selectProject,
    add: addProject,
  }))
}

export function createChatSelectionCoordinator<T extends { draftID: string; server: string }>(input: {
  capture: () => T
  allocate: (target: T) => Promise<{ id: string; directory: string }>
  apply: (target: T, allocation: { id: string; directory: string }) => Promise<unknown>
  setPending: (pending: boolean) => void
  onError: (error: unknown) => void
}) {
  let version = 0
  let active: Promise<void> | undefined
  const same = (a: T, b: T) => a.draftID === b.draftID && a.server === b.server
  return {
    select() {
      if (active) return active
      const target = input.capture()
      const current = ++version
      input.setPending(true)
      active = input
        .allocate(target)
        .then(async (allocation) => {
          if (current !== version || !same(target, input.capture())) return
          await input.apply(target, allocation)
        })
        .catch((error) => {
          if (current === version) input.onError(error)
        })
        .finally(() => {
          if (current !== version) return
          active = undefined
          input.setPending(false)
        })
      return active
    },
    cancel() {
      version++
      active = undefined
      input.setPending(false)
    },
  }
}
