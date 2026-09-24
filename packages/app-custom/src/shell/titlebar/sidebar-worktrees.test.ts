import { expect, test } from "bun:test"
import { ServerConnection } from "@/runtime/server/registry"
import { workspaceDraftTarget } from "@/workspaces/paths"
import {
  projectKey,
  rootSessions,
  sessionKey,
  sidebarProjectWorkspaces,
  sidebarProjects,
  sidebarSessionProject,
  type SidebarSession,
} from "./sidebar-model"
import {
  sidebarPreparingDirectory,
  sidebarPreparingGroups,
  sidebarWorktrees,
  visibleWorktreeSessions,
  withoutPreparingSessions,
  worktreeKey,
  type SidebarLocation,
} from "./sidebar-worktrees"

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
const project = sidebarProjects(
  server,
  [
    {
      id: "repo",
      worktree: "/repo",
      vcs: "git",
      worktrees: [{ directory: "/repo" }, { directory: "/trees/feat" }, { directory: "/repo/nested" }],
    },
  ],
  [row("root", "/repo")],
)[0]
const metadata = {
  cachedInventory: [{ directory: "/repo" }, { directory: "/trees/feat" }, { directory: "/repo/nested" }],
  location: (_directory: string): SidebarLocation | undefined => undefined,
  branch: (directory: string) => (directory === "/trees/feat" ? "feat/payments" : undefined),
}

test("managed chat rows and drafts never enter ancestral project or worktree groups", () => {
  const chat = { ...row("chat", "/repo/chats/session-one"), project: project.key, chat: true }
  const grouped = sidebarWorktrees(project, [chat], metadata)
  expect(grouped.root).toEqual([])
  expect(grouped.groups.every((group) => group.rows.length === 0)).toBe(true)
  const draft = {
    type: "draft" as const,
    draftID: "chat-draft",
    server,
    directory: "/repo/chats/session-two",
    chat: { allocationID: "allocation", sessionID: "ses_chat" },
  }
  const preparing = sidebarPreparingGroups(
    [{ tab: draft, directory: draft.directory, chat: true }],
    [{ key: project.key, server, directory: project.directory, groups: [] }],
  )
  expect(preparing.get(project.key)).toEqual({ root: [], groups: new Map() })
})

