import { expect, test } from "@playwright/test"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import {
  installStressSessionTabs,
  mockStressTimeline,
  stressSessionHref,
} from "../performance/timeline/timeline-test-helpers"

test.beforeEach(async ({ page }) => {
  await mockStressTimeline(page)
  await installStressSessionTabs(page)
})

test("compact services expand, collapse, and retain configuration actions", async ({ page }) => {
  await page.goto(stressSessionHref(fixture.targetID))
  await page.getByRole("button", { name: "Session details", exact: true }).click()
  const panel = page.locator('[data-component="session-summary-panel"]')
  await expect(panel.getByRole("tab")).toHaveText(["MCP", "Plugins", "Skills", "LSP"])
  await expect
    .poll(() => panel.getByRole("tab").evaluateAll((tabs) => tabs.every((tab) => tab.scrollWidth <= tab.clientWidth)))
    .toBe(true)
  await expect(panel.getByRole("tabpanel")).toHaveCount(0)
  for (const name of ["MCP", "Plugins", "Skills", "LSP"]) {
    const tab = panel.getByRole("tab", { name, exact: true })
    await tab.click()
    await expect(tab).toHaveAttribute("aria-expanded", "true")
    await expect(panel.getByRole("tabpanel")).toHaveCount(1)
    await expect(panel.getByRole("button", { name: "Copy configuration path", exact: true })).toBeVisible()
    await tab.press("Enter")
    await expect(panel.getByRole("tabpanel")).toHaveCount(0)
  }
})

for (const direction of ["ltr", "rtl"] as const) {
  test(`summary coordinates timeline and composer offsets in ${direction}`, async ({ page }) => {
    await page.setViewportSize({ width: 1800, height: 900 })
    await page.goto(stressSessionHref(fixture.targetID))
    await expect(page.locator("[data-session-title]").getByRole("heading")).toHaveText(fixture.expected.targetTitle)
    await page.evaluate((direction) => document.documentElement.setAttribute("dir", direction), direction)
    const review = page.getByRole("button", { name: "Toggle review", exact: true })
    await expect(review).toHaveAttribute("aria-expanded", "true")
    await review.click()
    const chat = page.locator('[data-slot="session-chat-panel"]')
    const content = chat.locator("[data-timeline-virtual-content]")
    const composer = chat.locator('[data-component="session-composer-dock"] > div')
    await page.getByRole("button", { name: "Session details", exact: true }).click()
    await expect(chat).toHaveAttribute("data-summary-open", "true")
    await expect(content).toHaveCSS("translate", direction === "ltr" ? "-160px" : "160px")
    await expect(composer).toHaveCSS("translate", direction === "ltr" ? "-160px" : "160px")
    await page.setViewportSize({ width: 1024, height: 900 })
    await expect(chat).toHaveAttribute("data-summary-resizing", "false")
    await expect(content).toHaveCSS("translate", "none")
    await page.keyboard.press("Escape")
    await expect(chat).toHaveAttribute("data-summary-open", "false")
    await page.setViewportSize({ width: 1800, height: 900 })
    await expect(content).toHaveCSS("translate", "none")
  })
}
