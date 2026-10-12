import { expect, test, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { fixture, pageMessages } from "../performance/timeline/session-timeline-stress.fixture"
import { stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { pressPlatformShortcut } from "../utils/command-palette"
import { expectSessionTitle } from "../utils/waits"

const serverKey = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const menu = (page: Page) => page.getByRole("menu", { name: "Recently closed", exact: true })
const newTab = (page: Page) =>
  page.locator('[data-slot="titlebar-v2"]').getByRole("button", { name: "New session", exact: true })

async function expectOnlyItem(page: Page, title: string) {
  await expect(menu(page).getByRole("menuitem")).toHaveCount(1)
  await expect(menu(page).getByRole("menuitem")).toHaveAccessibleName(title)
}

// Once its animations settle, the menu lies inside the viewport, above the drawer, with its entry on top at its center.
async function expectMenuOnTop(page: Page) {
  await expect(menu(page)).toBeVisible()
  await menu(page).evaluate((element) =>
    Promise.all(element.getAnimations({ subtree: true }).map((item) => item.finished)),
  )
  const viewport = page.viewportSize()!
  const box = await menu(page).boundingBox()
  expect(box).not.toBeNull()
  expect(box!.x).toBeGreaterThanOrEqual(0)
  expect(box!.y).toBeGreaterThanOrEqual(0)
  expect(box!.x + box!.width).toBeLessThanOrEqual(viewport.width)
  expect(box!.y + box!.height).toBeLessThanOrEqual(viewport.height)
  const entry = menu(page).getByRole("menuitem")
  await expect(entry).toHaveCount(1)
  expect(
    await entry.evaluate((element) => {
      const rect = element.getBoundingClientRect()
      return element.contains(document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2))
    }),
  ).toBe(true)
  await expect(menu(page)).toHaveCSS("opacity", "1")
}

async function setup(page: Page, tabLayout: "horizontal" | "vertical") {
  await mockOpenCodeServer(page, {
    sessions: fixture.sessions,
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages,
    tabLayout,
  })
  // Seed the tabs once, so a reload keeps what the test closed.
  await page.addInitScript(
    ({ server, sessionIDs }) => {
      if (localStorage.getItem("opencode.window.browser.dat:tabs")) return
      localStorage.setItem(
        "opencode.window.browser.dat:tabs",
        JSON.stringify(sessionIDs.map((sessionId) => ({ type: "session", server, sessionId }))),
      )
    },
    { server: serverKey, sessionIDs: [fixture.sourceID, fixture.targetID] },
  )
}

// Visiting the target loads its messages, so its tab is known to hold a prompt; then close it.
async function closeVisitedTarget(page: Page, close: "button" | "shortcut") {
  await page.goto(stressSessionHref(fixture.targetID))
  await expectSessionTitle(page, fixture.expected.targetTitle)
  await page.goto(stressSessionHref(fixture.sourceID))
  await expectSessionTitle(page, fixture.expected.sourceTitle)
  await page.goto(stressSessionHref(fixture.targetID))
  await expectSessionTitle(page, fixture.expected.targetTitle)
  await expect(page.locator('[data-component="composer-editor"]')).toBeEditable()
  if (close === "shortcut") await pressPlatformShortcut(page, "w")
  if (close === "button") {
    const tab = page.locator(`[data-titlebar-tab-slot]:has(a[href="${stressSessionHref(fixture.targetID)}"])`)
    await tab.hover()
    await tab.getByRole("button", { name: "Close tab", exact: true }).click()
  }
  await expect(page).toHaveURL(stressSessionHref(fixture.sourceID))
}

test.describe("desktop", () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test("the new-tab button's context menu reopens a closed tab once, after a reload", async ({ page }) => {
    await setup(page, "horizontal")
    await closeVisitedTarget(page, "button")
    const tabs = page.locator('[data-slot="titlebar-tabs"] [data-titlebar-tab-slot]')
    await expect(tabs).toHaveCount(1)
    await newTab(page).click({ button: "right" })
    await expectOnlyItem(page, fixture.expected.targetTitle)
    await page.keyboard.press("Escape")
    await expect(menu(page)).toHaveCount(0)
    await page.reload()
    await expectSessionTitle(page, fixture.expected.sourceTitle)

    await newTab(page).click({ button: "right" })
    await expect(menu(page).getByText("Recently closed", { exact: true })).toBeVisible()
    // The source session is open, so only the closed target is listed, with its persisted title.
    await expectOnlyItem(page, fixture.expected.targetTitle)
    await menu(page).getByRole("menuitem").click()
    await expect(page).toHaveURL(stressSessionHref(fixture.targetID))
    await expect(tabs).toHaveCount(2)
    await expect(tabs.last().locator(`a[href="${stressSessionHref(fixture.targetID)}"]`)).toHaveCount(1)

    await newTab(page).click({ button: "right" })
    await expect(menu(page).getByText("Recently closed", { exact: true })).toBeVisible()
    await expect(menu(page).getByRole("menuitem")).toHaveCount(0)
  })

  test("the sidebar's new-session context menu reopens a persisted closed tab", async ({ page }) => {
    await setup(page, "vertical")
    // Sidebar rows have no close control; start from a stored close record instead.
    await page.addInitScript(
      ({ server, sourceID, targetID, title, directory }) => {
        localStorage.setItem(
          "opencode.window.browser.dat:tabs",
          JSON.stringify([{ type: "session", server, sessionId: sourceID }]),
        )
        localStorage.setItem(
          "opencode.window.browser.dat:tabs.closed",
          JSON.stringify([
            {
              tab: { type: "session", server, sessionId: targetID },
              index: 1,
              info: { title, directory, prompted: true },
            },
            { tab: { type: "session", server, sessionId: "ses_smoke_unprompted" }, index: 2, info: { title: "Empty" } },
          ]),
        )
      },
      {
        server: serverKey,
        sourceID: fixture.sourceID,
        targetID: fixture.targetID,
        title: fixture.expected.targetTitle,
        directory: fixture.directory,
      },
    )
    await page.goto(stressSessionHref(fixture.sourceID))
    await expectSessionTitle(page, fixture.expected.sourceTitle)
    await page.locator('[data-action="vertical-tabs-new-session"]').click({ button: "right" })
    // A session that never received a prompt is not offered.
    await expectOnlyItem(page, fixture.expected.targetTitle)
    await menu(page).getByRole("menuitem", { name: fixture.expected.targetTitle, exact: true }).click()
    await expect(page).toHaveURL(stressSessionHref(fixture.targetID))
    await expectSessionTitle(page, fixture.expected.targetTitle)
  })
})

