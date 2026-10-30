import type { SessionMessage } from "@opencode/schema/session-message"

/**
 * Progresso: the agent's list of the Core `todowrite` tool (behind `experimental.todo`). Core keeps no state of its
 * own: the current list is the input of the session's latest completed call before its revert boundary. Every rule
 * here copies upstream's web (`packages/app/src/session/composer/todos.ts` and `region.tsx`); `docs/progress.md`.
 */
export const tool = "todowrite"

export type Status = "pending" | "in_progress" | "completed" | "cancelled"
export type Todo = { readonly content: string; readonly status: Status }

/** The numbers and the item the apps, the Live Activity and Mestra show. */
export type Summary = {
  /** Completed items: the `3` of `3/7`. */
  readonly done: number
  /** Completed and cancelled items: the ring's fill. */
  readonly finished: number
  readonly total: number
  /** The item in hand: the one in progress, else the next pending one, else the last completed one. */
  readonly current: string
}

const statuses = new Set<unknown>(["pending", "in_progress", "completed", "cancelled"])

/** Items with a non-empty `content`; an unknown status reads as pending. */
export function parse(value: unknown): Todo[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item: unknown) => {
    if (typeof item !== "object" || item === null || !("content" in item) || typeof item.content !== "string") return []
    if (!item.content) return []
    const status = "status" in item && statuses.has(item.status) ? (item.status as Status) : "pending"
    return [{ content: item.content, status }]
  })
}

/**
 * The list of the latest completed `todowrite` among `messages`, given newest first, ignoring the revert boundary
 * message and everything after it. `undefined` when no completed call is among them (a page may not reach one).
 */
export function latest(messages: readonly SessionMessage.Info[], boundary?: string): Todo[] | undefined {
  const start = boundary === undefined ? 0 : messages.findIndex((message) => message.id === boundary) + 1
  // A boundary outside the messages read hides all of them.
  if (start === 0 && boundary !== undefined) return undefined
  for (const message of messages.slice(start)) {
    if (message.type !== "assistant") continue
    const part = message.content.findLast(
      (item) => item.type === "tool" && item.name === tool && item.state.status === "completed",
    )
    if (part?.type === "tool" && part.state.status === "completed") return parse(part.state.input.todos)
  }
  return undefined
}

export const finished = (todo: Todo) => todo.status === "completed" || todo.status === "cancelled"

/** The todo the agent is on: the one in progress, else the next pending one, else the last finished one. */
export function current(todos: readonly Todo[]) {
  return (
    todos.find((todo) => todo.status === "in_progress") ??
    todos.find((todo) => todo.status === "pending") ??
    todos.findLast((todo) => todo.status === "completed") ??
    todos[0]
  )
}

/** The summary of a list that still has work left; `undefined` for an empty list or one with every item finished. */
export function summarize(todos: readonly Todo[]): Summary | undefined {
  if (todos.length === 0 || todos.every(finished)) return undefined
  return {
    done: todos.filter((todo) => todo.status === "completed").length,
    finished: todos.filter(finished).length,
    total: todos.length,
    current: current(todos)?.content ?? "",
  }
}
