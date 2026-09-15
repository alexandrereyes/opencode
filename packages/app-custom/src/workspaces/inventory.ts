import type { QueryClient } from "@tanstack/solid-query"
import type { WorktreeDirectory } from "@opencode/client/promise"
import type { ServerApi } from "@/runtime/server/api"
import type { ServerScope } from "@/runtime/server/scope"
import type { Project } from "@/runtime/server/types"
import { pathKey } from "./path-key"
import { sameDirectory } from "./paths"

export function worktreeInventoryKey(scope: ServerScope, projectID: string, directory: string) {
  return [scope, "worktree", projectID, pathKey(directory)] as const
}

// Project metadata arrives without worktrees; a loaded inventory supplies the workspace list.
export function withWorktreeInventory(project: Project, worktrees: readonly WorktreeDirectory[] | undefined): Project {
  if (!worktrees) return project
  return {
    ...project,
    worktrees: [...worktrees],
    sandboxes: worktrees
      .map((item) => item.directory)
      .filter((directory) => !sameDirectory(project.worktree, directory)),
  }
}

export function updateWorktreeInventory(
  projects: readonly Project[],
  projectID: string,
  directory: string,
  worktrees: readonly WorktreeDirectory[],
) {
  return projects.map((project) =>
    project.id === projectID && sameDirectory(project.worktree, directory)
      ? withWorktreeInventory(project, worktrees)
      : project,
  )
}

// Listing a project's worktrees boots its Location on the server and runs discovery, so only
// projects the user is looking at are loaded. Historical projects stay metadata-only.
export function createWorktreeInventory(input: {
  scope: ServerScope
  queryClient: QueryClient
  api: () => Pick<ServerApi["worktree"], "list">
  updated: (projectID: string, directory: string, worktrees: WorktreeDirectory[]) => void
}) {
  const revisions = new Map<string, number>()
  const options = (projectID: string, directory: string) => ({
    queryKey: worktreeInventoryKey(input.scope, projectID, directory),
    queryFn: () => {
      const key = `${projectID}:${pathKey(directory)}`
      const revision = revisions.get(key) ?? 0
      return input
        .api()
        .list({ location: { directory } })
        .then((items) => {
          if ((revisions.get(key) ?? 0) !== revision)
            return (
              input.queryClient.getQueryData<WorktreeDirectory[]>(
                worktreeInventoryKey(input.scope, projectID, directory),
              ) ?? []
            )
          input.updated(projectID, directory, items)
          return items
        })
    },
    // `worktree.updated` and reconnect invalidation drive refreshes; time alone does not re-list.
    staleTime: Infinity,
    gcTime: Infinity,
    retry: false,
  })
  return {
    cached: (projectID: string, directory: string) =>
      input.queryClient.getQueryData<WorktreeDirectory[]>(worktreeInventoryKey(input.scope, projectID, directory)),
    load: (projectID: string, directory: string) =>
      input.queryClient.fetchQuery(options(projectID, directory)).catch(() => undefined),
    remove: (projectID: string, directory: string, target: string) => {
      const current = input.queryClient.getQueryData<WorktreeDirectory[]>(
        worktreeInventoryKey(input.scope, projectID, directory),
      )
      if (!current) return
      const key = `${projectID}:${pathKey(directory)}`
      revisions.set(key, (revisions.get(key) ?? 0) + 1)
      const next = current.filter((item) => !sameDirectory(item.directory, target))
      input.queryClient.setQueryData(worktreeInventoryKey(input.scope, projectID, directory), next)
      input.updated(projectID, directory, next)
    },
    // Only inventories some view already demanded are refreshed.
    refresh: (projectID: string, directory: string) => {
      if (!input.queryClient.getQueryState(worktreeInventoryKey(input.scope, projectID, directory)))
        return Promise.resolve()
      return input.queryClient.fetchQuery({ ...options(projectID, directory), staleTime: 0 }).catch(() => undefined)
    },
  }
}
