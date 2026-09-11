import { expect, test } from "bun:test"
import type { LocationGetOutput } from "@opencode/client/promise"
import { ServerConnection } from "@/runtime/server/registry"
import { projectKey, rootSessions, sessionKey, sidebarProjects, type SidebarSession } from "./sidebar-model"
import { sidebarWorktrees, visibleWorktreeSessions, worktreeKey } from "./sidebar-worktrees"

const server = ServerConnection.Key.make("http://localhost:1234")
function row(id: string, directory: string, projectID = "repo", host = server): SidebarSession {
  return {
    key: sessionKey(host, id),
    server: host,
    project: projectKey(host, { id: projectID, worktree: directory }),
    session: {
      id,
      projectID,
      title: id,
      location: { directory },
      time: { created: 1, updated: 1 },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  }
}
const project = sidebarProjects(server, [{ id: "repo", worktree: "/repo", vcs: "git" }], [row("root", "/repo")])[0]
const metadata = {
  inventory: [{ directory: "/repo" }, { directory: "/trees/feat" }, { directory: "/repo/nested" }],
  location: (_directory: string): LocationGetOutput | undefined => undefined,
  branch: (directory: string) => (directory === "/trees/feat" ? "feat/payments" : undefined),
}

test("canonical root and its subdirectories never acquire a main accordion across cold, loaded and reconnect snapshots", () => {
  const rows = [row("root", "/repo"), row("sub", "/repo/src"), row("linked-main", "/trees/main")]
  for (const inventory of [undefined, [{ directory: "/repo" }, { directory: "/trees/main" }], undefined]) {
    const grouped = sidebarWorktrees(project, rows, { ...metadata, inventory, branch: () => "main" })
    expect(grouped.root.map((row) => row.session.id)).toEqual(["root", "sub"])
    expect(grouped.groups).toHaveLength(1)
    expect(grouped.groups[0].directory).toBe("/trees/main")
    expect(grouped.groups[0].name).toBe("main")
  }
})

test("canonical root (on any branch), subdirectories, nested worktrees and safe path boundaries", () => {
  const rows = [
    row("root", "/repo"),
    row("sub", "/repo/src"),
    row("feat", "/trees/feat"),
    row("deep", "/trees/feat/src"),
    row("nested", "/repo/nested/src"),
    row("prefix", "/trees/feature"),
    row("sibling", "/repo-other"),
  ]
  const group = sidebarWorktrees(project, rows, metadata)
  expect(group.root.map((row) => row.session.id)).toEqual(["root", "sub"])
  expect(group.groups.find((group) => group.directory === "/trees/feat")?.rows.map((row) => row.session.id)).toEqual([
    "feat",
    "deep",
  ])
  expect(group.groups.find((group) => group.directory === "/trees/feat")?.name).toBe("feat/payments")
  expect(group.groups.find((group) => group.directory === "/repo/nested")?.rows.map((row) => row.session.id)).toEqual([
    "nested",
  ])
  expect(group.groups.find((group) => group.directory === "/trees/feature")?.name).toBe("feature")
  expect(group.groups.find((group) => group.directory === "/repo-other")?.name).toBe("repo-other")
})

test("incremental inventory/Location/branch never loses rows; unavailable and detached labels stay truthful", () => {
  const rows = [row("sub", "/trees/feat/src"), row("root", "/repo"), row("unknown", "/gone/feat")]
  const cold = sidebarWorktrees(project, rows, { ...metadata, inventory: undefined })
  expect(cold.root.map((row) => row.session.id)).toEqual(["root"])
  expect(cold.groups.find((group) => group.directory === "/trees/feat/src")?.name).toBe("src")
  const location = (directory: string) =>
    directory === "/trees/feat/src"
      ? { directory, project: { id: "repo", canonical: "/repo", directory: "/trees/feat" } }
      : undefined
  const located = sidebarWorktrees(project, rows, { ...metadata, inventory: undefined, location, branch: () => "HEAD" })
  const ready = sidebarWorktrees(project, rows, metadata)
  for (const group of [cold, located, ready]) {
    expect([...group.root, ...group.groups.flatMap((item) => item.rows)].map((row) => row.key).sort()).toEqual(
      rows.map((row) => row.key).sort(),
    )
  }
  expect(located.groups.find((group) => group.directory === "/trees/feat")?.name).toBe("feat")
  expect(located.groups.map((group) => group.key)).toEqual(ready.groups.map((group) => group.key))
})

test("same basename/branch, foreign project/server and foreign Location metadata cannot merge", () => {
  const other = ServerConnection.Key.make("https://remote.test")
  const rows = [
    row("a", "/a/feat"),
    row("b", "/b/feat"),
    row("foreign", "/a/feat", "other"),
    row("remote", "/a/feat", "repo", other),
  ]
  const group = sidebarWorktrees(project, rows, {
    inventory: [{ directory: "/a/feat" }, { directory: "/b/feat" }],
    branch: () => "same-branch",
    location: (directory) => ({ directory, project: { id: "other", canonical: "/other", directory: "/a/feat" } }),
  })
  expect(group.groups).toHaveLength(2)
  expect(group.groups.map((group) => group.name)).toEqual(["same-branch", "same-branch"])
  expect(new Set(group.groups.map((group) => group.key)).size).toBe(2)
  expect(group.groups.flatMap((group) => group.rows).map((row) => row.session.id)).toEqual(["a", "b"])
  expect(worktreeKey(project.key, "/a/feat/")).toBe(worktreeKey(project.key, "/a/feat"))
  expect(worktreeKey(project.key, "C:\\Trees\\Feat")).toBe(worktreeKey(project.key, "c:/trees/feat/"))
  expect(worktreeKey(project.key, "/a/feat")).not.toBe(
    worktreeKey(projectKey(other, { id: "repo", worktree: "/repo" }), "/a/feat"),
  )
})

test("visible order uses subgroup caps; subgroup collapse hides rows and project collapse retains the approved current escape", () => {
  const rows = [
    ...Array.from({ length: 7 }, (_, i) => row(`r${i}`, "/repo")),
    ...Array.from({ length: 8 }, (_, i) => row(`f${i}`, "/trees/feat")),
  ]
  const group = sidebarWorktrees(project, rows, metadata)
  const key = group.groups[0].key
  expect(visibleWorktreeSessions(group, project.key, {}, {}).map((row) => row.session.id)).toEqual([
    "r0",
    "r1",
    "r2",
    "r3",
    "r4",
    "f0",
    "f1",
    "f2",
    "f3",
    "f4",
  ])
  expect(visibleWorktreeSessions(group, project.key, { [key]: true }, {}, rows.at(-1)?.key)).toHaveLength(5)
  expect(visibleWorktreeSessions(group, project.key, { [project.key]: true }, {}, rows[0].key)).toEqual([rows[0]])
  expect(visibleWorktreeSessions(group, project.key, {}, { [key]: 10 })).toHaveLength(13)
  expect(group.groups).toHaveLength(1)
  const child = row("child", "/trees/feat")
  child.session.parentID = "r0"
  const archived = row("archived", "/trees/feat")
  archived.session.time.archived = 10
  expect(sidebarWorktrees(project, [child, archived], metadata).groups).toEqual([])
  expect(sidebarWorktrees(project, rootSessions([child, archived]).rows, metadata).groups).toEqual([])
})

test("non-git directories preserve existing grouping", () => {
  const rows = [row("note", "/notes", "global")]
  const project = sidebarProjects(server, [], rows)[0]
  expect(sidebarWorktrees(project, rows, metadata)).toEqual({ root: rows, groups: [] })
})
