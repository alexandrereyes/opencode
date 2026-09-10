import { expect, test } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"

test("shares the dragged divider width with existing and newly opened sessions and restores it locally", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1800, height: 1000 })
  await page.emulateMedia({ reducedMotion: "reduce" })
  const fresh = { ...fixture.sessions[0], id: "ses_width_new", title: "New width session" }
  await mockOpenCodeServer(page, {
    sessions: [...fixture.sessions, fresh],
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages: (id) => ({ items: fixture.messages[id]?.slice(-2) ?? fixture.messages[fixture.sourceID].slice(-2) }),
  })
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  const panel = page.locator('[data-slot="session-chat-panel"]')
  const handle = panel.locator('[data-component="resize-handle"][data-direction="horizontal"]')
  await expect(handle).toBeVisible()
  await expect(panel).toHaveCSS("width", "600px")
  const bounds = await handle.boundingBox()
  if (!bounds) throw new Error("Missing divider bounds")
  await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + 80)
  await page.mouse.down()
  await page.mouse.move(bounds.x + bounds.width / 2 + 120, bounds.y + 80)
  await page.mouse.up()
  await expect(panel).toHaveCSS("width", "720px")
  await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.targetID)}"]`).click()
  await expect(page).toHaveURL(stressSessionHref(fixture.targetID))
  await expect(panel).toHaveCSS("width", "720px")
  await page.reload()
  await expect(panel).toHaveCSS("width", "720px")
  await page.goto(stressSessionHref(fresh.id))
  await expect(panel).toHaveCSS("width", "720px")
  await page.setViewportSize({ width: 1100, height: 1000 })
  await expect(panel).toHaveCSS("width", "450px")
  await page.setViewportSize({ width: 1800, height: 1000 })
  await expect(panel).toHaveCSS("width", "720px")
  await page.goto(stressSessionHref(fixture.sourceID))
  await expect(panel).toHaveCSS("width", "720px")
})
