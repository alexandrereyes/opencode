import { base64Encode } from "@opencode/util/encode"
import { expect, test, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const directory = "C:/OpenCode/ReviewWithoutGit"
const projectID = "proj_review_without_git"
const sessionID = "ses_review_without_git"
const title = "Review without Git"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

for (const view of ["desktop", "mobile"] as const) {
  test(`offers Git initialization for a project without VCS (${view})`, async ({ page }) => {
    await page.setViewportSize(view === "desktop" ? { width: 1440, height: 900 } : { width: 390, height: 844 })
    const project = await setup(page)
    const requests: { directory: string | null; provider: string | null }[] = []
    const release = Promise.withResolvers<void>()
    await page.route("**/api/vcs/init**", async (route) => {
      if (route.request().method() !== "POST") return route.fallback()
      const url = new URL(route.request().url())
      requests.push({
        directory: url.searchParams.get("location[directory]"),
        provider: url.searchParams.get("provider"),
      })
      await release.promise
      project.vcs = "git"
      return route.fulfill({ status: 204, headers: { "access-control-allow-origin": "*" } })
    })
    const panel = await openReview(page, view)

    // Both layouts show the same empty state, as upstream.
    await expect(panel.getByText("No tracked changes", { exact: true })).toBeVisible()
    await expect(panel.getByText("Track, review, and undo changes in this project")).toBeVisible()
    await expect(panel.getByRole("button", { name: "Git changes" })).toHaveCount(0)
    // Without a mode selector the mobile list header has nothing to show, so it is not rendered.
    if (view === "mobile") await expect(panel.locator('[data-slot="session-review-header"]')).toBeHidden()
    const init = panel.getByRole("button", { name: "Create Git repository" })
    await init.click()
    const pending = panel.getByRole("button", { name: "Creating Git repository…" })
    await expect(pending).toBeDisabled()
    await expect.poll(() => requests).toEqual([{ directory, provider: "git" }])
    if (view === "mobile") await page.screenshot({ path: test.info().outputPath("git-init-pending-mobile.png") })

    release.resolve()
    await expect(panel.getByRole("button", { name: "Git changes" })).toBeVisible()
    await expect(init).toHaveCount(0)
    if (view === "mobile") await expect(panel.locator('[data-slot="session-review-header"]')).toBeVisible()
    await expect(pending).toHaveCount(0)
    expect(requests).toHaveLength(1)
  })
}

test("keeps Git initialization available after a failed request", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await setup(page)
  let requests = 0
  await page.route("**/api/vcs/init**", (route) => {
    if (route.request().method() !== "POST") return route.fallback()
    requests++
    return route.fulfill({
      status: 503,
      contentType: "application/json",
      headers: { "access-control-allow-origin": "*" },
      body: JSON.stringify({ _tag: "ServiceUnavailableError", service: "git", message: "VCS initialization failed" }),
    })
  })
  const panel = await openReview(page, "desktop")
  await panel.getByRole("button", { name: "Create Git repository" }).click()
  await expect(page.getByText("Request failed", { exact: true })).toBeVisible()
  await expect(panel.getByRole("button", { name: "Create Git repository" })).toBeEnabled()
  await expect(panel.getByRole("button", { name: "Git changes" })).toHaveCount(0)
  expect(requests).toBe(1)
})

async function openReview(page: Page, view: "desktop" | "mobile") {
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  if (view === "desktop") {
    await expectSessionTitle(page, title)
    await page.locator("#session-side-panel-review-tab").click()
    return page.locator("#review-panel")
  }
  await page.getByRole("tab", { name: "Changes", exact: true }).click()
  return page.locator('[data-component="session-review"]')
}

async function setup(page: Page) {
  const project: { id: string; worktree: string; vcs?: string; name: string; time: object; sandboxes: string[] } = {
    id: projectID,
    worktree: directory,
    name: "review-without-git",
    time: { created: 1700000000000, updated: 1700000000000 },
    sandboxes: [],
  }
  await mockOpenCodeServer(page, {
    directory,
    project,
    provider: { all: [], connected: [], default: {} },
    sessions: [
      {
        id: sessionID,
        slug: sessionID,
        projectID,
        directory,
        title,
        version: "dev",
        time: { created: 1700000000000, updated: 1700000000000 },
      },
    ],
    vcsDiff: [],
    pageMessages: () => ({ items: [] }),
  })
  return project
}
