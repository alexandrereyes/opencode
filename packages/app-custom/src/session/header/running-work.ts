export type RunningWork = {
  sessionID?: string
  // The session whose running work is listed: this one, or its parent inside a subagent.
  owner?: string
  blocking: readonly { type: "shell" | "subagent"; partID: string; id?: string; label?: string }[]
  tasks: readonly { id: string; type: "shell" | "subagent"; label: string; agent?: string }[]
}

export type RunningItem = {
  key: string
  type: "subagent" | "shell"
  label?: string
  agent?: string
  sessionID?: string
  // The tool call or shell the owner's timeline reveals for this item.
  target: string
}

// Foreground shells stay out: the timeline already shows them at the bottom.
export function runningItems(work: RunningWork, agent: (sessionID: string | undefined) => string | undefined) {
  return [
    ...work.blocking.flatMap((task): RunningItem[] =>
      task.type === "subagent"
        ? [
            {
              type: "subagent",
              label: task.label,
              key: task.id ?? task.partID,
              agent: agent(task.id),
              sessionID: task.id,
              target: task.partID,
            },
          ]
        : [],
    ),
    ...work.tasks.flatMap((task): RunningItem[] =>
      task.type === "subagent"
        ? [
            {
              type: "subagent",
              label: task.label,
              key: task.id,
              agent: task.agent ?? agent(task.id),
              sessionID: task.id,
              target: task.id,
            },
          ]
        : [],
    ),
    ...work.tasks.flatMap((task): RunningItem[] =>
      task.type === "shell" ? [{ type: "shell", label: task.label, key: task.id, target: task.id }] : [],
    ),
  ]
}

/**
 * The trigger's count. `all` counts everything, hidden when the only item is the viewed session; `additional`
 * (a subagent's title) and `others` (the phone navigation) count the items besides the viewed session.
 */
export function runningLabel(
  items: RunningItem[],
  sessionID: string | undefined,
  mode: "all" | "additional" | "others",
) {
  const viewing = (item: RunningItem) => !!item.sessionID && item.sessionID === sessionID
  const count = mode === "all" ? items.length : items.filter((item) => !viewing(item)).length
  if (!count || (mode === "all" && count === 1 && viewing(items[0]))) return
  const shell = items.some((item) => item.type === "shell")
  if (mode === "additional")
    return { key: shell ? "session.running.additionalRunning" : "session.running.additionalWorking", count } as const
  return { key: shell ? "session.running.running" : "session.running.working", count } as const
}
