import { expect, test } from "bun:test"
import { createServer } from "node:http"
import { QueryClient } from "@tanstack/solid-query"
import { OpenCode } from "@opencode/client/promise"
import { createData } from "@opencode/client/solid"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import { ServerConnection } from "@/runtime/server/registry"
import { ServerScope } from "@/runtime/server/scope"
import type { Project } from "@/runtime/server/types"
import { resolveProjectMetadata } from "@/runtime/server/project-metadata"
import { updateProjectInfo } from "@/runtime/server/global-sync/utils"
import { bootstrapGlobal } from "@/runtime/server/global-sync/bootstrap"
import { createWorktreeInventory, updateWorktreeInventory } from "@/workspaces/inventory"
import { workspaceDraftTarget } from "@/workspaces/paths"
import {
  projectKey,
  sessionKey,
  sidebarProjects,
  sidebarSessionProject,
  type SidebarSession,
} from "@/shell/titlebar/sidebar-model"
import { createSidebarWorktrees, sidebarWorktrees } from "@/shell/titlebar/sidebar-worktrees"

test("a cold linked checkout discovers moved sessions and branch labels through the real inventory client", async () => {
  const requests: string[] = []
  let worktrees = [
    { directory: "/repo" },
    { directory: "/repo-linked" },
    { directory: "/repository" },
    { directory: "/trees/managed-chats", strategy: "git" as const },
  ]
  const apiServer = createServer((request, response) => {
    response.setHeader("access-control-allow-origin", "*")
    response.setHeader("access-control-allow-methods", "GET, POST, OPTIONS")
    response.setHeader("access-control-allow-headers", "content-type")
    if (request.method === "OPTIONS") {
      response.writeHead(204)
      return response.end()
    }
    const url = new URL(request.url!, "http://localhost")
    if (request.method !== "OPTIONS") requests.push(url.pathname)
    response.setHeader("content-type", "application/json")
    if (url.pathname === "/api/location") {
      expect(url.searchParams.get("location[directory]")).toBe("/repo-linked")
      return response.end(
        JSON.stringify({
          directory: "/repo-linked",
          project: { id: "repo", canonical: "/repo", directory: "/repo-linked" },
        }),
      )
    }
    if (url.pathname === "/api/vcs")
      return response.end(
        JSON.stringify({
          location: {
            directory: url.searchParams.get("location[directory]")!,
            project: { id: "repo", canonical: "/repo", directory: url.searchParams.get("location[directory]")! },
          },
          data: { branch: { current: "branch" } },
        }),
      )
    if (url.pathname === "/api/worktree/refresh") {
      response.writeHead(204)
      return response.end()
    }
    expect(url.pathname).toBe("/api/worktree")
    expect(url.searchParams.get("projectID")).toBe("repo")
    response.end(JSON.stringify(worktrees))
  })
  await new Promise<void>((resolve) => apiServer.listen(0, "127.0.0.1", resolve))
  const address = apiServer.address()
  if (!address || typeof address === "string") throw new Error("Expected ephemeral TCP server")
  const project = (id: string, worktree: string): Project => ({
    id,
    worktree,
    name: id,
    vcs: "git",
    worktrees: [{ directory: worktree }],
    sandboxes: [],
    time: { created: 1, updated: 1 },
  })
  const canonical = project("repo", "/repo")
  const unrelated = project("unrelated", "/repository")
  const historical = project("historical", "/repo")
  const opened = { worktree: "/repo-linked", expanded: true }
  const query = new QueryClient()
  const server = ServerConnection.Key.make("http://localhost:1234")
  const api = OpenCode.make({ baseUrl: `http://127.0.0.1:${address.port}` })
  const data = createData({
    api: () => api,
    directory: "",
    event: { on: () => () => {}, listen: () => () => {} },
  })
  const inventory = createWorktreeInventory({
    scope: ServerScope.fromServerKey(server),
    queryClient: query,
    api: () => api.worktree,
    updated: (projectID, directory, items) =>
      setStore("project", (projects) => updateWorktreeInventory(projects, projectID, directory, items)),
  })
  const [store, setStore] = createStore({
    path: { state: "", config: "", worktree: "", directory: "", home: "" },
    project: [canonical, unrelated, historical],
    provider_auth: {},
    config: {},
    reload: undefined as undefined | "pending" | "complete",
  })
  const bootstrap = () =>
    bootstrapGlobal({
      serverAPI: {
        location: {
          get: async () => ({
            directory: "/repo-linked",
            project: { id: "repo", canonical: "/repo", directory: "/repo-linked" },
          }),
        },
        project: {
          list: async () => [
            { id: "repo", canonical: "/repo", name: "Repo", time: { created: 1, updated: 1 }, sandboxes: [] },
            {
              id: "unrelated",
              canonical: "/repository",
              name: "Unrelated",
              time: { created: 1, updated: 1 },
              sandboxes: [],
            },
            {
              id: "historical",
              canonical: "/repo",
              name: "Historical",
              time: { created: 1, updated: 1 },
              sandboxes: [],
            },
          ],
        },
      },
      scope: ServerScope.fromServerKey(server),
      setGlobalStore: setStore,
      queryClient: query,
    })
  try {
    const controller = createRoot((dispose) => ({
      dispose,
      worktrees: createSidebarWorktrees({
        data,
        sync: { worktrees: inventory },
        sdk: { connection: { status: () => "connected" } },
      } as unknown as Parameters<typeof createSidebarWorktrees>[0]),
    }))
    await controller.worktrees.load(() => {
      const location = data.location.info({ directory: opened.worktree })
      const metadata = resolveProjectMetadata(opened, undefined, location, store.project)
      return { project: sidebarProjects(server, [metadata ? { ...metadata, ...opened } : opened], [])[0], rows: [] }
    })
    controller.dispose()
    expect(requests.slice(0, 3)).toEqual(["/api/location", "/api/worktree/refresh", "/api/worktree"])
    expect(requests.filter((path) => path === "/api/vcs")).toHaveLength(3)
    const location = data.location.info({ directory: opened.worktree })!
    const discovered = inventory.cached(location.project.id, location.project.canonical)!
    expect(inventory.cached(location.project.id, opened.worktree)).toBeUndefined()
    const worktreeRequests = requests.filter((path) => path === "/api/worktree").length
    await inventory.load(location.project.id, location.project.canonical)
    expect(requests.filter((path) => path === "/api/worktree")).toHaveLength(worktreeRequests)
    await bootstrap()
    expect(store.project.find((item) => item.id === "repo")?.worktrees).toEqual(discovered)
    expect(resolveProjectMetadata({ worktree: "/repo" }, undefined, undefined, [canonical, historical])).toBeUndefined()
    expect(resolveProjectMetadata({ worktree: "/repo" }, undefined, undefined, [historical, canonical])).toBeUndefined()
    const session = {
      id: "moved",
      projectID: "repo",
      title: "Moved session",
      location: { directory: "/trees/managed-chats" },
      time: { created: 1, updated: 1 },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    }
    for (const known of [
      [unrelated, historical, canonical],
      [canonical, historical, unrelated],
    ]) {
      const metadata = resolveProjectMetadata(opened, undefined, location, known)!
      expect(metadata.id).toBe("repo")
      const hydrated = known.map((item) => store.project.find((project) => project.id === item.id) ?? item)
      const selected = { ...hydrated.find((item) => item.id === metadata.id)!, ...opened }
      const row: SidebarSession = {
        server,
        key: sessionKey(server, session.id),
        project: sidebarSessionProject(server, session, [selected]),
        session,
      }
      const sidebarProject = sidebarProjects(server, [selected], [row])[0]
      const grouped = sidebarWorktrees(sidebarProject, [row], {
        cachedInventory: discovered,
        location: () => undefined,
        branch: (directory) => (directory === session.location.directory ? "managed-chats" : undefined),
      })

      expect(selected.worktree).toBe("/repo-linked")
      expect(sidebarProject.directory).toBe("/repo-linked")
      expect(workspaceDraftTarget(selected.worktree, selected.worktree)).toEqual({
        directory: "/repo-linked",
        worktree: "main",
      })
      expect(row.project).toBe(projectKey(server, selected))
      expect(grouped.root).toEqual([])
      expect(grouped.groups.find((group) => group.directory === session.location.directory)).toMatchObject({
        name: "managed-chats",
        rows: [row],
      })
    }
    worktrees = worktrees.filter((item) => item.directory !== session.location.directory)
    await inventory.refresh(location.project.id, location.project.canonical)
    setStore("project", (projects) =>
      projects.map((item) =>
        item.id === "repo"
          ? updateProjectInfo(item, { id: "repo", name: "Updated", canonical: "/repo", time: { updated: 2 } })
          : item,
      ),
    )
    expect(store.project.find((item) => item.id === "repo")?.worktrees).not.toContainEqual({
      directory: session.location.directory,
      strategy: "git",
    })
    expect(store.project.find((item) => item.id === "unrelated")?.worktrees).toEqual([{ directory: "/repository" }])
    expect(store.project.find((item) => item.id === "historical")?.worktrees).toEqual([{ directory: "/repo" }])
    await bootstrap()
    expect(store.project.find((item) => item.id === "repo")?.worktrees).toEqual(worktrees)
    expect(store.project.find((item) => item.id === "repo")?.worktrees).not.toContainEqual({
      directory: "/trees/managed-chats",
      strategy: "git",
    })
  } finally {
    query.clear()
    apiServer.closeAllConnections()
    apiServer.close()
  }
})
