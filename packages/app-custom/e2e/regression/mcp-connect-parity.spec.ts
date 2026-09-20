import { base64Encode } from "@opencode/util/encode"
import { expect, test } from "@playwright/test"
import { pressPlatformShortcut } from "../utils/command-palette"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const directory = "C:\\OpenCode\\mcp-parity"
const projectID = "proj_mcp_parity"
const sessionID = "ses_mcp_parity"
const title = "MCP connection parity"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test("connects, refreshes into OAuth, opens authorization, and disconnects", async ({ context, page }) => {
  const requests: { method: string; path: string; directory?: string; body?: unknown }[] = []
  const state = { status: "disabled" }
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "mcp-parity",
      time: { created: 1700000000000, updated: 1700000000000 },
      sandboxes: [],
    },
    provider: { all: [], connected: [], default: {} },
    sessions: [{ id: sessionID, projectID, directory, title }],
    pageMessages: () => ({ items: [] }),
  })
  await context.route("https://oauth.example/authorize", (route) =>
    route.fulfill({ contentType: "text/html", body: "<!doctype html><title>MCP authorization</title>" }),
  )
  await page.route("**/api/integration/**", async (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback()
    const url = new URL(route.request().url())
    const method = route.request().method()
    requests.push({
      method,
      path: url.pathname,
      directory: url.searchParams.get("location[directory]") ?? undefined,
      body: method === "POST" ? (route.request().postDataJSON() ?? undefined) : undefined,
    })
    if (url.pathname === "/api/integration/github-oauth") {
      return route.fulfill({
        json: {
          location: { directory },
          data: {
            id: "github-oauth",
            name: "GitHub OAuth",
            methods: [{ id: "browser", type: "oauth", label: "Browser" }],
            connections: [],
          },
        },
      })
    }
    if (url.pathname === "/api/integration/github-oauth/connect/oauth") {
      state.status = "connected"
      return route.fulfill({
        json: {
          location: { directory },
          data: {
            attemptID: "con_mcp_parity",
            url: "https://oauth.example/authorize",
            instructions: "Authorize GitHub",
            mode: "auto",
            time: { created: 1700000000000, expires: 1700000300000 },
          },
        },
      })
    }
    return route.fallback()
  })
  await page.route("**/api/experimental/mcp/**", async (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback()
    const url = new URL(route.request().url())
    requests.push({
      method: route.request().method(),
      path: url.pathname,
      directory: url.searchParams.get("location[directory]") ?? undefined,
    })
    if (url.pathname === "/api/experimental/mcp/github/connect") state.status = "needs_auth"
    if (url.pathname === "/api/experimental/mcp/github/disconnect") state.status = "disabled"
    return route.fulfill({ status: 204 })
  })
  await page.route("**/api/mcp**", async (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback()
    const url = new URL(route.request().url())
    requests.push({
      method: route.request().method(),
      path: url.pathname,
      directory: url.searchParams.get("location[directory]") ?? undefined,
    })
    return route.fulfill({
      json: {
        location: { directory },
        data:
          url.pathname === "/api/mcp/resource"
            ? { resources: [], templates: [] }
            : [
                {
                  name: "github",
                  status: { status: state.status },
                  integrationID: state.status === "needs_auth" ? "github-oauth" : undefined,
                },
              ],
      },
    })
  })

  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  await expectSessionTitle(page, title)
  await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeEditable()
  await pressPlatformShortcut(page, "Shift+P")
  const palette = page.getByRole("dialog")
  await palette.getByRole("textbox").fill("Toggle MCPs")
  await expect(palette.getByRole("option", { name: /^Toggle MCPs/ })).toHaveAttribute("aria-selected", "true")
  await palette.getByRole("textbox").press("Enter")
  const dialog = page.getByRole("dialog", { name: "MCPs", exact: true })
  const toggle = dialog.getByRole("switch")
  await expect(toggle).not.toBeChecked()

  requests.length = 0
  const authorization = context.waitForEvent("page")
  await dialog.locator('[data-slot="switch-control"]').click()
  const oauth = await authorization
  await expect(oauth).toHaveURL("https://oauth.example/authorize")
  await expect(oauth).toHaveTitle("MCP authorization")
  expect(requests).toContainEqual({
    method: "POST",
    path: "/api/integration/github-oauth/connect/oauth",
    directory,
    body: { methodID: "browser" },
  })
  expect(requests.map((request) => request.path)).toEqual([
    "/api/mcp",
    "/api/experimental/mcp/github/connect",
    "/api/mcp",
    "/api/integration/github-oauth",
    "/api/integration/github-oauth/connect/oauth",
    "/api/mcp/resource",
  ])
  await oauth.close()

  await page.reload()
  await expectSessionTitle(page, title)
  await pressPlatformShortcut(page, "Shift+P")
  const refreshedPalette = page.getByRole("dialog")
  await refreshedPalette.getByRole("textbox").fill("Toggle MCPs")
  await expect(refreshedPalette.getByRole("option", { name: /^Toggle MCPs/ })).toHaveAttribute(
    "aria-selected",
    "true",
  )
  await refreshedPalette.getByRole("textbox").press("Enter")
  const refreshedDialog = page.getByRole("dialog", { name: "MCPs", exact: true })
  const refreshedToggle = refreshedDialog.getByRole("switch")
  await expect(refreshedToggle).toBeChecked()

  requests.length = 0
  await refreshedDialog.locator('[data-slot="switch-control"]').click()
  await expect(refreshedToggle).not.toBeChecked()
  expect(requests.map((request) => request.path)).toEqual([
    "/api/mcp",
    "/api/experimental/mcp/github/disconnect",
    "/api/mcp",
    "/api/mcp/resource",
  ])
  expect(requests.filter((request) => request.path.endsWith("/disconnect"))).toEqual([
    { method: "POST", path: "/api/experimental/mcp/github/disconnect", directory },
  ])
})
