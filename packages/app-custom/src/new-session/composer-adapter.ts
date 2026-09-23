import { base64Encode } from "@opencode/util/encode"
import type { SessionMessageUser } from "@opencode/client/promise"
import { Session } from "@opencode/schema/session"
import { startTransition } from "solid-js"
import { createStore } from "solid-js/store"
import type { NewSessionComposerAdapter } from "@/composer/adapter"
import { useComposerState } from "@/composer/persistence"
import { createComposerControls, createComposerModelSelection } from "@/composer/selection"
import { createComposerProjectControls } from "./project/controller"
import { useLanguage } from "@/runtime/i18n/language"
import { useLocal } from "@/providers/models/selection"
import { useData, useServer } from "@/runtime/server/current"
import { type ServerSDK, useServerSDK } from "@/runtime/server/client"
import { useTabs } from "@/shell/tabs/tabs"
import { useWorkspaceLocation } from "@/workspaces/location"
import { createWorktree } from "@/workspaces/create"
import { useSessionKey } from "@/session/session-layout"
import { showToast } from "@/shell/notifications/toast"
import { SessionRouteKey, SessionStateKey } from "@/runtime/server/scope"
import { clearSessionMessageHandoff, setSessionMessageHandoff } from "@/session/handoff"
import { claimChat, confirmChat } from "@/runtime/chats"
import type { DraftMcpControls } from "./mcp"

export function createNewSessionComposerAdapter(props: {
  draftID: string
  worktree: () => string
  branch: () => string | undefined
  submitted: () => void
  mcp: DraftMcpControls
}) {
  const route = useSessionKey()
  const prompt = useComposerState()
  const state = prompt.capture()
  const local = useLocal()
  const data = useData()
  const server = useServer()
  const serverSDK = useServerSDK()
  const tabs = useTabs()
  const location = useWorkspaceLocation()
  const language = useLanguage()
  const model = createComposerModelSelection({ agent: () => local.agent.current() })
  const controls = createComposerControls({ sessionKey: route.sessionKey, model })
  const [context, setContext] = createStore({ pending: false })

  const adapter: NewSessionComposerAdapter = {
    kind: "new-session",
    state,
    ready: prompt.ready,
    controls,
    working: () => context.pending,
    submitted: props.submitted,
    async start(selection, submission, message) {
      if (managedSessionBlocked(context.pending)) return
      const draftID = props.draftID
      const draft = tabs.draft(draftID)
      const currentDirectory = location().directory
      const projectDirectory = data.location.info({ directory: currentDirectory })?.project.canonical ?? currentDirectory
      const worktree = props.worktree()
      const branch = props.branch()
      const mcp = props.mcp.capture()
      const chat = draft.chat
      const id = chat ? Session.ID.make(chat.sessionID) : Session.ID.create()
      const pending = tabs.prepareSession(
        draftID,
        { server: server.key, sessionId: id, chat: !!chat || undefined },
        { message, selection },
      )
      await pending.ready
      const sessionDirectory = await resolveManagedSessionDirectory({
        chat: !!chat,
        projectDirectory,
        resolve: () => resolveSessionDirectory({ projectDirectory, worktree, branch, data, serverSDK, language }),
      })
      if (!sessionDirectory) {
        await pending.rollback()
        return
      }
      const rollback = async () => {
        if (worktree === "create") {
          data.project.invalidate()
          await data.project.sync().catch(() => undefined)
        }
        await pending.rollback(worktree === "create" ? sessionDirectory : undefined)
        if (worktree === "create") props.mcp.remember(sessionDirectory, mcp)
      }
      if (chat) {
        const claimed = await claimChat(serverSDK, {
          id: chat.allocationID,
          directory: sessionDirectory,
          sessionID: id,
        }).then(
          () => true,
          (error) => {
            showToast({
              variant: "error",
              title: language.t("session.new.chats.failed"),
              description: errorMessage(language, error),
            })
            return false
          },
        )
        if (!claimed) {
          await rollback()
          return
        }
      }
      if (!(await props.mcp.prepare(sessionDirectory, mcp))) {
        await rollback()
        return
      }

      const created = data.session.create({
        id,
        agent: selection.agent,
        model: {
          id: selection.model.modelID,
          providerID: selection.model.providerID,
          variant: selection.variant,
        },
        location: { directory: sessionDirectory },
      })
      const creation = created.request.then(
        () => ({ ok: true as const }),
        (error) => {
          showToast({
            title: language.t("prompt.toast.sessionCreateFailed.title"),
            description: errorMessage(language, error),
          })
          return { ok: false as const, error }
        },
      )
      if (!(await creation).ok) {
        await rollback()
        return
      }
      if (chat) {
        await confirmChat(serverSDK, {
          id: chat.allocationID,
          directory: sessionDirectory,
          sessionID: id,
        }).catch(() => undefined)
      }
      const afterCreation = async <T>(run: () => Promise<T>) => {
        const result = await creation
        if (!result.ok) throw result.error
        return run()
      }
      const sessionKey = SessionStateKey.from(
        serverSDK.scope,
        SessionRouteKey.fromRoute(base64Encode(sessionDirectory), created.id),
      )
      const cleanupReady = startTransition(() => {
        local.session.promote(sessionDirectory, created.id, {
          agent: selection.agent,
          model: selection.model,
          variant: selection.variant ?? null,
          choices: model.remembered(),
        })
        submission.retarget(
          prompt.capture(
            { dir: base64Encode(sessionDirectory), id: created.id },
            { server: server.key, scope: serverSDK.scope },
          ),
          { preserveDraft: true },
        )
      })

      return {
        cleanupReady,
        complete: () => pending.complete(submission.target()),
        session: {
          id: created.id,
          directory: sessionDirectory,
          handoff: createMessageHandoff(sessionKey, created.id, serverSDK.event),
          api: {
            command: (input) => afterCreation(() => serverSDK.api.session.command(input)),
            shell: (input) => afterCreation(() => serverSDK.api.session.shell(input)),
            switchAgent: (input) => afterCreation(() => serverSDK.api.session.switchAgent(input)),
            switchModel: (input) => afterCreation(() => serverSDK.api.session.switchModel(input)),
          },
          data: {
            location: data.location,
            session: {
              setStatus: data.session.setStatus,
              prompt: (input) =>
                data.session.prompt({
                  ...input,
                  gate: Promise.all([input.gate, afterCreation(async () => undefined)]),
                }),
            },
          },
          current: () => data.session.get(created.id),
          admitted: (messageID) =>
            data.session.input.has(created.id, messageID) || !!data.session.message.get(created.id, messageID),
        },
      }
    },
  }

  return {
    adapter,
    project: createComposerProjectControls({
      draftId: props.draftID,
      pending: () => context.pending,
      setPending: (pending) => setContext("pending", pending),
    }),
    model,
    ready: prompt.ready,
  }
}

