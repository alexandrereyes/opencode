import { expect, test, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"

const directory = "/repo/home-location"
const worktree = `${directory}/.worktrees/crisp-cactus`
const now = Date.now()

async function setup(page: Page) {
  const located: string[][] = []
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "proj_home_location",
      worktree: directory,
      vcs: "git",
      name: "home-location",
      time: { created: 1, updated: 1 },
      sandboxes: [worktree],
    },
    provider: { all: [], connected: [], default: {} },
    sessions: [
      {
        id: "ses_home_location_main",
        projectID: "proj_home_location",
        directory,
        title: "Main work",
        time: { created: now, updated: now },
      },
      {
        id: "ses_home_location_tree",
        projectID: "proj_home_location",
        directory: worktree,
        title: "Worktree work",
        time: { created: now, updated: now },
      },
    ],
    pageMessages: () => ({ items: [] }),
    subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
  })
  await page.route("**/api/rpc/custom.worktrees/locate", async (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback()
    const directories: string[] = route.request().postDataJSON().input.directories
    located.push(directories)
    await route.fulfill({
      headers: { "access-control-allow-origin": "*" },
      json: {
        output: directories.map((item) => ({
          directory: item,
          worktree: item,
          canonical: directory,
          branch: item === worktree ? "feature/home" : "main",
        })),
      },
    })
  })
  await page.goto("/")
  return located
}

const row = (page: Page, title: string) =>
  page.locator('[data-component="home-session-row-container"]').filter({ hasText: title })

test("pointer rows reveal the worktree and branch on hover or while Alt is held", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  const located = await setup(page)
  const tree = row(page, "Worktree work")
  const location = tree.locator('[data-component="home-session-location"]')
  await expect(location).toHaveCSS("opacity", "0")
  expect(located).toEqual([])

  await tree.hover()
  await expect(location).toHaveText("crisp-cactusfeature/home")
  await expect(location).toHaveCSS("opacity", "1")
  await page.mouse.move(0, 0)
  await expect(location).toHaveCSS("opacity", "0")

  await page.keyboard.down("Alt")
  await expect(row(page, "Main work").locator('[data-component="home-session-location"]')).toHaveCSS("opacity", "1")
  await page.keyboard.up("Alt")
  expect(located).toEqual([[worktree], [directory]])
})

test.describe("touch", () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } })

  test("touch rows show the worktree and branch without hover", async ({ page }) => {
    const located = await setup(page)
    // Chrome can apply the touch media emulation after the first navigation.
    await expect.poll(() => page.evaluate(() => matchMedia("(hover: none)").matches)).toBe(true)
    const tree = row(page, "Worktree work")
    const location = tree.locator('[data-component="home-session-location"]')
    await expect(location).toHaveCSS("opacity", "1")
    await expect(location).toContainText("crisp-cactus")
    await expect(location).toContainText("feature/home")
    await expect(tree.locator('[data-component="home-session-title"]')).toBeInViewport()
    const box = await tree.boundingBox()
    expect(box!.x + box!.width).toBeLessThanOrEqual(390)
    expect(located).toHaveLength(1)
    expect(new Set(located[0])).toEqual(new Set([directory, worktree]))
  })
})
