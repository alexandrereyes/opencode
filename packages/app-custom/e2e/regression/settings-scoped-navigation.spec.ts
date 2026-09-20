import { expect, test, type Route } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { installSseTransport } from "../utils/sse-transport"

const server = "http://127.0.0.1:4199"
const directory = "/workspace/scoped-project"
const project = {
  id: "project-scoped-navigation",
  canonical: directory,
  name: "Scoped project",
  vcs: "git",
  time: { created: 1, updated: 1 },
  sandboxes: [],
}
const otherProject = {
  ...project,
  id: "project-outside-scope",
  canonical: "/workspace/outside-scope",
  name: "Outside scope",
}

test("navigates root, server, and project settings while preserving scope and app return", async ({ page }) => {
  const providerRequests: string[] = []
  const pluginRequests: string[] = []
  const projectUpdates: unknown[] = []

  await mockOpenCodeServer(page, {
    directory: "/workspace/origin",
    project: {
      id: "project-origin",
      canonical: "/workspace/origin",
      name: "Origin project",
      vcs: "git",
      time: { created: 1, updated: 1 },
      sandboxes: [],
    },
    sessions: [],
    pageMessages: () => ({ items: [] }),
    provider: { all: [], connected: [], default: {} },
    snippets: [{ id: "snippet-root", name: "Root snippet", aliases: [], description: "", content: "status" }],
  })
  await installSseTransport(page, { server })
  await page.addInitScript(
    ({ server, directory }) => {
      localStorage.setItem(
        "opencode.global.dat:server",
        JSON.stringify({
          list: [server],
          projects: {
            local: [{ worktree: "/workspace/origin", expanded: true }],
            [server]: [{ worktree: directory, expanded: true }],
          },
        }),
      )
    },
    { server, directory },
  )
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url())
    if (url.origin !== server) return route.fallback()
    if (url.pathname === "/api/provider") providerRequests.push(route.request().url())
    if (url.pathname === "/api/plugin") pluginRequests.push(route.request().url())
    if (url.pathname === `/api/project/${project.id}` && route.request().method() === "PATCH") {
      projectUpdates.push(route.request().postDataJSON())
      return json(route, { ...project, name: "Renamed scoped project" })
    }
    return mockScopedServer(route)
  })

  await page.goto("/")
  await page.getByRole("button", { name: "Settings", exact: true }).click()
  const settings = page.getByTestId("settings-screen")
  await expect(page).toHaveURL("/settings")
  await expect(settings.getByRole("heading", { name: "Preferences", exact: true })).toBeVisible()

  await settings.getByRole("tab", { name: "Snippets", exact: true }).click()
  await expect(settings.getByRole("heading", { name: "Snippets", exact: true })).toBeVisible()
  await settings.getByRole("tab", { name: "Preferences", exact: true }).click()
  await expect(settings.getByRole("heading", { name: "Preferences", exact: true })).toBeVisible()

  await settings.getByRole("tab", { name: "127.0.0.1:4199", exact: true }).click()
  await expect(settings.getByRole("button", { name: "Back to settings", exact: true })).toBeVisible()
  await expect(settings.getByRole("heading", { name: "127.0.0.1:4199", exact: true })).toBeVisible()
  await expect(settings.getByRole("tab", { name: "127.0.0.1:4199", exact: true })).toHaveAttribute(
    "aria-selected",
    "true",
  )

  await settings.getByRole("tab", { name: "Providers", exact: true }).click()
  await expect(settings.getByRole("heading", { name: "Providers", exact: true })).toBeVisible()
  await expect.poll(() => providerRequests.length).toBeGreaterThan(0)
  expect(new URL(providerRequests.at(-1)!).origin).toBe(server)
  await settings.getByRole("button", { name: "Show more providers", exact: true }).click()
  const providers = page.getByRole("dialog")
  await expect(providers.getByPlaceholder("Search providers", { exact: true })).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(providers).toBeHidden()

  await settings.getByRole("tab", { name: "Projects", exact: true }).click()
  await expect(settings.getByRole("heading", { name: "Projects", exact: true })).toBeVisible()
  await settings.getByRole("button", { name: /Scoped project/ }).click()
  await expect(settings.getByRole("button", { name: "Back to projects", exact: true })).toBeVisible()
  await expect(settings.getByRole("tab", { name: "Scoped project", exact: true })).toHaveAttribute(
    "aria-selected",
    "true",
  )
  await page.keyboard.press("Escape")
  await expect(settings.getByRole("heading", { name: "Projects", exact: true })).toBeVisible()
  await settings.getByRole("button", { name: /Scoped project/ }).click()
  await expect(settings.getByRole("button", { name: "Back to projects", exact: true })).toBeVisible()

  await settings.getByRole("tab", { name: "Worktrees", exact: true }).click()
  await expect(settings.getByRole("heading", { name: "Worktrees", exact: true })).toBeVisible()
  await expect(settings.getByRole("button", { name: "All projects", exact: true })).toHaveCount(0)
  await expect(settings.getByText(otherProject.canonical, { exact: true })).toHaveCount(0)
  await settings.getByRole("tab", { name: "Extensions", exact: true }).click()
  await expect(settings.getByRole("tab", { name: "Extensions", exact: true })).toHaveAttribute("aria-selected", "true")
  await expect
    .poll(() =>
      pluginRequests.some((request) => {
        const url = new URL(request)
        return url.origin === server && url.searchParams.get("location[directory]") === directory
      }),
    )
    .toBe(true)
  await settings.getByRole("tab", { name: "Scoped project", exact: true }).click()

  await settings.getByRole("button", { name: "Edit project", exact: true }).click()
  const editor = page.getByRole("dialog")
  await expect(editor.getByRole("button", { name: "Save", exact: true })).toBeVisible()
  await editor.getByRole("button", { name: "Cancel", exact: true }).click()
  await expect(editor).toBeHidden()

  await settings.getByRole("button", { name: "Edit project", exact: true }).click()
  await editor.getByRole("textbox").fill("Renamed scoped project")
  await editor.getByRole("button", { name: "Save", exact: true }).click()
  await expect(editor).toBeHidden()
  await expect(settings.getByRole("tab", { name: "Renamed scoped project", exact: true })).toHaveAttribute(
    "aria-selected",
    "true",
  )
  expect(projectUpdates).toEqual([
    {
      name: "Renamed scoped project",
      icon: { color: "", override: "" },
      commands: { start: "" },
    },
  ])

  await settings.getByRole("button", { name: "Back to projects", exact: true }).click()
  await expect(settings.getByRole("heading", { name: "Projects", exact: true })).toBeVisible()
  await settings.getByRole("button", { name: "Back to settings", exact: true }).click()
  await expect(settings.getByRole("heading", { name: "Preferences", exact: true })).toBeVisible()
  await settings.getByRole("button", { name: "Back to app", exact: true }).click()
  await expect(page).toHaveURL("/")
  await expect(settings).toBeHidden()
})

