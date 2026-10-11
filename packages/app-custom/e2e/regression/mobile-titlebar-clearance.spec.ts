import { expect, test, type Page } from "@playwright/test"
import { fixture } from "../smoke/session-timeline.fixture"
import { mockOpenCodeServer } from "../utils/mock-server"

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

test.beforeEach(async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    provider: fixture.provider,
    sessions: fixture.sessions,
    pageMessages: () => ({ items: [] }),
  })
})

// iOS blurs content just below the status bar in Home Screen web apps; the row must stay clear of that band.
for (const inset of [0, 47]) {
  test(`phone titlebar row clears a ${inset}px top safe area`, async ({ page }) => {
    if (inset) {
      const cdp = await page.context().newCDPSession(page)
      await cdp.send("Emulation.setSafeAreaInsetsOverride", { insets: { top: inset, bottom: 34 } })
    }
    await page.goto("/")
    await expect(page.locator('[data-component="home-session-row"]')).toHaveCount(fixture.sessions.length)
    const titlebar = page.locator('[data-slot="titlebar-v2"]')
    const trigger = page.locator('[data-slot="mobile-tabs-trigger"]')
    await expect(trigger).toBeVisible()
    expect(await safeAreaTop(page)).toBe(inset)

    await expect
      .poll(async () => {
        const bar = await titlebar.boundingBox()
        const row = await trigger.boundingBox()
        if (!bar || !row) return undefined
        return { offset: row.y - bar.y, row: row.height, below: bar.y + bar.height - (row.y + row.height) }
      })
      .toEqual({ offset: inset + (inset ? 16 : 8), row: 44, below: 0 })
  })
}

test("bottom phone titlebar keeps its safe-area padding", async ({ page }) => {
  const cdp = await page.context().newCDPSession(page)
  await cdp.send("Emulation.setSafeAreaInsetsOverride", { insets: { top: 47, bottom: 34 } })
  await page.addInitScript(() => {
    localStorage.setItem("settings.v3", JSON.stringify({ general: { mobileTitlebarPosition: "bottom" } }))
  })
  await page.goto("/")
  await expect(page.locator('[data-component="home-session-row"]')).toHaveCount(fixture.sessions.length)
  const titlebar = page.locator('[data-slot="titlebar-v2"]')
  await expect(titlebar).toHaveCSS("padding-top", "0px")
  await expect(titlebar).toHaveCSS("padding-bottom", "34px")
})

function safeAreaTop(page: Page) {
  return page.evaluate(() => {
    const probe = document.createElement("div")
    probe.style.paddingTop = "env(safe-area-inset-top, 0px)"
    document.body.append(probe)
    const value = Number.parseFloat(getComputedStyle(probe).paddingTop)
    probe.remove()
    return value
  })
}
