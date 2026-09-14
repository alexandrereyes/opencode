import type { SessionInfo, SessionMessageUser } from "@opencode/client/promise"
import { useComposerState } from "@/composer/persistence"
import { useData } from "@/runtime/server/current"
import { useServerSDK } from "@/runtime/server/client"
import { useWorkspaceLocation } from "@/workspaces/location"
import { useLanguage } from "@/runtime/i18n/language"
import { extractPromptComments, extractPromptFromMessage } from "@/composer/prompt"
import { readChatQuotes } from "@/composer/chat-quote"
import { showToast } from "@/shell/notifications/toast"

type SessionApi = ReturnType<typeof useServerSDK>["api"]["session"]
type MessageList = ReturnType<typeof useServerSDK>["api"]["message"]["list"]
type RevertApi = Pick<SessionApi, "interrupt" | "wait"> & { revert: Pick<SessionApi["revert"], "stage"> }
type RevertCascade = {
  sessions: (input: { parentID: string; cursor?: string }) => Promise<{
    data: SessionInfo[]
    cursor: { next?: string | null }
  }>
  messages: MessageList
  status: (sessionID: string) => "idle" | "busy"
}
type RevertInput = {
  session: {
    identity: { params: { id?: string } }
    history: { userMessages: () => SessionMessageUser[] }
    data: { revertMessageID: () => string | undefined }
  }
  setActiveMessage: (message: SessionMessageUser | undefined) => void
}
type RevertEnvironment = {
  prompt: Pick<ReturnType<typeof useComposerState>, "capture">
  api: Pick<SessionApi, "interrupt" | "wait"> & {
    revert: Pick<SessionApi["revert"], "stage" | "clear">
    inbox: Pick<SessionApi["inbox"], "list" | "cancel">
  }
  pending: Pick<ReturnType<typeof useData>["session"]["pending"], "list">
  directory: () => string
  failed: (error: unknown) => void
  cascade?: RevertCascade
}

export async function stageSessionRevert(
  api: RevertApi,
  input: { sessionID: string; messageID: SessionMessageUser["id"]; files?: boolean },
) {
  await api.interrupt({ sessionID: input.sessionID })
  await api.wait({ sessionID: input.sessionID })
  await api.revert.stage(input)
}

export function createSessionRevert(input: RevertInput) {
  const prompt = useComposerState()
  const server = useServerSDK()
  const data = useData()
  const location = useWorkspaceLocation()
  const language = useLanguage()
  return createSessionRevertActions(input, {
    prompt,
    api: server.api.session,
    pending: data.session.pending,
    directory: () => location().directory,
    cascade: {
      sessions: ({ parentID, cursor }) =>
        server.api.session.list(cursor ? { cursor } : { parentID, limit: 100, order: "asc" }),
      messages: server.api.message.list,
      status: (sessionID) => (data.session.status(sessionID) === "idle" ? "idle" : "busy"),
    },
    failed: (error) =>
      showToast({
        title: language.t("common.requestFailed"),
        description: error instanceof Error ? error.message : String(error),
      }),
  })
}

