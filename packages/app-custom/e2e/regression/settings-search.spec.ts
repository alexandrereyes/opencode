import { expect, test, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"

const directory = "/projects/settings-search"
const project = {
  id: "project-settings-search",
  canonical: directory,
  name: "Search Fixture",
  icon: { color: "orange" },
  vcs: "git",
  time: { created: 1, updated: 1 },
  sandboxes: [],
}

function ui(page: Page) {
  const settings = page.getByTestId("settings-screen")
  return {
    settings,
    search: settings.getByRole("combobox", { name: "Search", exact: true }),
    results: settings.getByRole("listbox", { name: "Settings results", exact: true }),
  }
}

async function findShortcut(page: Page) {
  await page.keyboard.press(
    await page.evaluate(() => (/Mac|iPhone|iPad|iPod/.test(navigator.platform) ? "Meta+f" : "Control+f")),
  )
}

test.beforeEach(async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory,
    project,
    provider: { all: [], connected: [], default: {} },
    snippets: [{ id: "snippet-search", name: "Review", aliases: [], description: "Review changes", content: "Review" }],
    sessions: [],
    pageMessages: () => ({ items: [] }),
  })
  await page.addInitScript((directory) => {
    localStorage.setItem(
      "opencode.global.dat:server",
      JSON.stringify({ projects: { local: [{ worktree: directory, expanded: true }] } }),
    )
  }, directory)
  await page.goto("/")
  await page.getByRole("button", { name: "Settings", exact: true }).click()
  const view = ui(page)
  await view.search.fill("Search Fixture")
  await expect(view.results.getByRole("option", { name: /^Search Fixture,/ })).toBeVisible()
  await view.search.clear()
})

test("searches custom pages and controls with keyboard navigation and local find", async ({ page }) => {
  const view = ui(page)
  await view.settings.evaluate((root) => {
    root.setAttribute("data-search-flashes", "0")
    root.addEventListener("animationstart", (event) => {
      if (!(event instanceof AnimationEvent) || event.animationName !== "settings-search-reveal") return
      root.setAttribute("data-search-flashes", String(Number(root.getAttribute("data-search-flashes")) + 1))
    })
  })
  await view.search.fill("command palette")
  const commandPalette = view.results.getByRole("option", { name: /^Command palette,/ })
  await expect(commandPalette).toBeVisible()
  await view.search.press("Enter")
  await expect(view.settings.locator('[data-action="settings-show-search"]')).toBeInViewport()
  await expect(commandPalette).toHaveAttribute("aria-current", "location")
  await expect(view.settings).toHaveAttribute("data-search-flashes", "1")

  await findShortcut(page)
  await expect(view.search).toBeFocused()
  await view.search.fill("snippets")
  await view.search.press("ArrowDown")
  await view.search.press("Enter")
  await expect(view.settings.getByRole("heading", { name: "Snippets", exact: true })).toBeVisible()

  await view.search.fill("manual favorites")
  await view.search.press("Enter")
  await expect(view.settings.getByRole("heading", { name: "Models", exact: true })).toBeVisible()
  await expect(view.search).toBeFocused()

  await view.search.fill("skills")
  await view.search.press("Enter")
  await expect(view.settings.getByRole("tab", { name: "Skills", exact: true })).toHaveAttribute("aria-selected", "true")
})

test("restores project search query, selected result, and result scroll", async ({ page }) => {
  const projects = Array.from({ length: 30 }, (_, index) => ({
    ...project,
    id: `project-search-${index}`,
    canonical: `/projects/search-${index}`,
    name: `Search Archive ${String(index).padStart(2, "0")}`,
  }))
  await page.route("**/api/project", (route) =>
    route.fulfill({ json: projects, headers: { "access-control-allow-origin": "*" } }),
  )
  await page.addInitScript((projects) => {
    localStorage.setItem(
      "opencode.global.dat:server",
      JSON.stringify({ projects: { local: projects.map((item) => ({ worktree: item.canonical, expanded: true })) } }),
    )
  }, projects)
  await page.reload()
  const view = ui(page)
  await view.search.fill("Search Archive")
  await expect(view.results.getByRole("option")).toHaveCount(30)
  const result = view.results.getByRole("option", { name: /^Search Archive 25,/ })
  await result.scrollIntoViewIfNeeded()
  const viewport = view.settings.locator(".settings-search-scroll > .scroll-view__viewport")
  await expect.poll(() => viewport.evaluate((element) => element.scrollTop)).toBeGreaterThan(0)
  const scroll = await viewport.evaluate((element) => element.scrollTop)
  await result.click()
  await expect(view.search).toHaveCount(0)
  await expect(view.settings.getByRole("tab", { name: "Search Archive 25", exact: true })).toHaveAttribute(
    "aria-selected",
    "true",
  )
  await view.settings.getByRole("button", { name: "Back to settings", exact: true }).click()
  await expect(view.search).toBeFocused()
  await expect(view.search).toHaveValue("Search Archive")
  await expect(result).toHaveAttribute("aria-selected", "true")
  await expect.poll(() => viewport.evaluate((element) => element.scrollTop)).toBe(scroll)
})

test("opens a searched project extension subtab and restores its qualified result", async ({ page }) => {
  const view = ui(page)
  await view.search.fill("Search Fixture skills")
  const result = view.results.getByRole("option", { name: /^Skills, .*Search Fixture/ })
  await result.click()
  await expect(view.search).toHaveCount(0)
  await expect(view.settings.getByRole("tab", { name: "Skills", exact: true })).toHaveAttribute("aria-selected", "true")
  await view.settings.getByRole("button", { name: "Back to settings", exact: true }).click()
  await expect(view.search).toBeFocused()
  await expect(view.search).toHaveValue("Search Fixture skills")
  await expect(result).toHaveAttribute("aria-selected", "true")
})

for (const direction of ["ltr", "rtl"] as const) {
  test(`keeps the narrow English search usable in forced ${direction.toUpperCase()}`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.evaluate((value) => {
      document.documentElement.lang = "en"
      document.documentElement.dir = value
    }, direction)
    const view = ui(page)
    await view.search.fill("zzzz ".repeat(30))
    await view.search.press("End")
    await expect(view.search).toHaveAttribute("data-overflow-start", "true")
    await expect(view.settings.getByRole("status")).toHaveAccessibleName(/No results for/)
    await expect.poll(() => view.settings.evaluate((root) => root.scrollWidth <= root.clientWidth)).toBe(true)
    await view.search.press("Escape")
    await expect(view.search).toHaveValue("")
    await expect(view.settings.getByRole("tab", { name: "Preferences", exact: true })).toBeHidden()
    const pages = view.settings.getByRole("button", { name: "Preferences", exact: true })
    await pages.click()
    await expect
      .poll(() => page.getByRole("menu").evaluate((element) => getComputedStyle(element).direction))
      .toBe(direction)
    await page.getByRole("menuitemradio", { name: "Snippets", exact: true }).click()
    await expect(view.settings.getByRole("heading", { name: "Snippets", exact: true })).toBeVisible()
  })
}
