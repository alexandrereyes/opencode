import type { QueryClient } from "@tanstack/solid-query"
import type { WorktreeDirectory } from "@opencode/client/promise"
import type { ServerApi } from "@/runtime/server/api"
import type { ServerScope } from "@/runtime/server/scope"
import type { Project } from "@/runtime/server/types"
import { pathKey } from "./path-key"
import { sameDirectory } from "./paths"

export function worktreeInventoryKey(scope: ServerScope, directory: string) {
  return [scope, "worktree", pathKey(directory)] as const
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

// Listing a project's worktrees boots its Location on the server and runs discovery, so only
// projects the user is looking at are loaded. Historical projects stay metadata-only.
export function createWorktreeInventory(input: {
  scope: ServerScope
  queryClient: QueryClient
  api: () => Pick<ServerApi["worktree"], "list">
  updated: (directory: string, worktrees: WorktreeDirectory[]) => void
}) {
  const revisions = new Map<string, number>()
  const options = (directory: string) => ({
    queryKey: worktreeInventoryKey(input.scope, directory),
    queryFn: () => {
      const key = String(pathKey(directory))
      const revision = revisions.get(key) ?? 0
      return input
        .api()
        .list({ location: { directory } })
        .then((items) => {
          if ((revisions.get(key) ?? 0) !== revision)
            return input.queryClient.getQueryData<WorktreeDirectory[]>(worktreeInventoryKey(input.scope, directory)) ?? []
          input.updated(directory, items)
          return items
        })
    },
    // `worktree.updated` and reconnect invalidation drive refreshes; time alone does not re-list.
    staleTime: Infinity,
    gcTime: Infinity,
    retry: false,
  })
  return {
    cached: (directory: string) =>
      input.queryClient.getQueryData<WorktreeDirectory[]>(worktreeInventoryKey(input.scope, directory)),
    load: (directory: string) => input.queryClient.fetchQuery(options(directory)).catch(() => undefined),
    remove: (directory: string, target: string) => {
      const current = input.queryClient.getQueryData<WorktreeDirectory[]>(worktreeInventoryKey(input.scope, directory))
      if (!current) return
      const key = String(pathKey(directory))
      revisions.set(key, (revisions.get(key) ?? 0) + 1)
      const next = current.filter((item) => !sameDirectory(item.directory, target))
      input.queryClient.setQueryData(worktreeInventoryKey(input.scope, directory), next)
      input.updated(directory, next)
    },
    // Only inventories some view already demanded are refreshed.
    refresh: (directory: string) => {
      if (!input.queryClient.getQueryState(worktreeInventoryKey(input.scope, directory))) return Promise.resolve()
      return input.queryClient.fetchQuery({ ...options(directory), staleTime: 0 }).catch(() => undefined)
    },
  }
}