export function createSessionRevertActions(input: RevertInput, environment: RevertEnvironment) {
  const prompt = environment.prompt

  const request = async (action: () => Promise<unknown>) =>
    action()
      .then(() => true)
      .catch((error) => {
        environment.failed(error)
        return false
      })
  const restore = (target: ReturnType<typeof prompt.capture>, message: SessionMessageUser) => {
    target.quotes.replace(readChatQuotes(message.metadata?.quotes))
    target.set(
      extractPromptFromMessage(message, {
        directory: environment.directory(),
      }),
    )
    target.context.replaceComments(
      extractPromptComments(message).map((comment) => ({
        type: "file",
        path: comment.path,
        selection: comment.selection,
        comment: comment.comment,
        preview: comment.preview,
        commentOrigin: comment.origin,
      })),
    )
  }

  const stage = async (sessionID: string, message: SessionMessageUser) => {
    await cascadeRevert(sessionID, message.time.created, environment)
    if (!(await request(() => stageSessionRevert(environment.api, { sessionID, messageID: message.id })))) return false
    // Pending prompts were written against the history being rewound. Keep
    // their conservative cutoff and finish cancelling the captured set before
    // releasing submissions waiting on this revert.
    const cutoff = Date.now()
    const local = environment.pending
      .list(sessionID)
      .filter((item) => item.type === "user")
      .map((item) => item.id)
    const authoritative = await environment.api.inbox
      .list({ sessionID })
      .then((rows) => rows.filter((row) => row.type === "user" && row.timeCreated <= cutoff).map((row) => row.id))
      .catch(() => [])
    await Promise.all(
      [...new Set([...local, ...authoritative])].map((inboxID) =>
        environment.api.inbox.cancel({ sessionID, inboxID }).catch(() => undefined),
      ),
    )
    return true
  }

  const project = (message: SessionMessageUser, previous: SessionMessageUser | undefined) => {
    const target = prompt.capture()
    target.revert.prepare()
    restore(target, message)
    input.setActiveMessage(previous)
    return target.revert
  }

  const to = (messageID: string) => {
    const sessionID = input.session.identity.params.id
    if (!sessionID) return Promise.resolve(false)
    const messages = input.session.history.userMessages()
    const index = messages.findIndex((message) => message.id === messageID)
    const message = messages[index]
    if (!message) return Promise.resolve(false)
    return project(message, messages[index - 1]).schedule(message.id, () => stage(sessionID, message))
  }

  const undo = () => {
    const sessionID = input.session.identity.params.id
    if (!sessionID) return Promise.resolve(false)
    const messages = input.session.history.userMessages()
    const reverted = effectiveBoundary(messages)
    const boundaryIndex = reverted ? messages.findIndex((message) => message.id === reverted) : messages.length
    if (boundaryIndex <= 0) return Promise.resolve(false)
    const message = messages[boundaryIndex - 1]
    if (!message) return Promise.resolve(false)
    return project(message, messages[boundaryIndex - 2]).schedule(message.id, () => stage(sessionID, message))
  }

  const redo = () => {
    const sessionID = input.session.identity.params.id
    const target = prompt.capture()
    const messages = input.session.history.userMessages()
    const reverted = effectiveBoundary(messages)
    if (!sessionID || !reverted) return Promise.resolve(false)
    const boundaryIndex = messages.findIndex((message) => message.id === reverted)
    if (boundaryIndex < 0) return Promise.resolve(false)
    const next = messages[boundaryIndex + 1]
    if (next) return project(next, messages[boundaryIndex]).schedule(next.id, () => stage(sessionID, next))
    target.revert.prepare()
    target.reset()
    target.context.replaceComments([])
    input.setActiveMessage(messages.at(-1))
    return target.revert.schedule(undefined, async () => {
      await cascadeClear(sessionID, environment)
      if (!(await request(() => environment.api.revert.clear({ sessionID })))) return false
      return true
    })
  }

  const effectiveBoundary = (messages = input.session.history.userMessages()) =>
    prompt
      .capture()
      .revert.boundary(input.session.data.revertMessageID(), (messageID) =>
        messages.some((message) => message.id === messageID),
      )
  const canUndo = () => {
    if (!input.session.identity.params.id) return false
    const messages = input.session.history.userMessages()
    const reverted = effectiveBoundary(messages)
    return (reverted ? messages.findIndex((message) => message.id === reverted) : messages.length) > 0
  }

  return {
    to,
    undo,
    redo,
    pending: () => prompt.capture().revert.pending(),
    wait: () => prompt.capture().revert.wait(),
    boundary: effectiveBoundary,
    canUndo,
  }
}

export type SessionRevert = ReturnType<typeof createSessionRevert>

async function cascadeRevert(rootID: string, cutoff: number, environment: RevertEnvironment) {
  const cascade = environment.cascade
  if (!cascade) return
  const descendants = await descendantSessions(rootID, environment)
  for (const session of descendants) {
    try {
      const message = await firstUserMessageAtOrAfter(session.id, cutoff, cascade)
      if (!message) continue
      if (cascade.status(session.id) !== "idle") {
        await environment.api.interrupt({ sessionID: session.id })
        await environment.api.wait({ sessionID: session.id })
      }
      await environment.api.revert.stage({ sessionID: session.id, messageID: message.id, files: false })
    } catch (error) {
      environment.failed(error)
    }
  }
}

async function cascadeClear(rootID: string, environment: RevertEnvironment) {
  const cascade = environment.cascade
  if (!cascade) return
  const descendants = await descendantSessions(rootID, environment)
  for (const session of descendants) {
    if (!session.revert) continue
    try {
      if (cascade.status(session.id) !== "idle") {
        await environment.api.interrupt({ sessionID: session.id })
        await environment.api.wait({ sessionID: session.id })
      }
      await environment.api.revert.clear({ sessionID: session.id })
    } catch (error) {
      environment.failed(error)
    }
  }
}

async function descendantSessions(rootID: string, environment: RevertEnvironment) {
  if (!environment.cascade) return []
  const result: SessionInfo[] = []
  const pending = [rootID]
  const visited = new Set(pending)
  for (const parentID of pending) {
    const children: SessionInfo[] = []
    try {
      let cursor: string | undefined
      do {
        const page = await environment.cascade.sessions({ parentID, cursor })
        children.push(
          ...page.data.filter((session) => {
            if (visited.has(session.id)) return false
            visited.add(session.id)
            return true
          }),
        )
        cursor = page.cursor.next ?? undefined
      } while (cursor)
    } catch (error) {
      environment.failed(error)
    }
    result.push(...children)
    pending.push(...children.map((session) => session.id))
  }
  return result
}

async function firstUserMessageAtOrAfter(sessionID: string, cutoff: number, cascade: RevertCascade) {
  let cursor: string | undefined
  do {
    const page = await cascade.messages(
      cursor ? { sessionID, cursor, type: "user" } : { sessionID, limit: 200, order: "asc", type: "user" },
    )
    const message = page.data.find(
      (item): item is SessionMessageUser => item.type === "user" && item.time.created >= cutoff,
    )
    if (message) return message
    cursor = page.cursor.next ?? undefined
  } while (cursor)
}
