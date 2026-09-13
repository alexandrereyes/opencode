import { expect, test, type Locator, type Page } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { fixture } from "../smoke/session-timeline.fixture"
import { mockOpenCodeServer } from "../utils/mock-server"

const now = 1_800_000_000_000
const href = (id: string) => `/server/${base64Encode(fixture.serverKey)}/session/${id}`
const drawer = (page: Page) => page.locator('[data-slot="mobile-tabs-drawer"]')
const row = (page: Page, title: string) =>
  drawer(page).locator('[data-slot="mobile-tab-swipe"]').filter({ hasText: title })

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

test.beforeEach(async ({ page }) => {
  await page.clock.setFixedTime(now)
  const sessions = [
    ...fixture.sessions.map((session, index) => ({
      ...session,
      time: { created: now - 10 * 86_400_000, updated: now - (index === 0 ? 3 * 3_600_000 : 2 * 86_400_000) },
    })),
    ...Array.from({ length: 16 }, (_, index) => ({
      ...fixture.sessions[1],
      id: `ses_mobile_extra_${index}`,
      title: `Older session ${index}`,
      time: { created: now - 10 * 86_400_000, updated: now - (index + 3) * 86_400_000 },
    })),
  ]
  await mockOpenCodeServer(page, {
    sessions,
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages: () => ({ items: [] }),
  })
  await page.addInitScript(
    ({ server, sessions }) => {
      localStorage.setItem(
        "opencode.window.browser.dat:tabs",
        JSON.stringify(sessions.map((session) => ({ type: "session", server, sessionId: session.id }))),
      )
    },
    { server: fixture.serverKey, sessions },
  )
  await page.goto(href(fixture.sourceID))
  await page.getByRole("button", { name: "Tabs", exact: true }).tap()
  await expect(page.getByRole("dialog", { name: "Tabs", exact: true })).not.toHaveAttribute("data-transitioning")
  await expect(row(page, fixture.expected.targetTitle).locator("time")).toHaveText("2d ago")
})

// Use trusted touch input: dispatchEvent alone cannot exercise native panning,
// pointer cancellation or the compatibility mouse events emitted by Chromium.
async function swipe(page: Page, target: Locator, dx: number, dy = 0, cancel = false) {
  await target.click({ trial: true })
  const bounds = await target.boundingBox()
  if (!bounds) throw new Error("Swipe target has no bounds")
  const cdp = await page.context().newCDPSession(page)
  const x = bounds.x + bounds.width / 2
  const y = bounds.y + bounds.height / 2
  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] })
  for (const fraction of [0.2, 0.5, 0.8, 1]) {
    await cdp.send("Input.dispatchTouchEvent", {
      type: "touchMove",
      touchPoints: [{ x: x + dx * fraction, y: y + dy * fraction }],
    })
  }
  await cdp.send("Input.dispatchTouchEvent", { type: cancel ? "touchCancel" : "touchEnd", touchPoints: [] })
  await cdp.detach()
}

