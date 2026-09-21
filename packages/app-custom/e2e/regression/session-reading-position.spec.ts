import { expect, test, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { waitForStableTimeline } from "../performance/timeline/session-tab-switch-probe"

test.use({ viewport: { width: 1440, height: 900 }, serviceWorkers: "block" })

for (const scenario of ["cached session switch", "workspace disposal", "pagination and workspace disposal"]) {
  test(`restores reading anchor after ${scenario}`, async ({ page }) => {
    const workspace = scenario !== "cached session switch"
    const pagination = scenario.startsWith("pagination")
    const pages: string[] = []
    await mockOpenCodeServer(page, {
      ...fixture,
      sessions: fixture.sessions.map((session) =>
        workspace && session.id === fixture.targetID ? { ...session, directory: "C:/OpenCode/OtherProject" } : session,
      ),
      pageMessages: (id, limit, before) => {
        const messages = fixture.messages[id] ?? []
        if (!pagination) return { items: messages }
        const end = before ? messages.findIndex((message) => message.id === before) : messages.length
        const start = Math.max(0, end - Math.min(limit, 8))
        return { items: messages.slice(start, end), cursor: start > 0 ? messages[start]!.id : undefined }
      },
      onMessages: ({ before, phase }) => {
        if (before && phase === "end") pages.push(before)
      },
    })
    await installStressSessionTabs(page)
    await page.goto(stressSessionHref(fixture.sourceID))
    await waitForStableTimeline(page, fixture.expected.sourceMessageIDs.at(-1)!)
    await page.getByRole("button", { name: "Attention view", exact: true }).click()
    await expect(page.getByRole("navigation", { name: "Sessions", exact: true })).toHaveAttribute(
      "data-mode",
      "projects",
    )
    const source = page
      .locator(`[data-titlebar-tab-link][href="${stressSessionHref(fixture.sourceID)}"]`)
      .filter({ has: page.locator('[data-slot="tab-project"]') })
    const target = page
      .locator(`[data-titlebar-tab-link][href="${stressSessionHref(fixture.targetID)}"]`)
      .filter({ has: page.locator('[data-slot="tab-project"]') })
    const viewport = page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport')
    await viewport.hover()
    await page.mouse.wheel(0, pagination ? -1000000 : -1900)
    if (pagination) await expect.poll(() => pages.length).toBeGreaterThan(0)
    await expect
      .poll(() => viewport.evaluate((el) => el.scrollHeight - el.clientHeight - el.scrollTop))
      .toBeGreaterThan(1500)
    await expect(page.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(0)
    await expect.poll(() => readAnchor(page)).toBeDefined()
    const anchor = await readAnchor(page)
    expect(anchor).toBeDefined()
    await target.click()
    await waitForStableTimeline(page, fixture.expected.targetMessageIDs.at(-1)!)
    if (workspace) await page.setViewportSize({ width: 1280, height: 800 })
    await source.click()
    await expect
      .poll(async () => {
        const current = await readAnchor(page)
        return current?.key === anchor!.key ? Math.abs(current.offset - anchor!.offset) : 100000
      })
      .toBeLessThan(3)
    await expect(page.locator("[data-timeline-virtual-content]")).toHaveCount(1)

    // Following the tail remains explicit and survives the same round trip.
    await page.getByRole("button", { name: "Jump to latest" }).click()
    await waitForStableTimeline(page, fixture.expected.sourceMessageIDs.at(-1)!)
    await target.click()
    await waitForStableTimeline(page, fixture.expected.targetMessageIDs.at(-1)!)
    await source.click()
    await waitForStableTimeline(page, fixture.expected.sourceMessageIDs.at(-1)!)

    await target.click()
    await waitForStableTimeline(page, fixture.expected.targetMessageIDs.at(-1)!)
    const messageID = fixture.expected.sourceMessageIDs[0]!
    await page.evaluate(
      (href) => {
        const link = document.createElement("a")
        link.href = href
        link.textContent = "Explicit message link"
        link.style.cssText = "position:fixed;top:0;left:0;z-index:99999;background:white"
        document.body.append(link)
      },
      `${stressSessionHref(fixture.sourceID)}#message-${messageID}`,
    )
    await page.getByRole("link", { name: "Explicit message link", exact: true }).click()
    await expect(page.locator(`#message-${messageID}`)).toBeInViewport()
    await expect(page).toHaveURL(new RegExp(`#message-${messageID}$`))
  })
}

async function readAnchor(page: Page) {
  return page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport').evaluate((root) => {
    const top = root.getBoundingClientRect().top
    return [...root.querySelectorAll<HTMLElement>("[data-timeline-key]")].flatMap((row) => {
      if (row.querySelector("[data-sticky-user]")) return []
      const rect = row.getBoundingClientRect()
      if (rect.bottom <= top || rect.top >= root.getBoundingClientRect().bottom) return []
      return [{ key: row.dataset.timelineKey!, offset: top - rect.top }]
    })[0]
  })
}
