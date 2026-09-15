import { describe, expect, test } from "bun:test"
import { resolveNewSessionBranch, resolveNewSessionGit, resolveNewSessionWorktree } from "./controller"

describe("new session workspace selection", () => {
  test("keeps explicit destinations authoritative over availability and defaults", () => {
    expect(resolveNewSessionWorktree({ enabled: false, selected: "/project/feature", fallback: "main" })).toBe(
      "/project/feature",
    )
    expect(resolveNewSessionWorktree({ enabled: false, selected: "/project/feature", fallback: "create" })).toBe(
      "/project/feature",
    )
    expect(resolveNewSessionWorktree({ enabled: true, selected: "main", fallback: "create" })).toBe("main")
    expect(resolveNewSessionWorktree({ enabled: false, selected: "create", fallback: "main" })).toBe("create")
  })

  test("uses availability and defaults only when the draft has no destination", () => {
    expect(resolveNewSessionWorktree({ enabled: false, fallback: "create" })).toBe("main")
    expect(resolveNewSessionWorktree({ enabled: true, fallback: "create" })).toBe("create")
  })

  test("resolves the branch from the active location", () => {
    const branch = (worktree: string) => (worktree === "/project/feature" ? "feature" : undefined)
    expect(resolveNewSessionBranch({ worktree: "main", directory: "/project/feature", worktreeBranch: branch })).toBe(
      "feature",
    )
    expect(resolveNewSessionBranch({ worktree: "create", directory: "/project/feature", worktreeBranch: branch })).toBe(
      "feature",
    )
    expect(
      resolveNewSessionBranch({ worktree: "/project/feature", directory: "/project", worktreeBranch: branch }),
    ).toBe("feature")
    expect(
      resolveNewSessionBranch({ worktree: "/missing", directory: "/project/feature", worktreeBranch: branch }),
    ).toBe(undefined)
  })

  test("uses a selected branch for a new workspace", () => {
    expect(
      resolveNewSessionBranch({
        worktree: "create",
        directory: "/project/feature",
        createBranch: "release",
        worktreeBranch: () => "feature",
      }),
    ).toBe("release")
  })

  test("uses location VCS state when the project inventory is stale", () => {
    expect(resolveNewSessionGit({ branch: "dev" })).toBe(true)
    expect(resolveNewSessionGit({ projectVcs: "git" })).toBe(true)
    expect(resolveNewSessionGit({})).toBe(false)
  })
})
