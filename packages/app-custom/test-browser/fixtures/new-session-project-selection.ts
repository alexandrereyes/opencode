import { describe, expect, mock, test } from "bun:test"
import { createRoot } from "solid-js"
import type { PromptProjectControls } from "@/new-session/project/selector"

mock.module("@/runtime/i18n/language", () => ({ useLanguage: () => ({ t: (key: string) => key }) }))
const { createPromptProjectController } = await import("@/new-session/project/selector")

function selected(controls: Pick<PromptProjectControls, "available" | "directory" | "projectID" | "server">) {
  return createRoot((dispose) => {
    const project = createPromptProjectController({
      controls: () => ({
        ...controls,
        chat: false,
        pending: false,
        selectChat: async () => {},
        select() {},
        add() {},
      }),
      onDone() {},
    }).selected()
    dispose()
    return project
  })
}

describe("new session project selection", () => {
  test("selects the resolved project when the directory is not a listed root", () => {
    const other = { id: "other", worktree: "/other" }
    const current = { id: "current", worktree: "/repo", name: "My custom name" }
    expect(
      selected({ available: [other, current], directory: "/worktrees/repo-feature", projectID: "current" }),
    ).toEqual(current)
  })

  test("prefers an exact path match over the resolved project ID", () => {
    const main = { id: "shared", worktree: "/repo" }
    const feature = { id: "shared", worktree: "/repo/.opencode/worktree/feature" }
    expect(
      selected({ available: [main, feature], directory: "/repo/.opencode/worktree/feature", projectID: "shared" }),
    ).toEqual(feature)
  })

  test("prefers the most specific project sharing the resolved ID that contains the directory", () => {
    const sibling = { id: "shared", worktree: "/worktrees/repo-other" }
    const main = { id: "shared", worktree: "/repo" }
    expect(
      selected({ available: [sibling, main], directory: "/repo/.opencode/worktree/feature", projectID: "shared" }),
    ).toEqual(main)
  })

  test("does not select a matching project ID from another server", () => {
    const remote = { id: "shared", worktree: "/remote", server: { key: "remote", name: "Remote" } }
    const local = { id: "shared", worktree: "/local", server: { key: "local", name: "Local" } }
    expect(
      selected({ available: [remote, local], directory: "/local/feature", projectID: "shared", server: "local" }),
    ).toEqual(local)
  })
})
