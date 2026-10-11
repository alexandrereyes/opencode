import { base64Encode } from "@opencode/util/encode"
import { expect, test, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const directory = "C:/OpenCode/ReviewLastTurn"
const projectID = "proj_review_last_turn"
const sessionID = "ses_review_last_turn"
const title = "Last turn review"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test.use({ viewport: { width: 1440, height: 900 } })

test("shows and restores last turn changes from the session diff", async ({ page }) => {
  const requests = await setup(page, { vcs: "git" })
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  await expectSessionTitle(page, title)
  await page.locator("#session-side-panel-review-tab").click()
  const panel = page.locator("#review-panel")
  await expect(panel.locator('[data-slot="session-review-v2-file-name"]')).toHaveText("alpha.ts")
  expect(requests.turn).toEqual([])

  await panel.getByRole("button", { name: "Git changes" }).click()
  await page.getByRole("option", { name: "Last turn changes" }).click()
  await expect(panel.getByRole("button", { name: "Last turn changes" })).toBeVisible()
  await expect(panel.locator('[data-slot="session-review-v2-file-name"]')).toHaveText("delta.ts")
  // The full-context patch was oversized (empty), so the panel loads the bounded-context turn diff instead.
  await expect(panel.getByText("export const turn = 'after'", { exact: true })).toBeVisible()
  expect(requests.turn).toContain(null)
  expect(requests.turn).toContain("3")

  await page.reload()
  await expectSessionTitle(page, title)
  await page.locator("#session-side-panel-review-tab").click()
  await expect(panel.getByRole("button", { name: "Last turn changes" })).toBeVisible()
  await expect(panel.locator('[data-slot="session-review-v2-file-name"]')).toHaveText("delta.ts")
})

test("offers last turn changes only for Git projects", async ({ page }) => {
  await setup(page, { vcs: "hg" })
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  await expectSessionTitle(page, title)
  await page.locator("#session-side-panel-review-tab").click()
  const panel = page.locator("#review-panel")
  await panel.getByRole("button", { name: "Git changes" }).click()
  await expect(page.getByRole("option", { name: "Git changes" })).toBeVisible()
  await expect(page.getByRole("option", { name: "Last turn changes" })).toHaveCount(0)
})

test("shows last turn changes on mobile", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await setup(page, { vcs: "git" })
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  await page.getByRole("tab", { name: "Changes", exact: true }).click()
  const review = page.locator('[data-component="session-review"]')
  await expect(review.getByRole("button", { name: "alpha.ts" })).toBeVisible()
  await review.getByRole("button", { name: "Git changes" }).click()
  await page.getByRole("option", { name: "Last turn changes" }).click()
  await expect(review.getByRole("button", { name: "Last turn changes" })).toBeVisible()
  await expect(review.getByRole("button", { name: "delta.ts" })).toBeVisible()
  await expect(review.getByRole("button", { name: "alpha.ts" })).toHaveCount(0)
  await page.screenshot({ path: test.info().outputPath("last-turn-mobile.png") })
})

async function setup(page: Page, input: { vcs: string }) {
  const requests = { turn: [] as (string | null)[] }
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: input.vcs,
      name: "review-last-turn",
      time: { created: 1700000000000, updated: 1700000000000 },
      sandboxes: [],
    },
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
    vcsDiff: [diff("src/alpha.ts", "value")],
    pageMessages: () => ({ items: [] }),
  })
  await page.route(`**/api/session/${sessionID}/diff**`, (route) => {
    const context = new URL(route.request().url()).searchParams.get("context")
    requests.turn.push(context)
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "access-control-allow-origin": "*" },
      // Without bounded context the patch is too large to return, as the server does for oversized files.
      body: JSON.stringify({
        data: context === "3" ? [diff("src/delta.ts", "turn")] : [{ ...diff("src/delta.ts"), patch: "" }],
      }),
    })
  })
  return requests
}

function diff(file: string, name = "turn") {
  return {
    file,
    additions: 1,
    deletions: 1,
    status: "modified",
    patch: `diff --git a/${file} b/${file}\n--- a/${file}\n+++ b/${file}\n@@ -1 +1 @@\n-export const ${name} = 'before'\n+export const ${name} = 'after'\n`,
  }
}