for (const direction of ["ltr", "rtl"] as const) {
  test(`swipe at the logical end preserves selection, focus and hidden controls (${direction})`, async ({ page }) => {
    await page.getByRole("dialog", { name: "Tabs", exact: true }).evaluate((element, direction) => {
      element.setAttribute("dir", direction)
    }, direction)
    const source = row(page, fixture.expected.sourceTitle)
    const target = row(page, fixture.expected.targetTitle)
    const link = target.locator("[data-titlebar-tab-link]")
    const delta = direction === "rtl" ? 110 : -110
    await expect(source.locator("time")).toHaveText("3h ago")
    await expect(target.getByRole("button", { name: "Archive", exact: true })).toHaveCount(0)
    await expect(target.locator('[data-slot="mobile-tab-actions"]')).toHaveAttribute("inert")
    await expect(target.locator('[data-slot="mobile-tab-actions"] button')).toHaveCount(2)
    await expect(target.locator('[data-slot="mobile-tab-actions"] button[tabindex="0"]')).toHaveCount(0)
    await expect(target.getByRole("button", { name: "More options", exact: true })).toBeVisible()
    await expect(target.getByRole("button", { name: "Close tab", exact: true })).toBeVisible()
    await swipe(page, link, delta)
    await expect(target).toHaveAttribute("data-revealed", "true")
    const actions = target.locator('[data-slot="mobile-tab-actions"]')
    await expect(actions.getByRole("button")).toHaveCount(2)
    await expect(actions.getByRole("button", { name: "Archive", exact: true })).toHaveCSS("width", "44px")
    await expect(actions.getByRole("button", { name: "Delete", exact: true })).toHaveCSS("width", "44px")
    await expect(target.locator('[data-slot="mobile-tab-content"]')).toHaveCSS(
      "transform",
      `matrix(1, 0, 0, 1, ${direction === "rtl" ? 88 : -88}, 0)`,
    )
    // Deliberately follow the swipe with compatibility events on the link.
    await link.dispatchEvent("mousedown", { button: 0, detail: 1 })
    await link.dispatchEvent("click", { button: 0, detail: 1 })
    await expect(page).toHaveURL(href(fixture.sourceID))
    await link.tap()
    await expect(target).toHaveAttribute("data-revealed", "false")
    await expect(link).toBeFocused()
    await expect(page).toHaveURL(href(fixture.sourceID))
    await swipe(page, link, delta)
    await swipe(page, source.locator("[data-titlebar-tab-link]"), delta)
    await expect(source).toHaveAttribute("data-revealed", "true")
    await expect(target).toHaveAttribute("data-revealed", "false")
    await source.getByRole("button", { name: "Archive", exact: true }).focus()
    await page.keyboard.press("Escape")
    await expect(source).toHaveAttribute("data-revealed", "false")
    await expect(source.locator("[data-titlebar-tab-link]")).toBeFocused()
    await swipe(page, link, delta)
    await drawer(page).getByRole("button", { name: "Home", exact: true }).tap()
    await page.getByRole("button", { name: "Tabs", exact: true }).tap()
    await expect(target).toHaveAttribute("data-revealed", "false")
    await link.tap()
    await expect(page).toHaveURL(href(fixture.targetID))
    await expect(drawer(page)).toBeHidden()
  })
}

test("short, vertical and cancelled gestures cannot navigate", async ({ page }) => {
  const target = row(page, fixture.expected.targetTitle)
  const link = target.locator("[data-titlebar-tab-link]")
  for (const gesture of [{ dx: -20 }, { dx: 0, dy: -65 }, { dx: -110, cancel: true }]) {
    await swipe(page, link, gesture.dx, gesture.dy, gesture.cancel)
    await expect(target).toHaveAttribute("data-revealed", "false")
    await link.dispatchEvent("mousedown", { button: 0, detail: 1 })
    await link.dispatchEvent("click", { button: 0, detail: 1 })
    await expect(page).toHaveURL(href(fixture.sourceID))
    await expect(drawer(page)).toBeVisible()
  }
  await link.tap()
  await expect(page).toHaveURL(href(fixture.targetID))
})

for (const cancelled of [false, true]) {
  for (const action of ["Close tab", "More options"] as const) {
    test(`${action} remains usable after ${cancelled ? "a cancelled gesture" : "a revealed swipe"}`, async ({
      page,
    }) => {
      const target = row(page, fixture.expected.targetTitle)
      const link = target.locator("[data-titlebar-tab-link]")
      const button = target.getByRole("button", { name: action, exact: true })
      await swipe(page, link, -110, 0, cancelled)
      await expect(target).toHaveAttribute("data-revealed", String(!cancelled))
      await link.dispatchEvent("mousedown", { button: 0, detail: 1 })
      await link.dispatchEvent("click", { button: 0, detail: 1 })
      await expect(page).toHaveURL(href(fixture.sourceID))

      await button.tap()
      if (action === "Close tab") {
        await expect(target).toHaveCount(0)
        await expect(page).toHaveURL(href(fixture.sourceID))
        await drawer(page).getByRole("button", { name: "Home", exact: true }).tap()
        await page.getByRole("button", { name: "Tabs", exact: true }).tap()
        await expect(drawer(page).getByRole("button", { name: "Home", exact: true })).toBeVisible()
        await expect(target).toHaveCount(0)
        return
      }

      await expect(page.getByRole("menuitem", { name: "Rename", exact: true })).toBeVisible()
      await page.getByRole("menuitem", { name: "Rename", exact: true }).tap()
      const title = target.locator('[data-titlebar-tab-title][contenteditable="true"]')
      await expect(title).toBeFocused()
      await expect(title).toHaveText(fixture.expected.targetTitle)
      await expect(page).toHaveURL(href(fixture.sourceID))
      await title.press("Escape")
      await expect(target.locator('[contenteditable="true"]')).toHaveCount(0)
      await expect(page).toHaveURL(href(fixture.sourceID))
    })
  }
}

