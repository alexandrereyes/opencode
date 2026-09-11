import { createEffect, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import type { LocationGetOutput, WorktreeDirectory } from "@opencode/client/promise"
import type { ServerCtx } from "@/runtime/server/runtime"
import { getFilename } from "@opencode/util/path"
import { pathKey } from "@/workspaces/path-key"
import { containsDirectory, sameDirectory } from "@/workspaces/paths"
import { sidebarProjects, visibleSessions, type SidebarSession } from "./sidebar-model"

type Project = ReturnType<typeof sidebarProjects>[number]

export function worktreeKey(project: string, directory: string) {
  const key = pathKey(directory)
  return JSON.stringify([project, "worktree", /^[a-z]:\//i.test(key) || key.startsWith("//") ? key.toLowerCase() : key])
}

export function sidebarWorktrees(
  project: Project,
  rows: SidebarSession[],
  metadata: {
    inventory?: readonly WorktreeDirectory[]
    location: (directory: string) => LocationGetOutput | undefined
    branch: (directory: string) => string | undefined
  },
) {
  const root: SidebarSession[] = []
  const groups = new Map<
    string,
    { key: string; directory: string; name: string; resolved: boolean; rows: SidebarSession[] }
  >()
  const candidates = metadata.inventory?.map((item) => item.directory).toSorted((a, b) => b.length - a.length)
  rows
    .filter((row) => row.project === project.key && !row.session.parentID && !row.session.time.archived)
    .forEach((row) => {
      const directory = row.session.location.directory
      // Non-Git projects retain their existing directory grouping. A missing project record
      // is not evidence that all of its session directories are the canonical worktree.
      if (project.metadata && project.metadata.vcs !== "git") {
        root.push(row)
        return
      }
      const location = metadata.location(directory)
      const owned =
        location?.project.id === row.session.projectID && sameDirectory(location.project.canonical, project.directory)
      const known = owned
        ? location.project.directory
        : candidates?.find((candidate) => containsDirectory(candidate, directory))
      const worktree = known ?? directory
      if (sameDirectory(worktree, project.directory)) {
        root.push(row)
        return
      }
      const key = worktreeKey(project.key, worktree)
      const branch = known ? metadata.branch(worktree) : undefined
      const group = groups.get(key) ?? {
        key,
        directory: worktree,
        resolved: known !== undefined,
        name: branch && branch !== "HEAD" ? branch : getFilename(pathKey(worktree)) || worktree,
        rows: [],
      }
      group.rows.push(row)
      groups.set(key, group)
    })
  // Directory order does not jump when branch metadata arrives or a session becomes active.
  return { root, groups: [...groups.values()].sort((a, b) => a.key.localeCompare(b.key)) }
}

export function visibleWorktreeSessions(
  group: ReturnType<typeof sidebarWorktrees>,
  project: string,
  collapsed: Record<string, boolean>,
  limits: Record<string, number>,
  current?: string,
) {
  if (collapsed[project])
    return [...group.root, ...group.groups.flatMap((item) => item.rows)].filter((row) => row.key === current)
  return [
    ...visibleSessions(group.root, limits[project] ?? 5, current),
    ...group.groups.flatMap((item) =>
      collapsed[item.key] ? [] : visibleSessions(item.rows, limits[item.key] ?? 5, current),
    ),
  ]
}

export function createSidebarWorktrees(ctx: Pick<ServerCtx, "sync" | "data" | "sdk">) {
  const [state, setState] = createStore({ loaded: {} as Record<string, boolean> })
  const requests = new Map<string, Promise<unknown>>()
  const lifetime = { disposed: false }
  onCleanup(() => {
    lifetime.disposed = true
  })
  createEffect(() => {
    if (ctx.sdk.connection.status() === "connected") requests.clear()
  })
  const once = (key: string, load: () => Promise<unknown>) => {
    const previous = requests.get(key)
    if (previous) return previous
    const request = load().catch(() => undefined)
    requests.set(key, request)
    return request
  }
  const group = (project: Project, rows: SidebarSession[]) =>
    sidebarWorktrees(project, rows, {
      inventory:
        project.metadata?.vcs === "git"
          ? state.loaded[project.key]
            ? project.metadata.worktrees
            : ctx.sync.worktrees.cached(project.directory)
          : undefined,
      location: (directory) => (project.metadata?.vcs === "git" ? ctx.data.location.info({ directory }) : undefined),
      branch: (directory) =>
        project.metadata?.vcs === "git" ? ctx.data.location.vcs.info({ directory })?.branch.current : undefined,
    })
  return {
    group,
    async load(demand: () => { project: Project; rows: SidebarSession[] } | undefined) {
      const initial = demand()
      if (!initial || initial.project.metadata?.vcs !== "git" || ctx.sdk.connection.status() !== "connected") return
      const project = initial.project
      await once(`inventory:${project.key}`, async () => {
        const inventory = await ctx.sync.worktrees.load(project.directory)
        if (inventory && !lifetime.disposed) setState("loaded", project.key, true)
      })
      if (lifetime.disposed) return
      const locations = demand()
      if (!locations || ctx.sdk.connection.status() !== "connected") return
      // Inventory containment resolves subdirectories without a request per session. Only
      // unmatched directories need Location's authoritative worktree root (no full bootstrap).
      const inventory = ctx.sync.worktrees.cached(locations.project.directory)
      await Promise.all(
        [
          ...new Set(
            locations.rows.filter((row) => row.project === project.key).map((row) => row.session.location.directory),
          ),
        ]
          .filter(
            (directory) =>
              !sameDirectory(directory, locations.project.directory) &&
              !inventory?.some((item) => containsDirectory(item.directory, directory)),
          )
          .map((directory) =>
            once(`location:${worktreeKey(project.key, directory)}`, () => ctx.data.location.syncInfo({ directory })),
          ),
      )
      if (lifetime.disposed) return
      const branches = demand()
      if (!branches || ctx.sdk.connection.status() !== "connected") return
      await Promise.all(
        group(branches.project, branches.rows)
          .groups.filter((item) => item.resolved)
          .map((item) => once(`branch:${item.key}`, () => ctx.data.location.vcs.sync({ directory: item.directory }))),
      )
    },
  }
}
