import { expect, test, type Page } from "@playwright/test"
import type { ConfigEntry } from "@opencode/client/promise"
import { mockOpenCodeServer } from "../utils/mock-server"

const directory = "/projects/lsp-demo"
const project = {
  id: "project-lsp-demo",
  canonical: directory,
  name: "LSP demo",
  vcs: "git",
  time: { created: 1, updated: 1 },
  sandboxes: [],
}

async function openLanguageServers(page: Page) {
  await page.goto("/")
  await page.getByRole("button", { name: "Settings", exact: true }).click()
  const settings = page.getByTestId("settings-screen")
  await settings.getByRole("tab", { name: "Projects", exact: true }).click()
  await settings.getByText("LSP demo", { exact: true }).click()
  const dialog = page.getByRole("dialog")
  await dialog.getByRole("tab", { name: "Extensions", exact: true }).click()
  await dialog.getByRole("tab", { name: "LSPs", exact: true }).click()
  return dialog
}

test.beforeEach(async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory,
    project,
    sessions: [],
    pageMessages: () => ({ items: [] }),
    provider: { all: [], connected: [], default: {} },
  })
  await page.addInitScript((directory) => {
    localStorage.setItem(
      "opencode.global.dat:server",
      JSON.stringify({ projects: { local: [{ worktree: directory, expanded: true }] } }),
    )
  }, directory)
  await page.route("**/api/project", (route) =>
    route.fulfill({ json: [project], headers: { "access-control-allow-origin": "*" } }),
  )
})

test("shows configured language servers and refreshes this project on config updates", async ({ page }) => {
  const first = Promise.withResolvers<void>()
  const requests: string[] = []
  let config: ConfigEntry[] = [
    {
      type: "document",
      path: "/config/opencode.json",
      info: {
        lsp: {
          typescript: { command: ["typescript-language-server", "--stdio"], extensions: [".ts", ".tsx"] },
          eslint: { disabled: true },
        },
      },
    },
  ]
  await page.route("**/api/config?*", async (route) => {
    requests.push(new URL(route.request().url()).searchParams.get("location[directory]") ?? "")
    if (requests.length === 1) await first.promise
    await route.fulfill({ json: config })
  })

  const dialog = await openLanguageServers(page)
  await expect(dialog.getByText("Loading", { exact: true })).toBeVisible()
  first.resolve()
  await expect(dialog.getByText("typescript", { exact: true })).toBeVisible()
  await expect(dialog.getByText(".ts, .tsx", { exact: true })).toBeVisible()
  await expect(dialog.getByText("Enabled in config", { exact: true })).toBeVisible()
  await expect(dialog.getByText("eslint", { exact: true })).toBeVisible()
  await expect(dialog.getByText("Disabled in config", { exact: true })).toBeVisible()

  config = [
    {
      type: "document",
      path: `${directory}/opencode.json`,
      info: { lsp: { rust: { command: ["rust-analyzer"], extensions: [".rs"] } } },
    },
  ]
  await page.evaluate((directory) => {
    const host = window as Window & { __mockServerStream?: { push: (events: unknown[]) => void } }
    host.__mockServerStream?.push([
      { id: "evt_config_updated", type: "config.updated", location: { directory }, data: {} },
    ])
  }, directory)

  await expect(dialog.getByText("rust", { exact: true })).toBeVisible()
  await expect(dialog.getByText(".rs", { exact: true })).toBeVisible()
  await expect(dialog.getByText("typescript", { exact: true })).toHaveCount(0)
  expect(requests).toEqual([directory, directory])
})

test("offers retry and reports a globally disabled LSP configuration", async ({ page }) => {
  let requests = 0
  await page.route("**/api/config?*", async (route) => {
    requests += 1
    if (requests === 1) return route.fulfill({ status: 500, json: { error: "fixture failure" } })
    await route.fulfill({ json: [{ type: "document", path: "/config/opencode.json", info: { lsp: false } }] })
  })

  const dialog = await openLanguageServers(page)
  await expect(dialog.getByRole("status")).toContainText("Could not load language server configuration")
  await dialog.getByRole("button", { name: "Retry", exact: true }).click()
  await expect(dialog.getByText("Language servers disabled", { exact: true })).toBeVisible()
  await expect(dialog.getByText("LSP is disabled in this project’s configuration", { exact: true })).toBeVisible()
  expect(requests).toBe(2)
})
