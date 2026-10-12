import { expect, test, type Page } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import type { SessionMessageInfo, ShellInfo } from "@opencode/client/promise"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const directory = "C:/OpenCode/RunningWork"
const projectID = "proj_running_work"
const parentID = "ses_running_parent"
const exploreID = "ses_running_explore"
const reviewID = "ses_running_review"
const shellID = "shl_running_server"
const href = (id: string) => `/server/${base64Encode(server)}/session/${id}`
const model = { id: "claude-opus-4-6", providerID: "opencode" }
const tokens = { input: 1, output: 1, reasoning: 0, cache: { read: 0, write: 0 } }

const session = (id: string, title: string, extra?: Record<string, unknown>) => ({
  id,
  slug: id,
  projectID,
  directory,
  title,
  version: "dev",
  time: { created: 1700000000000, updated: 1700000000000 },
  ...extra,
})

const shell: ShellInfo = {
  id: shellID,
  status: "running",
  command: "bun dev",
  cwd: directory,
  shell: "sh",
  file: "output.log",
  metadata: { sessionID: parentID },
  time: { started: 1700000000000 },
}

const exchange = (index: number): SessionMessageInfo[] => [
  {
    id: `msg_${1000 + index}_user`,
    type: "user",
    time: { created: 1700000000000 + index * 10 },
    text: `Step ${index}`,
  },
  {
    id: `msg_${1000 + index}_assistant`,
    type: "assistant",
    time: { created: 1700000000001 + index * 10, completed: 1700000000002 + index * 10 },
    model,
    agent: "build",
    cost: 0,
    tokens,
    finish: "stop",
    content: [{ type: "text", text: `Finished step ${index}.\n\n${"Detail line.\n\n".repeat(6)}` }],
  },
]

// The backgrounded shell call starts the history, far above the running turn at the end.
const parentMessages: SessionMessageInfo[] = [
  { id: "msg_0900_user", type: "user", time: { created: 1699999999000 }, text: "Start the dev server" },
  {
    id: "msg_0901_assistant",
    type: "assistant",
    time: { created: 1699999999001, completed: 1699999999002 },
    model,
    agent: "build",
    cost: 0,
    tokens,
    finish: "stop",
    content: [
      {
        type: "tool",
        id: "prt_running_shell",
        name: "shell",
        time: { created: 1699999999001, ran: 1699999999001, completed: 1699999999002 },
        state: {
          status: "completed",
          input: { command: shell.command },
          content: [{ type: "text", text: "Command moved to the background." }],
          metadata: { shellID, status: "running" },
        },
      },
    ],
  },
  ...Array.from({ length: 12 }, (_, index) => exchange(index)).flat(),
  { id: "msg_2000_user", type: "user", time: { created: 1700000001000 }, text: "Explore and review" },
  {
    id: "msg_2001_assistant",
    type: "assistant",
    time: { created: 1700000001001 },
    model,
    agent: "build",
    cost: 0,
    tokens,
    content: [
      {
        type: "tool",
        id: "prt_running_explore",
        name: "subagent",
        time: { created: 1700000001001, ran: 1700000001001 },
        state: {
          status: "running",
          input: { description: "Explore the code", agent: "explore", prompt: "Explore." },
          metadata: { sessionID: exploreID },
        },
      },
    ],
  },
]

async function setup(page: Page, start: string) {
  const stops: string[] = []
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "running-work",
      time: { created: 1, updated: 1 },
      sandboxes: [],
    },
    provider: {
      all: [
        {
          id: "opencode",
          name: "OpenCode",
          models: { [model.id]: { id: model.id, name: "Claude Opus 4.6", limit: { context: 200_000 } } },
        },
      ],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: model.id },
    },
    sessions: [
      session(parentID, "Running parent"),
      session(exploreID, "Explore the code", { parentID, agent: "explore" }),
      session(reviewID, "Review the change", { parentID, agent: "general" }),
    ],
    sessionStatus: { [parentID]: { type: "busy" }, [exploreID]: { type: "busy" }, [reviewID]: { type: "busy" } },
    pageMessages: (sessionID) => ({ items: sessionID === parentID ? parentMessages : [] }),
    tabLayout: "horizontal",
  })
  await page.route("**/api/shell?*", (route) =>
    route.fulfill({
      json: {
        location: { directory, project: { id: projectID, directory, canonical: directory } },
        data: new URL(route.request().url()).searchParams.get("location[directory]") === directory ? [shell] : [],
      },
    }),
  )
  await page.route(`**/api/shell/${shellID}?*`, (route) => {
    if (route.request().method() !== "DELETE") return route.fallback()
    stops.push(`shell ${new URL(route.request().url()).searchParams.get("location[directory]")}`)
    return route.fulfill({ status: 204, headers: { "access-control-allow-origin": "*" } })
  })
  page.on("request", (request) => {
    const path = new URL(request.url()).pathname
    if (request.method() === "POST" && path.endsWith("/interrupt")) stops.push(path)
  })
  await page.addInitScript(
    ({ server, parentID }) =>
      localStorage.setItem(
        "opencode.window.browser.dat:tabs",
        JSON.stringify([{ type: "session", server, sessionId: parentID }]),
      ),
    { server, parentID },
  )
  await page.goto(href(start))
  return stops
}

