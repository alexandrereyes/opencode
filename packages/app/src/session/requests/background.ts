import type { SessionInfo, SessionMessageAssistant, SessionMessageInfo, ShellInfo } from "@opencode/client/promise"
import { createMemo } from "solid-js"

type Task =
  | { id: string; type: "subagent"; label: string; agent?: string }
  | { id: string; type: "shell"; label: string }

export function createSessionBackground(input: {
  sessionID: () => string | undefined
  messages: (id: string) => SessionMessageInfo[]
  sessions: () => SessionInfo[]
  status: (id: string) => "idle" | "running"
  shells: () => ShellInfo[]
}) {
  const history = createMemo(() => {
    const subagents: { id: string; type: "subagent"; label: string; agent: string | undefined }[] = []
    const id = input.sessionID()
    const assistant = (id ? input.messages(id) : []).reduce<SessionMessageAssistant | undefined>((latest, message) => {
      if (message.type !== "assistant") return latest
      message.content.forEach((part) => {
        if (part.type !== "tool" || part.name !== "subagent") return
        if (part.state.status !== "completed" || part.state.metadata?.status !== "running") return
        const sessionID = part.state.metadata.sessionID
        if (typeof sessionID !== "string") return
        const description = part.state.input.description
        const agent = part.state.input.agent
        subagents.push({
          id: sessionID,
          type: "subagent",
          label: typeof description === "string" ? description : sessionID,
          agent: typeof agent === "string" ? agent : undefined,
        })
      })
      return message.time.completed === undefined ? message : latest
    }, undefined)

    return {
      subagents,
      blocking:
        assistant?.content.flatMap((part) => {
          if (part.type !== "tool" || part.state.status !== "running") return []
          if (part.name !== "shell" && part.name !== "subagent") return []
          const value = part.name === "shell" ? part.state.metadata.shellID : part.state.metadata.sessionID
          const label = part.name === "shell" ? part.state.input.command : part.state.input.description
          return [
            {
              type: part.name as "shell" | "subagent",
              partID: part.id,
              id: typeof value === "string" ? value : undefined,
              label: typeof label === "string" ? label : undefined,
            },
          ]
        }) ?? [],
    }
  })
  const blocking = createMemo(() => history().blocking)
  const unresolved = createMemo(() => {
    const id = input.sessionID()
    if (!id) return []
    const sessions = new Set(input.sessions().map((session) => session.id))
    return [
      ...new Set(
        history().subagents.flatMap((task) =>
          input.status(task.id) === "running" && !sessions.has(task.id) ? [task.id] : [],
        ),
      ),
    ]
  })
  const tasks = createMemo(() => {
    const id = input.sessionID()
    if (!id) return []
    const current = history()
    const blocked = (type: Task["type"], taskID: string, label: string) =>
      current.blocking.some(
        (item) => item.type === type && (item.id !== undefined ? item.id === taskID : !!item.label && item.label === label),
      )
    // A completed tool with metadata.status=running only records that it was backgrounded.
    // Runtime state is the authority for whether that work is still active.
    const owners = new Map(input.sessions().map((session) => [session.id, session]))
    const discovered = current.subagents.filter(
      (task) =>
        input.status(task.id) === "running" && owners.get(task.id)?.parentID === id && !blocked(task.type, task.id, task.label),
    )
    const active = input.sessions().flatMap((info) => {
      if (info?.parentID !== id) return []
      if (input.status(info.id) !== "running") return []
      if (blocked("subagent", info.id, info.title ?? info.id)) return []
      return [{ id: info.id, type: "subagent" as const, label: info.title ?? info.id }]
    })
    const running = input.shells().flatMap((shell) => {
      if (shell.status !== "running" || shell.metadata.sessionID !== id) return []
      if (blocked("shell", shell.id, shell.command)) return []
      return [{ id: shell.id, type: "shell" as const, label: shell.command }]
    })
    return [
      ...new Map<string, Task>(
        [...discovered, ...active, ...running].map((task) => [task.id, task]),
      ).values(),
    ]
  })
  return { blocking, tasks, unresolved }
}