test("canonical root and its subdirectories never acquire a main accordion across cold, loaded and reconnect snapshots", () => {
  const rows = [row("root", "/repo"), row("sub", "/repo/src"), row("linked-main", "/trees/main")]
  for (const inventory of [undefined, [{ directory: "/repo" }, { directory: "/trees/main" }], undefined]) {
    const grouped = sidebarWorktrees(project, rows, { ...metadata, cachedInventory: inventory, branch: () => "main" })
    expect(grouped.root.map((row) => row.session.id)).toEqual(["root", "sub"])
    expect(grouped.groups.map((group) => group.directory)).toEqual(["/repo/nested", "/trees/feat", "/trees/main"])
    expect(grouped.groups.find((group) => group.directory === "/trees/main")?.name).toContain("main")
    expect(grouped.groups.some((group) => group.directory === "/repo")).toBe(false)
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

test("only effective workspaces with a removal strategy authorize the worktree action", () => {
  const effective = sidebarProjects(
    server,
    [
      {
        id: "repo",
        worktree: "/repo",
        vcs: "git",
        worktrees: [{ directory: "/clone" }, { directory: "/trees/main", strategy: "git" }],
      },
    ],
    [],
  )[0]
  const group = sidebarWorktrees(effective, [row("outside", "/outside/main")], {
    cachedInventory: [{ directory: "/repo" }, { directory: "/clone" }, { directory: "/trees/main", strategy: "git" }],
    location: () => undefined,
    branch: () => "main",
  })
  expect(group.groups.find((item) => item.directory === "/clone")?.removable).toBe(false)
  expect(group.groups.find((item) => item.directory === "/trees/main")?.removable).toBe(true)
  expect(group.groups.find((item) => item.directory === "/outside/main")?.removable).toBe(false)
  expect(group.groups.some((item) => item.directory === "/repo")).toBe(false)
})

test("incremental inventory/Location/branch never loses rows; unavailable and detached labels stay truthful", () => {
  const rows = [row("sub", "/trees/feat/src"), row("root", "/repo"), row("unknown", "/gone/feat")]
  const cold = sidebarWorktrees(project, rows, { ...metadata, cachedInventory: undefined })
  expect(cold.root.map((row) => row.session.id)).toEqual(["root"])
  expect(cold.groups.find((group) => group.directory === "/trees/feat")?.rows.map((row) => row.session.id)).toEqual([
    "sub",
  ])
  const location = (directory: string) =>
    directory === "/trees/feat/src" ? { worktree: "/trees/feat", canonical: "/repo", projectID: "repo" } : undefined
  const located = sidebarWorktrees(project, rows, { ...metadata, cachedInventory: undefined, location, branch: () => "HEAD" })
  // Git-located roots carry no project ID; the canonical checkout alone establishes ownership.
  const gitLocated = sidebarWorktrees(project, rows, {
    ...metadata,
    cachedInventory: undefined,
    location: (directory) => (directory === "/trees/feat/src" ? { worktree: "/trees/feat", canonical: "/repo" } : undefined),
  })
  expect(gitLocated.groups.find((group) => group.directory === "/trees/feat")?.rows.map((row) => row.session.id)).toEqual([
    "sub",
  ])
  const ready = sidebarWorktrees(project, rows, metadata)
  for (const group of [cold, located, gitLocated, ready]) {
    expect([...group.root, ...group.groups.flatMap((item) => item.rows)].map((row) => row.key).sort()).toEqual(
      rows.map((row) => row.key).sort(),
    )
  }
  expect(located.groups.find((group) => group.directory === "/trees/feat")?.name).toBe("feat — trees/feat")
  expect(located.groups.find((group) => group.directory === "/gone/feat")?.name).toBe("feat — gone/feat")
  expect(ready.groups.map((group) => group.directory)).toEqual(["/gone/feat", "/repo/nested", "/trees/feat"])
  expect(ready.groups.find((group) => group.directory === "/repo/nested")?.rows).toEqual([])
})

test("same basename/branch gets distinct labels while identical directories and foreign rows cannot merge", () => {
  const other = ServerConnection.Key.make("https://remote.test")
  const rows = [
    row("a", "/a/feat"),
    row("b", "/b/feat"),
    row("foreign", "/a/feat", "other"),
    row("remote", "/a/feat", "repo", other),
  ]
  const groupedProject = sidebarProjects(
    server,
    [{ id: "repo", worktree: "/repo", vcs: "git", worktrees: [{ directory: "/a/feat" }, { directory: "/b/feat" }] }],
    [],
  )[0]
  const group = sidebarWorktrees(
    groupedProject,
    rows.map((item) => (item.session.id === "a" || item.session.id === "b" ? { ...item, project: groupedProject.key } : item)),
    {
    cachedInventory: [{ directory: "/a/feat" }, { directory: "/a/feat/" }, { directory: "/b/feat" }],
    branch: () => "same-branch",
    location: () => ({ worktree: "/a/feat", canonical: "/other", projectID: "other" }),
    },
  )
  expect(group.groups).toHaveLength(2)
  expect(group.groups.map((group) => group.name)).toEqual(["same-branch — a/feat", "same-branch — b/feat"])
  expect(new Set(group.groups.map((group) => group.key)).size).toBe(2)
  expect(group.groups.flatMap((group) => group.rows).map((row) => row.session.id)).toEqual(["a", "b"])
  expect(worktreeKey(project.key, "/a/feat/")).toBe(worktreeKey(project.key, "/a/feat"))
  expect(worktreeKey(project.key, "C:\\Trees\\Feat")).toBe(worktreeKey(project.key, "c:/trees/feat/"))
  expect(worktreeKey(project.key, "/a/feat")).not.toBe(
    worktreeKey(projectKey(other, { id: "repo", worktree: "/repo" }), "/a/feat"),
  )
  expect(
    sidebarWorktrees(groupedProject, [{ ...row("a", "/a/feat"), project: groupedProject.key }], {
      cachedInventory: [{ directory: "/a/feat" }],
      branch: () => "same-branch",
      location: () => undefined,
    }).groups[0].name,
  ).toBe("same-branch — a/feat")
})

test("Codex worktree labels expose their stable UUID parent", () => {
  const first = "/Users/test/.codex/worktrees/uuid-a/Agents2"
  const second = "/Users/test/.codex/worktrees/uuid-b/Agents2"
  const groupedProject = sidebarProjects(
    server,
    [{ id: "repo", worktree: "/repo", vcs: "git", worktrees: [{ directory: first }, { directory: second }] }],
    [],
  )[0]
  const group = sidebarWorktrees(
    groupedProject,
    [row("a", first), row("b", second)].map((item) => ({ ...item, project: groupedProject.key })),
    {
    cachedInventory: [{ directory: first }, { directory: second }],
    branch: () => undefined,
    location: () => undefined,
    },
  )
  expect(group.groups.map((item) => item.name)).toEqual(["Agents2 — uuid-a/Agents2", "Agents2 — uuid-b/Agents2"])
})

test("visible order uses subgroup caps; subgroup collapse hides rows and project collapse retains the approved current escape", () => {
  const rows = [
    ...Array.from({ length: 7 }, (_, i) => row(`r${i}`, "/repo")),
    ...Array.from({ length: 8 }, (_, i) => row(`f${i}`, "/trees/feat")),
  ]
  const group = sidebarWorktrees(project, rows, metadata)
  const key = group.groups.find((item) => item.directory === "/trees/feat")!.key
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
  expect(group.groups).toHaveLength(2)
  const child = row("child", "/trees/feat")
  child.session.parentID = "r0"
  const archived = row("archived", "/trees/feat")
  archived.session.time.archived = 10
  expect(sidebarWorktrees(project, [child, archived], metadata).groups.map((item) => item.directory)).toEqual([
    "/repo/nested",
    "/trees/feat",
  ])
  expect(
    sidebarWorktrees(project, rootSessions([child, archived]).rows, metadata).groups.map((item) => item.directory),
  ).toEqual(["/repo/nested", "/trees/feat"])
})

test("non-git directories preserve existing grouping", () => {
  const rows = [row("note", "/notes", "global")]
  const project = sidebarProjects(server, [{ worktree: "/notes" }], rows)[0]
  expect(sidebarWorktrees(project, rows, { ...metadata, cachedInventory: [{ directory: "/notes" }] })).toEqual({
    root: rows,
    groups: [],
  })
})

test("inventory does not infer workspace ownership before project metadata", () => {
  const root = row("root", "/repo-linked")
  const project = sidebarProjects(server, [{ worktree: "/repo-linked" }], [root])[0]
  root.project = project.key
  const group = sidebarWorktrees(project, [root], {
    cachedInventory: [{ directory: "/repo" }, { directory: "/repo-linked" }, { directory: "/trees/idle" }],
    location: () => undefined,
    branch: (directory) => (directory === "/trees/idle" ? "idle" : undefined),
  })
  expect(group.root.map((item) => item.session.id)).toEqual(["root"])
  expect(group.groups).toEqual([])
})

test("non-git explicit worktrees and sandboxes keep preparing and real rows in the same group", () => {
  for (const source of ["worktree", "sandbox"] as const) {
    const directory = source === "worktree" ? "/repository" : "/sandbox"
    const selected = {
      id: "repo",
      worktree: "/repo",
      ...(source === "worktree" ? { worktrees: [{ directory }] } : { sandboxes: [directory] }),
    }
    const project = sidebarProjects(server, [selected], [])[0]
    const grouped = sidebarWorktrees(project, [], {
      cachedInventory: [],
      location: () => undefined,
      branch: () => undefined,
    })
    const draft = { type: "draft" as const, draftID: source, server, directory: "/repo", worktree: directory }
    const pending = { type: "session" as const, server, sessionId: source }
    const preparing = sidebarPreparingGroups(
      [{ tab: pending, directory: sidebarPreparingDirectory(draft) }],
      [{ ...project, groups: grouped.groups }],
    )
      .get(project.key)!
      .groups.get(worktreeKey(project.key, directory))
    const real = row(source, directory)
    real.project = project.key
    const resolved = sidebarWorktrees(project, [real], {
      cachedInventory: [],
      location: () => undefined,
      branch: () => undefined,
    })

    expect(preparing).toEqual([pending])
    expect(resolved.root).toEqual([])
    expect(resolved.groups.find((group) => group.directory === directory)?.rows).toEqual([real])
  }
})

test("effective workspaces come from metadata, materialize sandboxes and use cache only for strategy", () => {
  const effective = sidebarProjects(
    server,
    [
      {
        id: "effective",
        worktree: "/effective",
        vcs: "git",
        worktrees: [
          { directory: "/effective" },
          { directory: "/repository" },
          { directory: "/manual", strategy: "manual" },
        ],
        sandboxes: ["/sandbox", "/repository/"],
      },
    ],
    [],
  )[0]
  expect(sidebarProjectWorkspaces(effective.metadata!)).toEqual([
    { directory: "/repository" },
    { directory: "/manual", strategy: "manual" },
    { directory: "/sandbox" },
  ])

  const grouped = sidebarWorktrees(effective, [], {
    cachedInventory: [
      { directory: "/effective", strategy: "git" },
      { directory: "/repository", strategy: "git" },
      { directory: "/manual", strategy: "git" },
      { directory: "/stale", strategy: "git" },
    ],
    location: () => undefined,
    branch: () => undefined,
  })
  expect(grouped.groups.map((group) => [group.directory, group.explicit, group.removable])).toEqual([
    ["/manual", true, false],
    ["/repository", true, true],
    ["/sandbox", true, false],
  ])
})

test("metadata publication adds ownership and removal rejects stale cache without changing pending/real decisions", () => {
  const selected = { id: "repository", worktree: "/repository", expanded: true }
  const before = sidebarProjects(
    server,
    [{ id: "parent", worktree: "/parent", vcs: "git", worktrees: [{ directory: "/parent" }] }],
    [],
  )[0]
  const after = sidebarProjects(
    server,
    [
      {
        id: "parent",
        worktree: "/parent",
        vcs: "git",
        worktrees: [{ directory: "/parent" }, { directory: "/repository" }],
      },
    ],
    [],
  )[0]
  const cachedInventory = [{ directory: "/repository", strategy: "git" as const }]
  const metadata = { cachedInventory, location: () => undefined, branch: () => undefined }
  expect(sidebarWorktrees(before, [], metadata).groups).toEqual([])
  expect(sidebarWorktrees(after, [], metadata).groups).toMatchObject([
    { directory: "/repository", explicit: true, removable: true },
  ])

  const fallback = row("fallback", "/repository", "parent")
  fallback.project = before.key
  expect(sidebarWorktrees(before, [fallback], metadata).groups).toMatchObject([
    { directory: "/repository", explicit: false, removable: false },
  ])

  const draft = { type: "draft" as const, draftID: "removed", server, directory: "/repository", worktree: "main" }
  const pending = { type: "session" as const, server, sessionId: "removed" }
  const groups = sidebarWorktrees(before, [fallback], metadata).groups
  const preparing = sidebarPreparingGroups(
    [{ tab: pending, directory: sidebarPreparingDirectory(draft) }],
    [
      { ...before, groups },
      {
        key: projectKey(server, selected),
        server,
        directory: selected.worktree,
        groups: [],
      },
    ],
  )
  const real = row("removed", "/repository", "repository")
  real.project = sidebarSessionProject(server, real.session, [before.metadata!, selected])
  expect(preparing.get(projectKey(server, selected))?.root).toEqual([pending])
  expect(real.project).toBe(projectKey(server, selected))
})

test("drafts are ordered first in their canonical project or exact worktree group", () => {
  const grouped = sidebarWorktrees(project, [], metadata)
  const rootDraft = {
    type: "draft" as const,
    draftID: "root-draft",
    server,
    directory: "/repo",
  }
  const worktreeDraft = {
    type: "draft" as const,
    draftID: "worktree-draft",
    server,
    directory: "/trees/feat",
  }
  const nestedDraft = {
    type: "draft" as const,
    draftID: "nested-draft",
    server,
    directory: "/repo",
    worktree: "/repo/nested",
  }
  const placements = sidebarPreparingGroups(
    [worktreeDraft, rootDraft, nestedDraft].map((tab) => ({ tab, directory: sidebarPreparingDirectory(tab) })),
    [{ ...project, groups: grouped.groups }],
  ).get(project.key)!

  expect(placements.root).toEqual([rootDraft])
  expect(placements.groups.get(worktreeKey(project.key, "/trees/feat"))).toEqual([worktreeDraft])
  expect(placements.groups.get(worktreeKey(project.key, "/repo/nested"))).toEqual([nestedDraft])
})

test("draft grouping isolates servers and projects and rejects directory-prefix siblings", () => {
  const remote = ServerConnection.Key.make("https://remote.test")
  const other = sidebarProjects(server, [{ id: "other", worktree: "/other", vcs: "git" }], [])[0]
  const remoteProject = sidebarProjects(remote, [{ id: "repo", worktree: "/repo", vcs: "git" }], [])[0]
  const feature = worktreeKey(project.key, "/trees/feat")
  const remoteFeature = worktreeKey(remoteProject.key, "/trees/feat")
  const draft = (draftID: string, host: typeof server, directory: string) => ({
    tab: { type: "draft" as const, draftID, server: host, directory },
    directory,
  })
  const placements = sidebarPreparingGroups(
    [
      draft("local", server, "/trees/feat/src"),
      draft("prefix", server, "/trees/feature"),
      draft("other", server, "/other"),
      draft("remote", remote, "/trees/feat"),
    ],
    [
      { ...project, groups: [{ key: feature, directory: "/trees/feat", explicit: true }] },
      { ...other, groups: [] },
      {
        ...remoteProject,
        groups: [{ key: remoteFeature, directory: "/trees/feat", explicit: true }],
      },
    ],
  )

  expect(placements.get(project.key)?.groups.get(feature)?.map((tab) => tab.type === "draft" && tab.draftID)).toEqual([
    "local",
  ])
  expect(placements.get(other.key)?.root.map((tab) => tab.type === "draft" && tab.draftID)).toEqual(["other"])
  expect(
    placements.get(remoteProject.key)?.groups.get(remoteFeature)?.map((tab) => tab.type === "draft" && tab.draftID),
  ).toEqual(["remote"])
  expect([...placements.values()].flatMap((placement) => [placement.root, ...placement.groups.values()]).flat()).toHaveLength(
    3,
  )
})

test("an existing-worktree handoff stays single while the real row arrives and pending completes", () => {
  const parent = sidebarProjects(
    server,
    [{ id: "5e5", worktree: "/opencode", vcs: "git", worktrees: [{ directory: "/repository" }] }],
    [],
  )[0]
  const independent = { id: "f001", worktree: "/repository", expanded: true }
  const inventory = {
    cachedInventory: [{ directory: "/opencode" }, { directory: "/repository" }],
    branch: () => undefined,
    location: (): SidebarLocation => ({ worktree: "/repository", canonical: "/repository", projectID: "f001" }),
  }
  const grouped = sidebarWorktrees(parent, [], inventory)
  const target = workspaceDraftTarget("/repository", "/opencode")
  const draft = { type: "draft" as const, draftID: "draft", server, ...target }
  const pending = { type: "session" as const, server, sessionId: "created" }
  const created = row("created", "/repository", "f001")
  const selected = [parent.metadata!, independent]

  for (const projects of [selected, selected.toReversed()]) {
    created.project = sidebarSessionProject(server, created.session, projects)
    const state = {
      preparing: [{ tab: pending, directory: sidebarPreparingDirectory(draft) }],
      rows: [] as SidebarSession[],
    }
    const preparingProjects = projects.map((item) => {
      const key = projectKey(server, item)
      return item.id === "5e5"
        ? { key, server, directory: "/opencode", groups: grouped.groups }
        : { key, server, directory: "/repository", groups: [] }
    })
    const view = () => {
      const pendingRows = sidebarPreparingGroups(state.preparing, preparingProjects)
        .get(parent.key)!
        .groups.get(worktreeKey(parent.key, "/repository"))!
      const tree = sidebarWorktrees(parent, withoutPreparingSessions(state.rows, state.preparing), inventory)
      const realRows = tree.groups.find((group) => group.directory === "/repository")!.rows
      return { pending: pendingRows.length, real: realRows.length, root: tree.root.length, total: pendingRows.length + realRows.length }
    }
    const snapshots = [view()]
    state.rows.push(created)
    snapshots.push(view())
    state.preparing.splice(0)
    snapshots.push(view())

    expect(created.project).toBe(parent.key)
    expect(snapshots).toEqual([
      { pending: 1, real: 0, root: 0, total: 1 },
      { pending: 1, real: 0, root: 0, total: 1 },
      { pending: 0, real: 1, root: 0, total: 1 },
    ])
  }
})
