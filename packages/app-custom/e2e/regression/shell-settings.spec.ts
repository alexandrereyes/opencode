import { expect, test, type Route } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"
import { installSseTransport } from "../utils/sse-transport"
import { pressPlatformShortcut } from "../utils/command-palette"

const serverA = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const serverB = "http://127.0.0.1:4199"
const directory = "/workspace/shell-settings"
const sessionB = {
  id: "ses_shell_server_b",
  projectID: "project-b",
  title: "Server B shell session",
  location: { directory: "/workspace/server-b" },
  time: { created: 1, updated: 1 },
}

test("selects and persists the global shell for the active settings server", async ({ page }) => {
  const updates: Array<{ shell: string | null }> = []
  const failedUpdate = Promise.withResolvers<void>()
  const releaseFailedUpdate = Promise.withResolvers<void>()
  const releaseServerB = Promise.withResolvers<void>()
  let fail = false

  await mockOpenCodeServer(page, {
    directory,
    project: { id: "project-shell-settings", canonical: directory, vcs: "git", time: { created: 1, updated: 1 } },
    provider: { all: [], connected: [], default: {} },
    sessions: [],
    pageMessages: () => ({ items: [] }),
  })
  await installSseTransport(page, { server: serverB })
  await page.addInitScript((server) => {
    localStorage.setItem("opencode.global.dat:server", JSON.stringify({ list: [server] }))
  }, serverB)
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url())
    if (url.origin === serverA && url.pathname === "/api/config" && route.request().method() === "GET") {
      return json(route, [
        { type: "document", path: "/global-a.json", info: { shell: "bash" } },
        { type: "document", path: "/global-b.json", info: { shell: "zsh" } },
        { type: "directory", path: directory },
        { type: "document", path: `${directory}/opencode.json`, info: { shell: "fish" } },
      ])
    }
    if (url.origin === serverA && url.pathname === "/api/config/shell") {
      return json(route, [
        { path: "/bin/bash", name: "bash", acceptable: true },
        { path: "/bin/zsh", name: "zsh", acceptable: true },
      ])
    }
    if (url.origin === serverA && url.pathname === "/api/experimental/config") {
      const body = route.request().postDataJSON() as { shell: string | null }
      updates.push(body)
      if (!fail) return route.fulfill({ status: 204, headers: corsHeaders })
      failedUpdate.resolve()
      await releaseFailedUpdate.promise
      return route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ message: "save failed" }),
      })
    }
    if (url.origin === serverB) return mockServerB(route, releaseServerB.promise)
    return route.fallback()
  })

  await page.goto("/")
  await page.getByRole("button", { name: "Settings", exact: true }).click()
  const settings = page.getByTestId("settings-screen")
  const shell = settings.locator('[data-action="settings-shell"]')
  await expect(shell).toContainText("zsh")

  await shell.click()
  await page.getByRole("option", { name: "bash", exact: true }).click()
  await expect(shell).toContainText("bash")
  await expect.poll(() => updates).toEqual([{ shell: "bash" }])

  await shell.click()
  await page.getByRole("option", { name: "Auto (Default)", exact: true }).click()
  await expect(shell).toContainText("Auto (Default)")
  await expect.poll(() => updates).toEqual([{ shell: "bash" }, { shell: null }])

  fail = true
  await shell.click()
  await page.getByRole("option", { name: "bash", exact: true }).click()
  await failedUpdate.promise
  await expect(shell).toContainText("bash")
  releaseFailedUpdate.resolve()
  await expect(shell).toContainText("Auto (Default)")
  await expect(page.getByText("Request failed", { exact: true })).toBeVisible()

  await settings.getByRole("tab", { name: "Models", exact: true }).click()
  const server = settings.locator('[data-action="settings-server-select"]')
  await server.click()
  await page.getByRole("option", { name: "127.0.0.1:4199", exact: true }).click()
  await settings.getByRole("button", { name: "Back to app", exact: true }).click()
  await page.goto(`/server/${base64Encode(serverB)}/session/${sessionB.id}`)
  await expect(page.getByRole("heading", { name: sessionB.title, exact: true })).toBeVisible()
  await pressPlatformShortcut(page, ",")
  await settings.getByRole("tab", { name: "Preferences", exact: true }).click()
  await expect(shell).toContainText("Auto (Default)")
  releaseServerB.resolve()
  await expect(shell).toContainText("pwsh")
})

async function mockServerB(route: Route, configReady: Promise<void>) {
  const url = new URL(route.request().url())
  if (route.request().method() === "OPTIONS") return route.fulfill({ status: 204, headers: corsHeaders })
  if (url.pathname === "/api/info") return json(route, { version: "2.0.0" })
  if (url.pathname === "/api/global/health" || url.pathname === "/api/health")
    return json(route, { healthy: true, version: "2.0.0", pid: 2 })
  if (url.pathname === "/api/config") {
    await configReady
    return json(route, [
      { type: "document", path: "/global.json", info: { shell: "pwsh" } },
      { type: "directory", path: "/workspace/server-b" },
      { type: "document", path: "/workspace/server-b/opencode.json", info: { shell: "fish" } },
    ])
  }
  if (url.pathname === "/api/config/shell") return json(route, [{ path: "/bin/pwsh", name: "pwsh", acceptable: true }])
  const location = {
    directory: "/workspace/server-b",
    project: { id: "project-b", directory: "/workspace/server-b", canonical: "/workspace/server-b" },
  }
  if (url.pathname === "/api/location") return json(route, location)
  if (url.pathname === "/api/project")
    return json(route, [
      { id: "project-b", canonical: "/workspace/server-b", vcs: "git", time: { created: 1, updated: 1 } },
    ])
  if (url.pathname === "/api/project/current") return json(route, location.project)
  if (url.pathname === "/api/worktree") return json(route, [{ directory: location.directory }])
  if (url.pathname === "/api/session") return json(route, { data: [sessionB], cursor: {} })
  if (url.pathname === "/api/session/active") return json(route, { data: { [sessionB.id]: { type: "idle" } } })
  if (url.pathname === `/api/session/${sessionB.id}`) return json(route, { data: sessionB })
  if (url.pathname === `/api/session/${sessionB.id}/message`) return json(route, { data: [], cursor: {} })
  if (url.pathname === `/api/session/${sessionB.id}/inbox`) return json(route, { data: [] })
  if (url.pathname === `/api/session/${sessionB.id}/permission`) return json(route, { location, data: [] })
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
