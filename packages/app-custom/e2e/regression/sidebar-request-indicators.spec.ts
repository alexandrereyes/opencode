import { expect, test, type Locator, type Page } from "@playwright/test"
import type { SessionInfo } from "@opencode/client/promise"
import { mockOpenCodeServer } from "../utils/mock-server"
import type { SessionNavigationInfo } from "../../src/shell/titlebar/sidebar-model"

const directory = "/workspace/requests"

async function setup(page: Page) {
  const now = Date.now()
  const session = (id: string, title: string, offset: number): SessionInfo => ({
    id,
    projectID: "requests-project",
    title,
    location: { directory },
    agent: "build",
    model: { id: "test", providerID: "opencode" },
    time: { created: now - offset, updated: now - offset },
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  })
  const sessions = [
    session("ses_question", "Question waiting", 1000),
    session("ses_permission", "Permission waiting", 2000),
    session("ses_busy", "Busy session", 3000),
    session("ses_quiet", "Quiet session", 4000),
  ]
  const rows: SessionNavigationInfo[] = [
    { session: sessions[0], messageAt: now - 1000, questionAt: now - 1000, questionCount: 2 },
    {
      session: sessions[1],
      messageAt: now - 2000,
      permissionAt: now - 2000,
      permissionCount: 1,
      questionAt: now - 2000,
      questionCount: 1,
    },
    { session: sessions[2], messageAt: now - 3000 },
    { session: sessions[3], messageAt: now - 4000 },
  ]
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "requests-project",
      worktree: directory,
      name: "Requests project",
      vcs: "git",
      time: { created: now, updated: now },
      sandboxes: [],
    },
    sessions,
    // A pending question keeps the session execution running; the request must still win.
    sessionStatus: { ses_question: { type: "running" }, ses_busy: { type: "running" } },
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
  await page.addInitScript((directory) => {
    localStorage.setItem("settings.v3", JSON.stringify({ appearance: { tabLayout: "vertical" } }))
    localStorage.setItem("opencode.global.dat:language", JSON.stringify({ locale: "en" }))
    localStorage.setItem(
      "opencode.global.dat:server",
      JSON.stringify({ projects: { local: [{ worktree: directory, expanded: true }] } }),
    )
  }, directory)
}

function row(section: Locator, title: string) {
  return section
    .locator("[data-titlebar-tab]")
    .filter({ has: section.page().locator('[data-slot="tab-title"]', { hasText: title }) })
}

async function expectIndicators(section: Locator) {
  const question = row(section, "Question waiting")
  await expect(question).toHaveAttribute("data-activity", "question")
  await expect(question.getByRole("img", { name: "Question pending", exact: true })).toBeVisible()
  await expect(question.getByRole("img", { name: "2 questions pending", exact: true })).toHaveText("2")
  await expect(question.getByRole("img", { name: "Running", exact: true })).toHaveCount(0)

  const permission = row(section, "Permission waiting")
  await expect(permission).toHaveAttribute("data-activity", "permission")
  await expect(permission.getByRole("img", { name: "Permission required", exact: true })).toBeVisible()
  await expect(permission.getByRole("img", { name: "1 permission request pending", exact: true })).toHaveText("1")
  await expect(permission.getByRole("img", { name: "1 question pending", exact: true })).toHaveText("1")

  const busy = row(section, "Busy session")
  await expect(busy).toHaveAttribute("data-activity", "running")
  await expect(busy.getByRole("img", { name: "Running", exact: true })).toBeVisible()
  await expect(busy.locator('[data-slot="tab-requests"]')).toHaveCount(0)

  await expect(row(section, "Quiet session")).not.toHaveAttribute("data-activity", /./)
}

test("sidebar rows and collapsed projects show pending requests ahead of running activity", async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 })
  await setup(page)
  await page.goto("/")
  const sidebar = page.locator('[data-slot="vertical-tabs-sidebar"]')
  const section = (name: string) =>
    sidebar.locator("section").filter({ has: page.getByRole("heading", { name, exact: true }) })
  const toggle = page.getByRole("button", { name: "Attention view", exact: true })

  await expect(toggle).toHaveAttribute("aria-pressed", "true")
  await expectIndicators(sidebar)
  await expect(row(section("Priority"), "Question waiting").locator('[data-slot="tab-project"]')).toBeVisible()
  await expect(row(section("Priority"), "Permission waiting")).toHaveCount(1)
  await expect(row(section("Priority"), "Busy session")).toHaveCount(0)
  await sidebar.screenshot({ path: test.info().outputPath("attention.png") })

  await toggle.click()
  await expect(toggle).toHaveAttribute("aria-pressed", "false")
  await expectIndicators(section("Recent"))
  const project = sidebar.locator("[data-project-key]").filter({ hasText: "Requests project" })
  await expectIndicators(project)
  await sidebar.screenshot({ path: test.info().outputPath("projects.png") })
  await project.getByRole("button", { name: "Requests project" }).click()
  await expect(row(project, "Question waiting")).toHaveCount(0)
  await expect(project.getByRole("img", { name: "Permission required", exact: true })).toBeVisible()
  await expect(project.getByRole("img", { name: "Running", exact: true })).toHaveCount(0)
})
