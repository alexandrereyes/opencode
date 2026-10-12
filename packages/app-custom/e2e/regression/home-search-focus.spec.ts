import { expect, test, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { fixture, pageMessages } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { pressPlatformShortcut } from "../utils/command-palette"
import { expectSessionTitle } from "../utils/waits"

test.use({ serviceWorkers: "block" })

async function openSession(page: Page) {
  await mockOpenCodeServer(page, {
    sessions: fixture.sessions,
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages,
    tabLayout: "horizontal",
  })
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  await expectSessionTitle(page, fixture.expected.sourceTitle)
  const editor = page.locator('[data-component="composer-editor"]')
  await expect(editor).toBeEditable()
  await editor.click()
}

const search = (page: Page) =>
  page.locator('[data-component="home-screen"]').getByRole("textbox", { name: /Search sessions/ })

async function shortcutFocusesSearch(page: Page) {
  await pressPlatformShortcut(page, "b")
  await expect(search(page)).toBeFocused()
  await page.keyboard.type("jump")
  const results = page.locator('[data-component="home-screen"]').getByRole("option")
  await expect(results).toHaveCount(1)
  await expect(results).toContainText(fixture.expected.targetTitle)
  await pressPlatformShortcut(page, "b")
  await expect(page).toHaveURL(stressSessionHref(fixture.sourceID))
}

test.describe("desktop", () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test("the Home shortcut focuses session search, and the Home button leaves focus alone", async ({ page }) => {
    await openSession(page)
    await shortcutFocusesSearch(page)
    await page.locator('[data-slot="titlebar-v2"]').getByRole("button", { name: "Home", exact: true }).click()
    await expect(search(page)).toHaveValue("")
    await expect(search(page)).not.toBeFocused()
  })
})

test.describe("phone", () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

  test("the Home shortcut focuses session search, and the drawer's Home leaves focus alone", async ({ page }) => {
    await openSession(page)
    await shortcutFocusesSearch(page)
    await page.getByRole("button", { name: "Tabs", exact: true }).tap()
    await expect(page.getByRole("dialog", { name: "Tabs", exact: true })).not.toHaveAttribute("data-transitioning")
    await page.locator('[data-action="mobile-tabs-home"]').tap()
    await expect(search(page)).toHaveValue("")
    await expect(search(page)).not.toBeFocused()
  })
})
