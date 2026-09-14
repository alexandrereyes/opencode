import { expect, test } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"

// Run with VITE_OPENCODE_CUSTOM_UPDATES=1 for the Web updater, and without it
// for the ordinary Web build. Both use the real SettingsGeneral component.
const custom = process.env.VITE_OPENCODE_CUSTOM_UPDATES === "1"

for (const width of [1280, 390]) {
  test.describe(`update settings at ${width}px`, () => {
    test.use({ viewport: { width, height: 900 }, locale: "en-US" })

    test("exposes the updater action only when the Web platform supplies it", async ({ page }) => {
      await mockOpenCodeServer(page, {
        directory: "/settings-updates-fixture",
        project: {
          id: "proj_updates",
          canonical: "/settings-updates-fixture",
          vcs: "git",
          time: { created: 1, updated: 1 },
          sandboxes: [],
        },
        provider: { all: [], connected: [], default: {} },
        sessions: [],
        pageMessages: () => ({ items: [] }),
      })
      await page.route("**/api/rpc/custom.updates/check", (route) =>
        route.fulfill({ json: { output: { status: "up-to-date" } } }),
      )
      await page.goto("/settings")
      const settings = page.getByTestId("settings-screen")
      await expect(settings.getByRole("heading", { name: "Preferences", exact: true })).toBeVisible()
      const heading = settings.getByRole("heading", { name: "Updates", exact: true })
      if (!custom) {
        await expect(settings.getByRole("heading", { name: "General", exact: true })).toBeVisible()
        await expect(heading).toHaveCount(0)
        return
      }
      await expect(heading).toBeVisible()
      const button = settings.getByRole("button", { name: "Check now", exact: true })
      await expect(button).toBeEnabled()
      const request = page.waitForRequest(
        (request) => new URL(request.url()).pathname === "/api/rpc/custom.updates/check" && request.method() === "POST",
      )
      await button.click()
      await request
      await expect(page.getByText("You're up to date", { exact: true })).toBeVisible()
      await expect(button).toBeEnabled()
    })
  })
}
