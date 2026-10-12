import { describe, expect, test } from "bun:test"
import { runningItems, runningLabel } from "./running-work"

const agents: Record<string, string> = { ses_child: "explore", ses_sibling: "general" }
const agent = (id: string | undefined) => (id ? agents[id] : undefined)

describe("running work", () => {
  test("lists foreground subagents, background subagents and background shells, but no foreground shells", () => {
    const items = runningItems(
      {
        sessionID: "ses_parent",
        owner: "ses_parent",
        blocking: [
          { type: "subagent", partID: "prt_child", id: "ses_child", label: "Explore code" },
          { type: "subagent", partID: "prt_starting", label: "Starting" },
          { type: "shell", partID: "prt_shell", id: "shl_foreground", label: "bun test" },
        ],
        tasks: [
          { id: "ses_sibling", type: "subagent", label: "Review" },
          { id: "shl_server", type: "shell", label: "bun dev" },
        ],
      },
      agent,
    )
    expect(items).toEqual([
      {
        type: "subagent",
        label: "Explore code",
        key: "ses_child",
        agent: "explore",
        sessionID: "ses_child",
        target: "prt_child",
      },
      {
        type: "subagent",
        label: "Starting",
        key: "prt_starting",
        agent: undefined,
        sessionID: undefined,
        target: "prt_starting",
      },
      {
        type: "subagent",
        label: "Review",
        key: "ses_sibling",
        agent: "general",
        sessionID: "ses_sibling",
        target: "ses_sibling",
      },
      { type: "shell", label: "bun dev", key: "shl_server", target: "shl_server" },
    ])
  })

  test("counts working subagents, and running work once a shell is involved", () => {
    const subagents = runningItems(
      { blocking: [], tasks: [{ id: "ses_child", type: "subagent", label: "Explore" }] },
      agent,
    )
    expect(runningLabel(subagents, "ses_parent", "all")).toEqual({ key: "session.running.working", count: 1 })
    const mixed = runningItems(
      {
        blocking: [],
        tasks: [
          { id: "ses_child", type: "subagent", label: "Explore" },
          { id: "shl_server", type: "shell", label: "bun dev" },
        ],
      },
      agent,
    )
    expect(runningLabel(mixed, "ses_parent", "all")).toEqual({ key: "session.running.running", count: 2 })
    expect(runningLabel([], "ses_parent", "all")).toBeUndefined()
  })

  test("inside a subagent, counts only the other work and hides the count when nothing else runs", () => {
    const items = runningItems(
      {
        sessionID: "ses_child",
        owner: "ses_parent",
        blocking: [],
        tasks: [
          { id: "ses_child", type: "subagent", label: "Explore" },
          { id: "ses_sibling", type: "subagent", label: "Review" },
        ],
      },
      agent,
    )
    expect(runningLabel(items, "ses_child", "additional")).toEqual({
      key: "session.running.additionalWorking",
      count: 1,
    })
    expect(runningLabel(items, "ses_child", "others")).toEqual({ key: "session.running.working", count: 1 })
    expect(runningLabel(items.slice(0, 1), "ses_child", "additional")).toBeUndefined()
    expect(runningLabel(items.slice(0, 1), "ses_child", "others")).toBeUndefined()
    expect(runningLabel(items.slice(0, 1), "ses_child", "all")).toBeUndefined()
  })
})
