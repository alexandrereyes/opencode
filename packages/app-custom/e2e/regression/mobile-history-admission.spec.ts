import { devices, expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { fixture } from "../smoke/session-timeline.fixture"
import { mockOpenCodeServer } from "../utils/mock-server"

// TanStack Virtual defers prepend anchoring on iOS WebKit while a gesture or its
// momentum is active. An older page admitted then moves the rows under a still
// finger and snaps back after release. The iPhone user agent selects that path.
test.use({
  colorScheme: "light",
  isMobile: true,
  hasTouch: true,
  userAgent: devices["iPhone 13"].userAgent,
  viewport: { width: 390, height: 844 },
  launchOptions: { args: ["--disable-features=ResamplingScrollEvents"] },
})

test("iOS history page waits for the touch to settle before it anchors", async ({ page }) => {
  const messages = fixture.messages[fixture.targetID]
  const initial = messages.slice(-40)
  const older = messages.slice(-80, -40)
  const release = Promise.withResolvers<void>()
  const requested = Promise.withResolvers<void>()
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    provider: fixture.provider,
    sessions: fixture.sessions.filter((session) => session.id === fixture.targetID),
    pageMessages: (_sessionID, _limit, before) => {
      if (!before) return { items: initial, cursor: initial[0].id }
      if (before === initial[0].id) return { items: older, cursor: older[0].id }
      return { items: [] }
    },
    onMessages: ({ before, phase }) => {
      if (before === initial[0].id && phase === "start") requested.resolve()
    },
    beforeMessagesResponse: ({ before }) => (before === initial[0].id ? release.promise : Promise.resolve()),
  })
  // Location-history queries are independent of transcript pagination.
  await page.route(
    (url) => url.pathname.endsWith("/message") && url.searchParams.has("type"),
    (route) => route.fulfill({ json: { data: [], cursor: {} } }),
  )

  try {
    await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${fixture.targetID}`)
    await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeEditable()
    const timeline = page.locator('[data-slot="session-timeline-scroll"]')
    const scroller = timeline.getByRole("region", { name: "scrollable content", exact: true })
    await expect(timeline.locator("[data-timeline-virtual-content]")).toBeVisible()
    await page.evaluate(() => document.fonts.ready)
    await expect(timeline.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(0)
    // The initial scroll-to-end reconciles until the tail measurements settle.
    await expect
      .poll(() => scroller.evaluate((element) => element.scrollHeight - element.clientHeight - element.scrollTop))
      .toBeLessThan(2)
    await expect(timeline.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)

    await scroller.evaluate((element) => {
      element.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: -1 }))
      element.scrollTop = 0
    })
    await requested.promise
    await expect(scroller.locator(`[data-timeline-part-id="${initial[0].id}:text:0"]`)).toBeInViewport()
    await expect(timeline.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(0)
    // Leave room above the reader for a held drag toward older history.
    await scroller.evaluate((element) => {
      element.scrollTop = 180
    })
    const anchor = scroller.locator(`[data-timeline-part-id="${initial[1].id}:text:0"]`)
    await expect(anchor).toBeInViewport()
    await expect.poll(() => scroller.evaluate((element) => element.scrollTop)).toBe(180)
    await expect(timeline.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)
    const top = () => anchor.evaluate((element) => element.getBoundingClientRect().top)
    const before = await top()
    const scrollTop = 180

    const bounds = (await scroller.boundingBox())!
    const x = bounds.x + bounds.width / 3
    const y = bounds.y + bounds.height / 2
    const devtools = await page.context().newCDPSession(page)
    await devtools.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] })
    const drag = async (step: number) => {
      await devtools.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y: y + step * 20 }] })
      // Chromium consumes its 15px touch slop before the first scroll.
      await expect.poll(top).toBeCloseTo(before + step * 20 - 15, 0)
    }
    for (const step of [1, 2, 3]) await drag(step)

    const response = page.waitForResponse((response) => {
      const url = new URL(response.url())
      return url.pathname.endsWith("/message") && url.searchParams.has("cursor") && !url.searchParams.has("type")
    })
    release.resolve()
    await (await response).finished()
    // While the finger stays down, the page must neither move the rows nor enter the timeline.
    for (const step of [4, 5, 6]) await drag(step)
    await expect(scroller.locator(`[data-timeline-key*="${older.at(-1)!.id}"]`)).toHaveCount(0)
    await expect.poll(() => scroller.evaluate((element) => element.scrollTop)).toBe(scrollTop - 105)

    const held = await top()
    await devtools.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] })
    // Admission anchors the reader with one immediate write, so the older page
    // lands above the viewport without moving the visible message.
    await expect.poll(() => scroller.evaluate((element) => element.scrollTop)).toBeGreaterThan(scrollTop - 105 + 1000)
    await expect.poll(top).toBeCloseTo(held, 0)
    await expect(scroller.locator(`[data-timeline-key*="${older.at(-1)!.id}"]`)).toBeAttached()
  } finally {
    release.resolve()
  }
})