export function managedSessionBlocked(contextPending: boolean) {
  return contextPending
}

export function resolveManagedSessionDirectory(input: {
  chat: boolean
  projectDirectory: string
  resolve: () => Promise<string | void | undefined>
}) {
  return input.chat ? Promise.resolve(input.projectDirectory) : input.resolve()
}

function createMessageHandoff(key: string, sessionID: string, event: ServerSDK["event"]) {
  let unsubscribe: VoidFunction | undefined
  return {
    set(message: SessionMessageUser) {
      unsubscribe?.()
      setSessionMessageHandoff(key, message)
      unsubscribe = event.on("session.inbox.enqueued", (item) => {
        if (item.data.sessionID !== sessionID || item.data.inboxID !== message.id) return
        unsubscribe?.()
        unsubscribe = undefined
        clearSessionMessageHandoff(key, message.id)
      })
    },
    clear(messageID: string) {
      unsubscribe?.()
      unsubscribe = undefined
      clearSessionMessageHandoff(key, messageID)
    },
  }
}

async function resolveSessionDirectory(input: {
  projectDirectory: string
  worktree: string
  branch?: string
  data: ReturnType<typeof useData>
  serverSDK: ReturnType<typeof useServerSDK>
  language: ReturnType<typeof useLanguage>
}) {
  if (input.worktree === "main") return input.projectDirectory
  if (input.worktree !== "create") return input.worktree

  return createWorktree({
    api: input.serverSDK.api,
    data: input.data,
    directory: input.projectDirectory,
    project: input.data.location.info({ directory: input.projectDirectory })?.project,
    branch: input.branch,
  }).catch((error) => {
    showToast({
      title: input.language.t("prompt.toast.worktreeCreateFailed.title"),
      description: errorMessage(input.language, error),
    })
  })
}

function errorMessage(language: ReturnType<typeof useLanguage>, error: unknown) {
  if (error && typeof error === "object" && "message" in error && typeof error.message === "string") {
    return error.message
  }
  if (error && typeof error === "object" && "data" in error) {
    const data = (error as { data?: { message?: string } }).data
    if (data?.message) return data.message
  }
  return language.t("common.requestFailed")
}
