import { queryOptions, useQueryClient, type QueryClient } from "@tanstack/solid-query"
import type { Accessor } from "solid-js"
import type { ServerSDK } from "@/runtime/server/client"
import type { ServerConnection } from "@/runtime/server/registry"
import { useServerCtx, type ServerCtx } from "@/runtime/server/runtime"
import { normalizeProjectInfo } from "@/runtime/server/global-sync/utils"
import { worktreeInventoryViewKey } from "@/workspaces/inventory"

function workspaceProjectsQuery(sdk: ServerSDK) {
  return queryOptions({
    queryKey: [sdk.scope, "settings-workspace-project-metadata"],
    queryFn: () => sdk.api.project.list(),
    staleTime: 30_000,
  })
}

export function workspaceInventoryQuery(
  context: ServerCtx,
  client: QueryClient,
  projectID?: string,
  shouldRefresh = projectID !== undefined,
) {
  return queryOptions({
    queryKey: worktreeInventoryViewKey(context.sdk.scope, projectID),
    queryFn: async () =>
      Promise.all(
        (await client.fetchQuery(workspaceProjectsQuery(context.sdk)))
          .filter((project) => projectID === undefined || project.id === projectID)
          .map(async (project) => {
            const cached = context.sync.worktrees.cached(project.id, project.canonical)
            const worktrees = (await context.sync.worktrees.load(project.id, project.canonical)) ?? [
              { directory: project.canonical },
              ...project.sandboxes.map((directory) => ({ directory })),
            ]
            if (shouldRefresh && cached) void context.sync.worktrees.refresh(project.id, project.canonical)
            return normalizeProjectInfo({ ...project, worktrees })
          }),
      ),
    staleTime: 30_000,
  })
}

export function prefetchWorkspaces(client: QueryClient, context: ServerCtx | undefined, projectID?: string) {
  if (!context || context.sdk.connection.status() !== "connected") return
  if (projectID) {
    return client.prefetchQuery(workspaceInventoryQuery(context, client, projectID, false))
  }
  // Server-level hover warms metadata without booting every project's Location.
  return client.prefetchQuery(workspaceProjectsQuery(context.sdk))
}

export function useWorkspacesPrefetch(
  server: Accessor<ServerConnection.Any | undefined>,
  projectID?: Accessor<string | undefined>,
) {
  const client = useQueryClient()
  const context = useServerCtx(server)
  return () => prefetchWorkspaces(client, context(), projectID?.())
}
