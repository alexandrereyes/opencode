import type { Page } from "@playwright/test"
import { expectSessionTitle } from "../../utils/waits"
import { benchmark, benchmarkDiagnostics, expect } from "../benchmark"
import { fixture } from "./session-timeline-stress.fixture"
import { installStressSessionTabs, mockStressTimeline, stressSessionHref } from "./timeline-test-helpers"
import { measureSessionSwitch, waitForStableTimeline } from "./session-tab-switch-probe"

const viewport = { width: 1440, height: 900 }

benchmark.describe.configure({ mode: "serial" })
benchmark.setTimeout(120_000)
benchmark.use({ viewport, video: "off", trace: "off", serviceWorkers: "block", traceScope: "interaction" })

benchmark("cached session activation and summary open by click", async ({ page, report }) => {
  await mockStressTimeline(page)
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  await expectSessionTitle(page, fixture.expected.sourceTitle)
  await waitForStableTimeline(page, fixture.expected.sourceMessageIDs.at(-1)!)
  const sidebar = page.locator('[data-slot="vertical-tabs-sidebar"]')
  await sidebar.getByRole("button", { name: "Attention view", exact: true }).click()
  await expect(sidebar.getByRole("navigation", { name: "Sessions", exact: true })).toHaveAttribute(
    "data-mode",
    "projects",
  )

  await switchSession(page, fixture.targetID, fixture.expected.targetTitle)
  await waitForStableTimeline(page, fixture.expected.targetMessageIDs.at(-1)!)
  await switchSession(page, fixture.sourceID, fixture.expected.sourceTitle)
  await waitForStableTimeline(page, fixture.expected.sourceMessageIDs.at(-1)!)

  await benchmarkDiagnostics(page).startTrace()
  const activation = await measureSessionSwitch(page, {
    destinationIDs: fixture.expected.targetMessageIDs,
    sourceIDs: fixture.expected.sourceMessageIDs,
    lastID: fixture.expected.targetMessageIDs.at(-1)!,
    requiredPartID: fixture.expected.targetPartIDs.at(-1)!,
    href: stressSessionHref(fixture.targetID),
    switch: () => switchSession(page, fixture.targetID, fixture.expected.targetTitle),
  })

  expect(activation.firstCorrectObservedMs).not.toBeNull()
  expect(activation.stableObservedMs).not.toBeNull()
  await expectSessionTitle(page, fixture.expected.targetTitle)
  await waitForStableTimeline(page, fixture.expected.targetMessageIDs.at(-1)!)

  const summaryTrigger = page.getByRole("button", { name: "Session details", expanded: false })
  await expect(summaryTrigger).toBeVisible()
  const summaryStarted = await page.evaluate(() => performance.now())
  await summaryTrigger.click()
  await expect(page.getByRole("button", { name: "Session details", expanded: true })).toBeVisible()
  await expect(page.locator('[data-component="session-summary-panel"]')).toBeVisible()
  const summary = {
    visibleObservedMs: await page.evaluate((started) => performance.now() - started, summaryStarted),
  }
  await benchmarkDiagnostics(page).stop()

  expect(summary.visibleObservedMs).not.toBeNull()
  await expect(page.getByRole("button", { name: "Session details", expanded: true })).toBeVisible()
  await expect(page.locator('[data-component="session-summary-panel"]')).toBeVisible()
  report(
    { activation, summary },
    {
      buildHash: process.env.OPENCODE_PERFORMANCE_BUILD_HASH,
      cache: "warm",
      summaryInput: "click",
      data: "paginated fixture",
      viewport,
    },
  )
})

async function switchSession(page: Page, sessionID: string, title: string) {
  const tab = page
    .locator(`[data-titlebar-tab-link][href="${stressSessionHref(sessionID)}"]`)
    .filter({ has: page.locator('[data-slot="tab-project"]') })
  await expect(tab).toHaveCount(1)
  await tab.click()
  await expectSessionTitle(page, title)
}