test.describe("phone", () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

  test("the tabs drawer reopens a closed tab by touch", async ({ page }) => {
    await setup(page, "horizontal")
    await closeVisitedTarget(page, "shortcut")
    await page.getByRole("button", { name: "Tabs", exact: true }).tap()
    const drawer = page.getByRole("dialog", { name: "Tabs", exact: true })
    await expect(drawer).not.toHaveAttribute("data-transitioning")
    const reopen = drawer.getByRole("button", { name: "Recently closed", exact: true })
    const entry = menu(page).getByRole("menuitem", { name: fixture.expected.targetTitle, exact: true })
    await reopen.tap()
    await expectMenuOnTop(page)

    // A tap outside the menu only dismisses it: the drawer row under the tap does not navigate or close the drawer.
    const row = drawer.locator('[data-slot="mobile-tab-swipe"]').filter({ hasText: fixture.expected.sourceTitle })
    const rowBox = await row.boundingBox()
    const menuBox = await menu(page).boundingBox()
    if (!rowBox || !menuBox) throw new Error("Drawer row and menu need bounds")
    const outside = { x: rowBox.x + 24, y: rowBox.y + rowBox.height / 2 }
    expect(outside.x < menuBox.x || outside.y < menuBox.y || outside.y > menuBox.y + menuBox.height).toBe(true)
    await page.touchscreen.tap(outside.x, outside.y)
    await expect(menu(page)).toHaveCount(0)
    await expect(page).toHaveURL(stressSessionHref(fixture.sourceID))
    await reopen.tap()
    await expectMenuOnTop(page)

    // Escape closes the menu and leaves the drawer open.
    await page.keyboard.press("Escape")
    await expect(menu(page)).toHaveCount(0)
    await reopen.tap()
    await expectMenuOnTop(page)
    await entry.tap()
    await expect(page).toHaveURL(stressSessionHref(fixture.targetID))
    await expect(drawer).toHaveCount(0)
    await expectSessionTitle(page, fixture.expected.targetTitle)

    await page.getByRole("button", { name: "Tabs", exact: true }).tap()
    await expect(page.getByRole("dialog", { name: "Tabs", exact: true })).not.toHaveAttribute("data-transitioning")
    // Nothing is left to reopen, so the drawer shows no reopen button.
    await expect(page.getByRole("button", { name: "Recently closed", exact: true })).toHaveCount(0)
  })
})
