import { expect, test } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"

const directory = "/projects/settings-search-autofocus"

test.use({ viewport: { width: 1280, height: 900 } })

test.beforeEach(async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "proj_settings_search_autofocus",
      canonical: directory,
      name: "Settings search autofocus",
      vcs: "git",
      time: { created: 1700000000000, updated: 1700000000000 },
    },
    provider: { all: [], connected: [], default: {} },
    sessions: [],
    pageMessages: () => ({ items: [] }),
  })
  await page.goto("/")
  await page.getByRole("button", { name: "Settings", exact: true }).click()
  await expect(page.getByTestId("settings-screen")).toBeFocused()
})

test("focuses model and shortcut searches while preserving Option shortcut recording", async ({ page }) => {
  const settings = page.getByTestId("settings-screen")
  await settings.getByRole("tab", { name: "Shortcuts", exact: true }).click()
  await expect(settings.getByRole("searchbox", { name: "Search shortcuts", exact: true })).toBeFocused()

  const binding = settings.locator('[data-keybind-id="tab.new"]')
  await binding.click()
  await expect(binding).toHaveText("Press keys")
  await binding.dispatchEvent("keydown", {
    key: "¬",
    code: "KeyL",
    altKey: true,
    bubbles: true,
    cancelable: true,
  })
  await expect(binding).toHaveText(
    await page.evaluate(() => (/Mac|iPod|iPhone|iPad/.test(navigator.platform) ? "⌥L" : "Alt+L")),
  )
  await expect(page).toHaveURL("/settings")

  await settings.getByRole("tab", { name: "Models", exact: true }).click()
  await expect(settings.getByRole("searchbox", { name: "Search models", exact: true })).toBeFocused()
  await settings.getByRole("tab", { name: "Shortcuts", exact: true }).click()
  await expect(settings.getByRole("searchbox", { name: "Search shortcuts", exact: true })).toBeFocused()
})
