import { expect, test } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"

const server = `http://127.0.0.1:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4999"}`

for (const viewport of [
  { width: 1440, height: 900 },
  { width: 390, height: 844 },
]) {
  test(`project options preserve close confirmation at ${viewport.width}`, async ({ page }) => {
    await page.setViewportSize(viewport)
    await mockOpenCodeServer(page, {
      directory: "/projects/example",
      project: {
        id: "project-example",
        name: "Example",
        canonical: "/projects/example",
        vcs: "git",
        time: { created: 1, updated: 1 },
        sandboxes: [],
      },
      sessions: [],
      pageMessages: () => ({ items: [] }),
      fileList: () => [],
      provider: { all: [], connected: [], default: {} },
      subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
    })
    await page.addInitScript((server) => {
      localStorage.setItem(
        "opencode.global.dat:server",
        JSON.stringify({ projects: { [server]: [{ worktree: "/projects/example", expanded: true }] } }),
      )
      localStorage.setItem(
        "opencode.global.dat:notification",
        JSON.stringify({
          list: [{ type: "turn-complete", directory: "/projects/example", time: Date.now(), viewed: false }],
        }),
      )
    }, server)
    await page.route("**/api/info", (route) =>
      route.fulfill({ json: { version: "2.0.0" }, headers: { "access-control-allow-origin": "*" } }),
    )
    await page.goto("/settings?tab=projects")
    const row = page.locator('[data-component="settings-project-row"][data-project-path="/projects/example"]')
    await expect(row.getByRole("button", { name: "Example", exact: true })).toBeVisible()
    await row.getByRole("button", { name: "More options" }).click()
    await page.getByRole("menuitem", { name: "Clear notifications" }).click()
    await row.getByRole("button", { name: "More options" }).click()
    await expect(page.getByRole("menuitem", { name: "Clear notifications" })).toBeDisabled()
    await page.getByRole("menuitem", { name: "Close", exact: true }).click()
    const dialog = page.getByRole("dialog")
    await dialog.getByRole("button", { name: "Cancel", exact: true }).click()
    await expect(row.getByRole("button", { name: "Example", exact: true })).toBeFocused()
    await row.getByRole("button", { name: "More options" }).click()
    await page.getByRole("menuitem", { name: "Close", exact: true }).click()
    await dialog.getByRole("button", { name: "Remove from sidebar", exact: true }).click()
    await expect(row).toHaveCount(0)
    const body = page.getByRole("tabpanel").locator(".settings-tab-body")
    await body.getByRole("button", { name: "Open project", exact: true }).click()
    await expect(dialog.getByRole("heading", { name: "Open project", exact: true })).toBeVisible()
    await dialog.getByRole("button", { name: "Add project", exact: true }).click()
    await expect(row.getByRole("button", { name: "Example", exact: true })).toBeVisible()
  })
}