async function mockScopedServer(route: Route) {
  const url = new URL(route.request().url())
  if (route.request().method() === "OPTIONS") return route.fulfill({ status: 204, headers: corsHeaders })
  if (url.pathname === "/api/info") return json(route, { version: "2.0.0" })
  if (url.pathname === "/api/global/health" || url.pathname === "/api/health")
    return json(route, { healthy: true, version: "2.0.0", pid: 2 })
  const location = {
    directory,
    project: { id: project.id, directory, canonical: directory },
  }
  if (url.pathname === "/api/location") return json(route, location)
  if (url.pathname === "/api/project") return json(route, [project, otherProject])
  if (url.pathname === "/api/project/current") return json(route, location.project)
  if (url.pathname === "/api/worktree") return json(route, [{ directory }])
  if (url.pathname === "/api/session") return json(route, { data: [], cursor: {} })
  if (url.pathname === "/api/session/active") return json(route, { data: {} })
  if (url.pathname === "/api/config") return json(route, [{ type: "directory", path: directory }])
  if (url.pathname === "/api/config/shell") return json(route, [])
  if (url.pathname === "/api/provider") return json(route, { location, data: [] })
  if (url.pathname === "/api/model") return json(route, { location, data: [] })
  if (url.pathname === "/api/model/default") return json(route, { location, data: undefined })
  if (url.pathname === "/api/agent") return json(route, { location, data: [] })
  if (
    [
      "/api/reference",
      "/api/command",
      "/api/skill",
      "/api/plugin",
      "/api/permission/request",
      "/api/question/request",
    ].includes(url.pathname)
  )
    return json(route, { location, data: [] })
  if (url.pathname === "/api/mcp") return json(route, { location, data: [] })
  if (url.pathname === "/api/mcp/resource") return json(route, { location, data: { resources: [], templates: [] } })
  if (url.pathname === "/api/vcs")
    return json(route, { location, data: { branch: { current: "main", default: "main" } } })
  if (url.pathname === "/api/rpc/custom.preferences/get")
    return json(route, {
      output: {
        version: 1,
        revision: 0,
        imported: true,
        data: { projects: {}, sidebarOrder: [], pinnedSessions: [], models: { user: [], variant: {} }, settings: {} },
      },
    })
  if (url.pathname.startsWith("/api/rpc/")) return json(route, { output: { items: [] } })
  return json(route, {})
}

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({ status, contentType: "application/json", headers: corsHeaders, body: JSON.stringify(body) })
}

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "*",
  "access-control-allow-methods": "GET, POST, PATCH, OPTIONS",
}
