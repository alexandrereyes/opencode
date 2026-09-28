import { expect, test } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"

const directory = "/projects/settings-route"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test.use({ serviceWorkers: "block" })

for (const [width, height] of [
  [1440, 900],
  [390, 844],
]) {
  test(`settings pages survive a reload at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await mockOpenCodeServer(page, {
      directory,
      project: {
        id: "proj_settings_route",
        canonical: directory,
        worktree: directory,
        name: "Settings route",
        vcs: "git",
        time: { created: 1, updated: 1 },
      },
      provider: { all: [], connected: [], default: {} },
      sessions: [],
      pageMessages: () => ({ items: [] }),
      subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
    })
    await page.goto("/settings")
    const settings = page.getByTestId("settings-screen")
    if (width > 390) await settings.getByRole("tab", { name: "Snippets", exact: true }).click()
    if (width === 390) {
      await settings.getByRole("button", { name: "Preferences", exact: true }).click()
      await page.getByRole("menuitemradio", { name: "Snippets", exact: true }).click()
    }
    await expect(page).toHaveURL("/settings?tab=snippets")
    await page.reload()
    await expect(settings.getByRole("heading", { name: "Snippets", exact: true })).toBeVisible()

    await page.goto(
      `/settings?server=${encodeURIComponent(server)}&project=${encodeURIComponent(directory)}&tab=extensions`,
    )
    await settings.getByRole("tab", { name: "LSPs", exact: true }).click()
    await expect(page).toHaveURL(/[?&]subtab=lsps(&|$)/)
    await page.reload()
    await expect(settings.getByRole("tab", { name: "LSPs", exact: true })).toHaveAttribute("aria-selected", "true")
    await settings.getByRole("button", { name: "Back to projects", exact: true }).click()
    await expect(page).toHaveURL("/settings?tab=projects")
  })
}