test("vertical touch scroll stays inside the session list and does not dismiss the drawer", async ({ page }) => {
  const list = drawer(page).locator('[data-slot="vertical-tabs-scroll"]')
  await swipe(page, row(page, fixture.expected.targetTitle).locator("[data-titlebar-tab-link]"), 0, -130)
  await expect.poll(() => list.evaluate((element) => element.scrollTop)).toBeGreaterThan(0)
  await expect(page.getByRole("button", { name: "Tabs", exact: true })).toHaveAttribute("aria-expanded", "true")
  await expect(page).toHaveURL(href(fixture.sourceID))
  await expect(drawer(page).locator('[data-slot="mobile-tab-swipe"][data-revealed="true"]')).toHaveCount(0)
})

test("relative time refreshes when the drawer reopens", async ({ page }) => {
  await expect(row(page, fixture.expected.sourceTitle).locator("time")).toHaveText("3h ago")
  await row(page, fixture.expected.sourceTitle).locator("[data-titlebar-tab-link]").click({ trial: true })
  await page.keyboard.press("Escape")
  await expect(drawer(page)).toBeHidden()
  await page.clock.setFixedTime(now + 3_600_000)
  await page.getByRole("button", { name: "Tabs", exact: true }).tap()
  await expect(row(page, fixture.expected.sourceTitle).locator("time")).toHaveText("4h ago")
})

test("archive keeps focus while pending and can retry a failure", async ({ page }) => {
  const target = row(page, fixture.expected.targetTitle)
  const release = Promise.withResolvers<void>()
  const mutations: string[] = []
  await page.route("**/api/rpc/custom.archive/archive", async (route) => {
    expect(route.request().postDataJSON()).toEqual({ input: { sessionID: fixture.targetID } })
    mutations.push(route.request().method())
    if (mutations.length === 1) {
      await release.promise
      await route.fulfill({
        status: 400,
        json: {
          _tag: "RpcError",
          type: "operation_failed",
          message: "Archive failed",
          data: { message: "Archive failed" },
        },
        headers: { "access-control-allow-origin": "*" },
      })
      return
    }
    await route.fulfill({ json: { output: {} }, headers: { "access-control-allow-origin": "*" } })
  })
  await swipe(page, target.locator("[data-titlebar-tab-link]"), -110)
  const archive = target.getByRole("button", { name: "Archive", exact: true })
  await archive.focus()
  await archive.press("Enter")
  await expect(archive).toHaveAttribute("aria-disabled", "true")
  await expect(archive).toBeFocused()
  await archive.press("Enter")
  expect(mutations).toEqual(["POST"])
  release.resolve()
  await expect(archive).toHaveAttribute("aria-disabled", "false")
  await expect(archive).toBeFocused()
  await expect(target).toBeVisible()
  await expect(page.getByText("Request failed", { exact: true })).toBeVisible()
  const archived = page.waitForResponse((response) => response.url().endsWith("/api/rpc/custom.archive/archive"))
  await archive.press("Enter")
  expect((await archived).status()).toBe(200)
  await expect(target).toHaveCount(0)
  expect(mutations).toEqual(["POST", "POST"])
  await expect(page).toHaveURL(href(fixture.sourceID))
})

test("delete requires confirmation and removing the current session selects its neighbor", async ({ page }) => {
  const source = row(page, fixture.expected.sourceTitle)
  const mutations: string[] = []
  await page.route(`**/api/session/${fixture.sourceID}`, async (route) => {
    if (route.request().method() !== "DELETE") return route.fallback()
    mutations.push(route.request().method())
    await route.fulfill({ status: 204, headers: { "access-control-allow-origin": "*" } })
  })
  await swipe(page, source.locator("[data-titlebar-tab-link]"), -110)
  await source.getByRole("button", { name: "Delete", exact: true }).tap()
  const dialog = page.getByRole("dialog", { name: "Delete session", exact: true })
  await expect(dialog).toContainText(fixture.expected.sourceTitle)
  await expect(dialog).toContainText("all its child sessions")
  expect(mutations).toEqual([])
  await dialog.getByRole("button", { name: "Cancel", exact: true }).tap()
  await expect(dialog).toBeHidden()
  await expect(source).toBeVisible()
  await expect(source.getByRole("button", { name: "Delete", exact: true })).toBeFocused()
  await source.getByRole("button", { name: "Delete", exact: true }).tap()
  const deleted = page.waitForResponse((response) => response.request().method() === "DELETE")
  await dialog.getByRole("button", { name: "Delete session", exact: true }).tap()
  expect((await deleted).status()).toBe(204)
  await expect(dialog).toBeHidden()
  await expect(page).toHaveURL(href(fixture.targetID))
  expect(mutations).toEqual(["DELETE"])
})
