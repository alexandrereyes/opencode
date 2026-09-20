import { describe, expect, test } from "bun:test"
import { QueryClient } from "@tanstack/solid-query"
import { ServerScope } from "@/runtime/server/scope"
import type { ServerCtx } from "@/runtime/server/runtime"
import { prefetchWorkspaces, workspaceInventoryQuery } from "./queries"

const projects = [
  {
    id: "alpha",
    canonical: "/alpha",
    name: "Alpha",
    time: { created: 1, updated: 1 },
    sandboxes: ["/alpha/legacy"],
  },
  {
    id: "beta",
    canonical: "/beta",
    name: "Beta",
    time: { created: 1, updated: 1 },
    sandboxes: [],
  },
]

function setup(status: "connected" | "disconnected" = "connected") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const calls = { projects: 0, loads: [] as string[], refreshes: [] as string[] }
  const cached = new Set<string>()
  const context = {
    sdk: {
      scope: ServerScope.local,
      connection: { status: () => status },
      api: {
        project: {
          list: async () => {
            calls.projects++
            return projects
          },
        },
      },
    },
    sync: {
      worktrees: {
        cached: (projectID: string, directory: string) => (cached.has(`${projectID}:${directory}`) ? [] : undefined),
        load: async (projectID: string, directory: string) => {
          calls.loads.push(`${projectID}:${directory}`)
          cached.add(`${projectID}:${directory}`)
          return [{ directory }, { directory: `${directory}/feature`, strategy: "git" as const }]
        },
        refresh: async (projectID: string, directory: string) => {
          calls.refreshes.push(`${projectID}:${directory}`)
        },
      },
    },
  } as unknown as ServerCtx
  return { client, calls, context }
}

describe("workspaceInventoryQuery", () => {
  test("caches metadata and inventory views for 30 seconds, then refetches an invalidated view", async () => {
    const result = setup()
    const options = workspaceInventoryQuery(result.context, result.client)

    expect(await result.client.fetchQuery(options)).toHaveLength(2)
    expect(await result.client.fetchQuery(options)).toHaveLength(2)
    expect(result.calls).toEqual({
      projects: 1,
      loads: ["alpha:/alpha", "beta:/beta"],
      refreshes: [],
    })

    await result.client.invalidateQueries({ queryKey: [ServerScope.local, "settings-workspace-inventory"] })
    expect(await result.client.fetchQuery(options)).toHaveLength(2)
    expect(result.calls.projects).toBe(1)
    expect(result.calls.loads).toEqual(["alpha:/alpha", "beta:/beta", "alpha:/alpha", "beta:/beta"])
    result.client.clear()
  })

  test("loads only the requested project and refreshes it after the cache is warm", async () => {
    const result = setup()
    const inventory = await result.client.fetchQuery(workspaceInventoryQuery(result.context, result.client, "beta"))
    await Promise.resolve()

    expect(inventory).toHaveLength(1)
    expect(inventory[0]).toMatchObject({
      id: "beta",
      worktree: "/beta",
      worktrees: [{ directory: "/beta" }, { directory: "/beta/feature", strategy: "git" }],
    })
    expect(result.calls.loads).toEqual(["beta:/beta"])
    expect(result.calls.refreshes).toEqual([])

    await result.client.invalidateQueries({ queryKey: [ServerScope.local, "settings-workspace-inventory"] })
    await result.client.fetchQuery(workspaceInventoryQuery(result.context, result.client, "beta"))
    await Promise.resolve()
    expect(result.calls.loads).toEqual(["beta:/beta", "beta:/beta"])
    expect(result.calls.refreshes).toEqual(["beta:/beta"])
    result.client.clear()
  })
})

describe("prefetchWorkspaces", () => {
  test("server prefetch warms only metadata while project prefetch loads one cached inventory", async () => {
    const server = setup()
    await prefetchWorkspaces(server.client, server.context)
    expect(server.calls).toEqual({ projects: 1, loads: [], refreshes: [] })

    await prefetchWorkspaces(server.client, server.context, "alpha")
    expect(server.calls.projects).toBe(1)
    expect(server.calls.loads).toEqual(["alpha:/alpha"])
    expect(server.calls.refreshes).toEqual([])
    server.client.clear()
  })

  test("does nothing while disconnected", async () => {
    const result = setup("disconnected")
    await prefetchWorkspaces(result.client, result.context)
    expect(result.calls).toEqual({ projects: 0, loads: [], refreshes: [] })
    result.client.clear()
  })
})
