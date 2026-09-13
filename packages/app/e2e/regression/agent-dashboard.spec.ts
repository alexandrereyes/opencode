import { expect, test, type Page } from "@playwright/test"
import type { SessionInfo } from "@opencode/client/promise"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"
import type { SessionNavigationInfo } from "../../src/shell/titlebar/sidebar-model"

const directory = "/workspace/dashboard"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

async function setup(page: Page) {
  const now = Date.now()
  const sessions: SessionInfo[] = Array.from({ length: 24 }, (_, index) => ({
    id: `ses_dashboard_${index}`,
    projectID: "dashboard-project",
    title: `Dashboard session ${String(index).padStart(2, "0")}`,
    location: { directory },
    agent: "build",
    model: { id: "test", providerID: "opencode" },
    outcome: "succeeded",
    time: { created: now - index * 1000, updated: now, idle: now },
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  }))
  const rows: SessionNavigationInfo[] = sessions.map((session, index) => ({
    session,
    messageAt: now,
    questionAt: index === 0 ? now : undefined,
  }))
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "dashboard-project",
      worktree: directory,
      name: "Dashboard project",
      vcs: "git",
      time: { created: now, updated: now },
      sandboxes: [],
    },
    sessions,
    provider: {
      all: [
        {
          id: "opencode",
          name: "OpenCode",
          models: { test: { id: "test", name: "Test", limit: { context: 200_000 } } },
        },
      ],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: "test" },
    },
    pageMessages: (id) => ({
      items: [
        {
          id: `msg_${id}`,
          type: "assistant",
          agent: "build",
          model: { id: "test", providerID: "opencode" },
          time: { created: now },
          content: [
            { type: "reasoning", text: "Reasoning must never appear on a card" },
            { type: "text", text: `Preview for ${id}` },
          ],
        },
      ],
    }),
  })
  await page.route("**/api/rpc/custom.navigation/list*", async (route) => {
    const body: unknown = route.request().postDataJSON()
    const id =
      typeof body === "object" &&
      body !== null &&
      "input" in body &&
      typeof body.input === "object" &&
      body.input !== null &&
      "sessionID" in body.input &&
      typeof body.input.sessionID === "string"
        ? body.input.sessionID
        : undefined
    await route.fulfill({
      json: { output: { data: id ? rows.filter((row) => row.session.id === id) : rows } },
    })
  })
  await page.addInitScript(() => {
    localStorage.setItem("settings.v3", JSON.stringify({ appearance: { tabLayout: "vertical" } }))
    localStorage.setItem("opencode.global.dat:language", JSON.stringify({ locale: "en" }))
  })
}

test("desktop dashboard filters, opens the normal session and restores density and scroll", async ({ page }) => {
  await page.setViewportSize({ width: 1600, height: 900 })
  await setup(page)
  await page.goto("/")
  await page.getByRole("button", { name: "Agent dashboard", exact: true }).click()
  await expect(page.getByRole("heading", { name: "Agent dashboard", exact: true })).toBeVisible()
  const cards = page.getByRole("link", { name: /^Open session: Dashboard session/ })
  await expect(cards).toHaveCount(24)
  await expect(page.getByRole("link", { name: "Open session: Dashboard session 00", exact: true })).toContainText(
    "Preview for ses_dashboard_0",
  )
  await expect(page.getByText("Reasoning must never appear on a card", { exact: true })).toHaveCount(0)
  await page.getByRole("combobox", { name: "Session status", exact: true }).selectOption("attention")
  await expect(cards).toHaveCount(1)
  await expect(cards).toContainText("Needs you")
  await page.getByRole("combobox", { name: "Session status", exact: true }).selectOption("all")
  await page.getByRole("combobox", { name: "Card density", exact: true }).selectOption("comfortable")
  await expect(cards).toHaveCount(24)
  const search = page.getByRole("searchbox", { name: "Search title, project or directory", exact: true })
  await search.fill("session 23")
  await expect(cards).toHaveCount(1)
  await expect(cards).toContainText("Dashboard session 23")
  await search.clear()
  await expect(cards).toHaveCount(24)
  const target = page.getByRole("link", { name: "Open session: Dashboard session 23", exact: true })
  await target.scrollIntoViewIfNeeded()
  await expect(target).toContainText("Preview for ses_dashboard_23")
  const viewport = page.locator('[data-slot="dashboard-scroll"]')
  const scroll = await viewport.evaluate((element) => element.scrollTop)
  expect(scroll).toBeGreaterThan(0)
  await target.click()
  await expect(page).toHaveURL(`/server/${base64Encode(server)}/session/ses_dashboard_23`)
  await expectSessionTitle(page, "Dashboard session 23")
  await page.goBack()
  await expect(cards).toHaveCount(24)
  await expect(page.getByRole("combobox", { name: "Card density", exact: true })).toHaveValue("comfortable")
  await expect(page.getByRole("combobox", { name: "Session status", exact: true })).toHaveValue("all")
  await expect.poll(() => viewport.evaluate((element) => element.scrollTop)).toBe(scroll)
})

test("narrow RTL fallback has no horizontal overflow or desktop navigation entry", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await setup(page)
  await page.goto("/agent-dashboard")
  await expect(page.getByRole("link", { name: "Open session: Dashboard session 00", exact: true })).toContainText(
    "Preview for ses_dashboard_0",
  )
  await page.evaluate(() => {
    document.documentElement.dir = "rtl"
  })
  await expect(page.getByRole("button", { name: "Agent dashboard", exact: true })).toHaveCount(0)
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  await expect
    .poll(() =>
      page.locator('[data-slot="dashboard-scroll"]').evaluate((element) => element.scrollWidth <= element.clientWidth),
    )
    .toBe(true)
  await page.getByRole("searchbox", { name: "Search title, project or directory", exact: true }).fill("missing")
  await expect(page.getByRole("heading", { name: "No sessions match this view", exact: true })).toBeVisible()
  await page.getByRole("button", { name: "Show all sessions", exact: true }).click()
  await expect(page.getByRole("link", { name: /^Open session: Dashboard session/ })).toHaveCount(24)
})