const runningMenu = (page: Page) => page.getByRole("menu", { name: /running$/ })

test.describe("desktop", () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test("lists running subagents and shells in the header, reveals, stops and navigates", async ({ page }) => {
    const stops = await setup(page, parentID)
    await expectSessionTitle(page, "Running parent")
    const header = page.locator("[data-session-title]")
    const trigger = header.getByRole("button", { name: "3 running", exact: true })
    await expect(trigger).toBeVisible()
    await trigger.click()
    const items = runningMenu(page).getByRole("menuitem")
    await expect(items).toHaveCount(3)
    await expect(items.nth(0)).toContainText("ExploreExplore the code")
    await expect(items.nth(1)).toContainText("GeneralReview the change")
    await expect(items.nth(2)).toContainText("Shellbun dev")

    // Reveal the backgrounded shell call far up the timeline.
    const call = page.locator('[data-timeline-part-id="prt_running_shell"]')
    await expect(call).not.toBeInViewport()
    await items.nth(2).click()
    await expect(runningMenu(page)).toHaveCount(0)
    await expect(call).toBeInViewport()

    // Stop the shell with its button, and the review subagent with the keyboard.
    await trigger.click()
    await items.nth(2).hover()
    await items.nth(2).getByRole("button", { name: "Kill shell command", exact: true }).click()
    await expect.poll(() => stops).toContain(`shell ${directory}`)
    await items.nth(1).focus()
    await page.keyboard.press("Delete")
    await expect.poll(() => stops).toContain(`/api/session/${reviewID}/interrupt`)

    await items.nth(0).click()
    await expect(page).toHaveURL(href(exploreID))
  })

  test("a subagent's header shows its own activity and the rest of its parent's work", async ({ page }) => {
    await setup(page, exploreID)
    const header = page.locator("[data-session-title]")
    const title = header.getByRole("heading", { name: "Explore the code", exact: true })
    await expect(title).toBeVisible()
    await expect(title.getByRole("status", { name: "Working", exact: true })).toBeVisible()
    await expect(title).toContainText("+2 running")
    await title.getByRole("button").click()
    const items = runningMenu(page).getByRole("menuitem")
    await expect(items).toHaveCount(3)
    await expect(items.nth(0)).toHaveAttribute("aria-current", "page")

    // The shell lives in the parent's timeline, which opens on the call.
    await items.nth(2).click()
    await expect(page).toHaveURL(href(parentID))
    await expect(page.locator('[data-timeline-part-id="prt_running_shell"]')).toBeInViewport()
  })
})

test.describe("phone", () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

  test("the session navigation lists running work and opens a subagent by touch", async ({ page }) => {
    await setup(page, parentID)
    await expectSessionTitle(page, "Running parent")
    const navigation = page.locator('[data-slot="session-mobile-view-navigation"]')
    const trigger = navigation.getByRole("button", { name: "3 running", exact: true })
    await expect(trigger).toBeVisible()
    await trigger.tap()
    const items = runningMenu(page).getByRole("menuitem")
    await expect(items).toHaveCount(3)
    await expect(items.nth(2).getByRole("button", { name: "Kill shell command", exact: true })).toBeVisible()
    // Without the timeline's header, the shell call is revealed through the session route.
    const call = page.locator('[data-timeline-part-id="prt_running_shell"]')
    await expect(call).not.toBeInViewport()
    await items.nth(2).tap()
    await expect(call).toBeInViewport()
    await trigger.tap()
    await items.nth(1).tap()
    await expect(page).toHaveURL(href(reviewID))
    await expectSessionTitle(page, "Review the change")
    // Inside the subagent, only its siblings and the shell are counted.
    await expect(
      page
        .locator('[data-slot="session-mobile-view-navigation"]')
        .getByRole("button", { name: "2 running", exact: true }),
    ).toBeVisible()
  })
})
