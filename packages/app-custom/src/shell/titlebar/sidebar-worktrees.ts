import { createEffect, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import type { LocationGetOutput, WorktreeDirectory } from "@opencode/client/promise"
import type { ServerCtx } from "@/runtime/server/runtime"
import type { DraftTab, Tab } from "@/shell/tabs/tabs"
import { getFilename } from "@opencode/util/path"
import { pathKey } from "@/workspaces/path-key"
import { containsDirectory, sameDirectory } from "@/workspaces/paths"
import {
  sessionKey,
  sidebarExplicitWorkspace,
  sidebarProjectWorkspaces,
  sidebarProjects,
  visibleSessions,
  type SidebarSession,
} from "./sidebar-model"

type Project = ReturnType<typeof sidebarProjects>[number]

export type SidebarPreparingTab = { tab: Tab; directory: string; chat?: boolean }

export function sidebarPreparingDirectory(draft: DraftTab) {
  if (draft.worktree && draft.worktree !== "main" && draft.worktree !== "create") return draft.worktree
  return draft.directory
}

export function sidebarPreparingGroups(
  tabs: readonly SidebarPreparingTab[],
  projects: readonly {
    key: string
    server: string
    directory: string
    groups: readonly { key: string; directory: string; explicit: boolean }[]
  }[],
) {
  const result = new Map<string, { root: Tab[]; groups: Map<string, Tab[]> }>(
    projects.map((project) => [project.key, { root: [], groups: new Map(project.groups.map((group) => [group.key, []])) }]),
  )
  tabs.forEach((entry) => {
    if (entry.chat) return
    const matching = projects.filter((project) => project.server === entry.tab.server)
    const explicit = sidebarExplicitWorkspace(
      entry.directory,
      matching.map((project) => ({
        ...project,
        workspaces: project.groups.filter((group) => group.explicit).map((group) => ({ directory: group.directory })),
      })),
    )
    const target = explicit
      ? {
          project: explicit.project.key,
          directory: explicit.directory,
          group: explicit.project.groups.find((group) => sameDirectory(group.directory, explicit.directory))?.key,
        }
      : matching
          .flatMap<{ project: string; directory: string; group?: string }>((project) => [
            { project: project.key, directory: project.directory },
            ...project.groups.map((group) => ({ project: project.key, directory: group.directory, group: group.key })),
          ])
          .filter((candidate) => containsDirectory(candidate.directory, entry.directory))
          .toSorted(
            (a, b) =>
              pathKey(b.directory).length - pathKey(a.directory).length ||
              Number(!!a.group) - Number(!!b.group) ||
              a.project.localeCompare(b.project),
          )[0]
    if (!target) return
    const placement = result.get(target.project)!
    if (!target.group) {
      placement.root.push(entry.tab)
      return
    }
    placement.groups.get(target.group)?.push(entry.tab)
  })
  return result
}

export function withoutPreparingSessions(rows: SidebarSession[], tabs: readonly SidebarPreparingTab[]) {
  const preparing = new Set(
    tabs.flatMap((entry) =>
      entry.tab.type === "session" ? [sessionKey(entry.tab.server, entry.tab.sessionId)] : [],
    ),
  )
  return rows.filter((row) => !preparing.has(row.key))
}

export function worktreeKey(project: string, directory: string) {
  const key = pathKey(directory)
  return JSON.stringify([project, "worktree", /^[a-z]:\//i.test(key) || key.startsWith("//") ? key.toLowerCase() : key])
}

export function sidebarWorktrees(
  project: Project,
  rows: SidebarSession[],
  metadata: {
    cachedInventory?: readonly WorktreeDirectory[]
    location: (directory: string) => LocationGetOutput | undefined
    branch: (directory: string) => string | undefined
  },
) {
  const root: SidebarSession[] = []
  const groups = new Map<
    string,
    {
      key: string
      directory: string
      name: string
      resolved: boolean
      removable: boolean
      explicit: boolean
      rows: SidebarSession[]
    }
  >()
  const workspaces = project.metadata ? sidebarProjectWorkspaces(project.metadata) : []
  workspaces.forEach((item) => {
    const key = worktreeKey(project.key, item.directory)
    const branch = metadata.branch(item.directory)
    const cached = metadata.cachedInventory?.find((entry) => sameDirectory(entry.directory, item.directory))
    groups.set(key, {
      key,
      directory: item.directory,
      resolved: true,
      removable: (item.strategy ?? cached?.strategy) === "git",
      explicit: true,
      name: branch && branch !== "HEAD" ? branch : getFilename(pathKey(item.directory)) || item.directory,
      rows: [],
    })
  })
  const candidates = [
    ...workspaces.map((item) => item.directory),
    ...(project.metadata ? [project.directory] : []),
  ].toSorted((a, b) => b.length - a.length)
  rows
    .filter((row) => !row.chat && row.project === project.key && !row.session.parentID && !row.session.time.archived)
    .forEach((row) => {
      const directory = row.session.location.directory
      const explicit = sidebarExplicitWorkspace(directory, [
        { key: project.key, directory: project.directory, workspaces },
      ])
      if (explicit) {
        groups.get(worktreeKey(project.key, explicit.directory))!.rows.push(row)
        return
      }
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
        removable: false,
        explicit: false,
        name: branch && branch !== "HEAD" ? branch : getFilename(pathKey(worktree)) || worktree,
        rows: [],
      }
      group.rows.push(row)
      groups.set(key, group)
    })
  // Directory order does not jump when branch metadata arrives or a session becomes active.
  return { root, groups: disambiguateWorktreeNames([...groups.values()].sort((a, b) => a.key.localeCompare(b.key))) }
}

function disambiguateWorktreeNames<T extends { directory: string; name: string }>(groups: T[]) {
  const collisions = Map.groupBy(groups, (group) => group.name)
  return groups.map((group) => {
    const matching = collisions.get(group.name) ?? []
    if (matching.length < 2) return group
    const paths = matching.map((item) => pathKey(item.directory).split("/").filter(Boolean))
    const parts = pathKey(group.directory).split("/").filter(Boolean)
    const depth = Array.from({ length: parts.length }, (_, index) => index + 1).find((size) => {
      const suffix = parts.slice(-size).join("/")
      return paths.filter((path) => path.slice(-size).join("/") === suffix).length === 1
    })
    return { ...group, name: `${group.name} — ${parts.slice(-(depth ?? parts.length)).join("/")}` }
  })
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
  const inventoryIdentity = (project: Project) => {
    const location = ctx.data.location.info({ directory: project.directory })?.project
    return { id: location?.id ?? project.metadata?.id, directory: location?.canonical ?? project.directory }
  }
  const group = (project: Project, rows: SidebarSession[]) =>
    sidebarWorktrees(project, rows, {
      cachedInventory: (() => {
        const identity = inventoryIdentity(project)
        return identity.id ? ctx.sync.worktrees.cached(identity.id, identity.directory) : undefined
      })(),
      location: (directory) => ctx.data.location.info({ directory }),
      branch: (directory) => ctx.data.location.vcs.info({ directory })?.branch.current,
    })
  return {
    group,
    async load(demand: () => { project: Project; rows: SidebarSession[] } | undefined) {
      const initial = demand()
      if (
        !initial ||
        (initial.project.metadata?.vcs && initial.project.metadata.vcs !== "git") ||
        ctx.sdk.connection.status() !== "connected"
      )
        return
      const project = initial.project
      await once(`project-location:${pathKey(project.directory)}`, () =>
        ctx.data.location.syncInfo({ directory: project.directory }),
      )
      if (lifetime.disposed) return
      const identity = inventoryIdentity(project)
      const projectID = identity.id
      if (!projectID) return
      await once(`inventory:${projectID}:${pathKey(identity.directory)}`, async () => {
        const inventory = await ctx.sync.worktrees.load(projectID, identity.directory)
        if (inventory && !lifetime.disposed) setState("loaded", project.key, true)
      })
      if (lifetime.disposed) return
      const locations = demand()
      if (!locations || ctx.sdk.connection.status() !== "connected") return
      // Inventory containment resolves subdirectories without a request per session. Only
      // unmatched directories need Location's authoritative worktree root (no full bootstrap).
      const currentIdentity = inventoryIdentity(locations.project)
      const inventory = currentIdentity.id
        ? ctx.sync.worktrees.cached(currentIdentity.id, currentIdentity.directory)
        : undefined
      await Promise.all(
        [
          ...new Set(
            locations.rows
              .filter((row) => row.project === locations.project.key)
              .map((row) => row.session.location.directory),
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
