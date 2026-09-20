import { expect, test } from "@playwright/test"
import type { OpenCodeEvent } from "@opencode/client/promise"
import { base64Encode } from "@opencode/util/encode"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs } from "../performance/timeline/timeline-test-helpers"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionReady } from "../utils/waits"

test.use({ serviceWorkers: "block", viewport: { width: 1280, height: 900 } })

test("refreshes the session workspace menu on open and matching worktree events", async ({ page }) => {
  const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
  const worktrees = [
    { directory: fixture.directory },
    { directory: "C:/OpenCode/Worktrees/initial-worktree", strategy: "git" },
  ]
  const events: OpenCodeEvent[] = []
  const requests: string[] = []
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    sessions: fixture.sessions,
    provider: fixture.provider,
    pageMessages: () => ({ items: fixture.messages[fixture.targetID].slice(0, 2) }),
    events: () => events.splice(0),
  })
  await page.route(
    (url) => url.pathname === "/api/worktree" || url.pathname === "/api/worktree/refresh",
    (route) => {
      const path = new URL(route.request().url()).pathname
      if (path === "/api/worktree" && route.request().method() === "GET") {
        requests.push("list")
        return route.fulfill({ json: worktrees, headers: { "access-control-allow-origin": "*" } })
      }
      if (path === "/api/worktree/refresh" && route.request().method() === "POST") {
        requests.push("refresh")
        return route.fulfill({ status: 204, headers: { "access-control-allow-origin": "*" } })
      }
      return route.fallback()
    },
  )
  await installStressSessionTabs(page)
  await page.goto(`/server/${base64Encode(server)}/session/${fixture.targetID}`)
  await expectSessionReady(page, { server, sessionID: fixture.targetID, title: fixture.expected.targetTitle })

  requests.length = 0
  await page.getByRole("button", { name: "Session details", exact: true }).click()
  const summary = page.locator('[data-component="session-summary-panel"]')
  await expect(summary).toBeVisible()
  await summary.getByRole("button").filter({ hasText: "Local" }).click()
  await expect.poll(() => requests).toEqual(["list", "refresh"])
  await page.getByRole("menuitem", { name: "Worktree", exact: true }).hover()
  await expect(page.getByRole("menuitem", { name: "initial-worktree", exact: true })).toBeVisible()

  requests.length = 0
  worktrees.push({ directory: "C:/OpenCode/Worktrees/discovered-worktree", strategy: "git" })
  const otherProcessed = page.waitForResponse(
    (response) => new URL(response.url()).pathname === "/api/project" && response.request().method() === "GET",
  )
  events.push({
    id: "evt_other_worktree_updated",
    type: "worktree.updated",
    created: 1700000002000,
    data: { projectID: "proj_other" },
  })
  expect((await otherProcessed).ok()).toBe(true)
  expect(requests).toEqual([])
  await expect(page.getByRole("menuitem", { name: "discovered-worktree", exact: true })).toHaveCount(0)

  events.push({
    id: "evt_matching_worktree_updated",
    type: "worktree.updated",
    created: 1700000003000,
    data: { projectID: fixture.project.id },
  })

  await expect(page.getByRole("menuitem", { name: "discovered-worktree", exact: true })).toBeVisible()
  expect(requests).toContain("list")
})
