import { expect, test, type Page } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"

const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const directory = "/repo/submit-touch-hover"
const sessionID = "ses_submit_touch_hover_123456"

async function openBusySession(page: Page) {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "proj_submit_touch_hover",
      worktree: directory,
      vcs: "git",
      name: "submit-touch-hover",
      time: { created: 1, updated: 1 },
      sandboxes: [],
    },
    provider: { all: [], connected: [], default: {} },
    sessions: [
      {
        id: sessionID,
        projectID: "proj_submit_touch_hover",
        directory,
        title: "Submit touch hover",
        time: { created: 1, updated: 1 },
      },
    ],
    pageMessages: () => ({ items: [] }),
    sessionStatus: { [sessionID]: { type: "busy" } },
    subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
  })
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  const stop = page.getByRole("button", { name: "Stop", exact: true })
  await expect(stop).toHaveAttribute("data-variant", "submit")
  return stop
}

// The hover overlay is the extra gradient layer on top of the highlight and the contrast fill.
const layers = (stop: Awaited<ReturnType<typeof openBusySession>>) =>
  stop.evaluate((element) => getComputedStyle(element).backgroundImage.match(/linear-gradient/g)?.length)

test("a tapped submit button does not keep its hover overlay", async ({ browser }) => {
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    hasTouch: true,
    isMobile: true,
    serviceWorkers: "block",
  })
  const page = await context.newPage()
  const interrupts: string[] = []
  page.on("request", (request) => {
    if (request.method() === "POST" && request.url().includes(`/session/${sessionID}/interrupt`))
      interrupts.push(request.url())
  })
  try {
    const stop = await openBusySession(page)
    expect(await page.evaluate(() => matchMedia("(hover: none)").matches)).toBe(true)
    await stop.tap()
    await expect.poll(() => interrupts.length).toBe(1)
    await expect(stop).toBeVisible()
    expect(await stop.evaluate((element) => element.matches(":hover"))).toBe(true)
    await expect.poll(() => layers(stop)).toBe(2)
  } finally {
    await context.close()
  }
})

test("a hovered submit button shows its hover overlay with a pointer", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  const stop = await openBusySession(page)
  expect(await page.evaluate(() => matchMedia("(hover: hover)").matches)).toBe(true)
  await expect.poll(() => layers(stop)).toBe(2)
  await stop.hover()
  await expect.poll(() => layers(stop)).toBe(3)
})
