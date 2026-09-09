import { expect, test } from "@playwright/test"
import type { OpenCodeEvent } from "@opencode/client/promise"
import { mockOpenCodeServer } from "../utils/mock-server"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"

test("context tab retains selection across sessions and shows live quota and subagents", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1000 })
  await page.clock.install()
  const events: OpenCodeEvent[] = []
  const sessions = fixture.sessions.map((session) =>
    session.id === fixture.targetID ? { ...session, directory: "C:/OpenCode/OtherProject" } : { ...session },
  )
  await mockOpenCodeServer(page, {
    sessions,
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages: (id) => ({ items: fixture.messages[id]?.slice(-2) ?? [] }),
    events: () => events.splice(0),
  })
  const usage = { remaining: 25, requests: 0 }
  await page.route("**/api/server/subscriptions", (route) => {
    usage.requests++
    return route.fulfill({
      json: {
        status: "ok",
        accounts: [
          {
            id: "quota-fixture",
            name: "subscription@example.test",
            remaining: usage.remaining,
            enabled: true,
            stale: false,
            hasCapacity: true,
            observedAt: new Date().toISOString(),
            resetAt: "2026-09-15T02:15:47Z",
          },
        ],
      },
    })
  })
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  await page.getByRole("button", { name: "View context usage", exact: true }).click()
  const overview = page.locator('[data-slot="context-overview"]')
  await expect(overview.getByText("subscription@example.test", { exact: true })).toBeVisible()
  await expect(overview.getByRole("meter", { name: "subscription@example.test" })).toHaveAttribute(
    "aria-valuenow",
    "25",
  )
  await expect(overview.getByRole("link", { name: /Inspect child navigation/ })).toBeVisible()
  events.push({
    id: "evt_context_renamed",
    created: Date.now(),
    type: "session.renamed",
    durable: { aggregateID: fixture.childID, seq: 1, version: 1 },
    data: { sessionID: fixture.childID, title: "Live child title" },
  })
  await expect(overview.getByRole("link", { name: /Live child title/ })).toBeVisible()
  events.push({
    id: "evt_context_running",
    created: Date.now(),
    type: "session.execution.started",
    durable: { aggregateID: fixture.childID, seq: 2, version: 1 },
    data: { sessionID: fixture.childID },
  })
  await expect(overview.getByRole("link", { name: /Live child title/ })).toContainText("Running")
  await expect(overview.getByRole("button", { name: "1 background task running" })).toBeVisible()
  await overview.getByRole("button", { name: "1 background task running" }).click()
  await expect(page.locator('[data-component="session-background-list"]')).toContainText("Live child title")
  await page.keyboard.press("Escape")
  events.push({
    id: "evt_context_done",
    created: Date.now(),
    type: "session.execution.succeeded",
    durable: { aggregateID: fixture.childID, seq: 3, version: 1 },
    data: { sessionID: fixture.childID },
  })
  await expect(overview.getByText("No background tasks running.")).toBeVisible()
  const assistant = fixture.messages[fixture.sourceID]?.at(-1)
  if (!assistant || assistant.type !== "assistant") throw new Error("Missing assistant fixture")
  events.push({
    id: "evt_context_tokens",
    created: Date.now(),
    type: "session.step.ended",
    durable: { aggregateID: fixture.sourceID, seq: 2, version: 1 },
    data: {
      sessionID: fixture.sourceID,
      assistantMessageID: assistant.id,
      finish: "stop",
      cost: 2,
      tokens: { input: 40000, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  })
  await expect(overview.getByRole("meter", { name: "Context", exact: true })).toHaveAttribute("aria-valuenow", "20")
  usage.remaining = 24
  await page.clock.fastForward(60_000)
  await expect(overview.getByRole("meter", { name: "subscription@example.test" })).toHaveAttribute(
    "aria-valuenow",
    "24",
  )
  await page.getByRole("tab", { name: "Review", exact: true }).click()
  await expect(overview).toBeHidden()
  const requests = usage.requests
  await page.clock.fastForward(120_000)
  expect(usage.requests).toBe(requests)
  await page.getByRole("tab", { name: "Context", exact: true }).click()
  await expect(overview).toBeVisible()
  const source = sessions.find((session) => session.id === fixture.sourceID)
  if (!source) throw new Error("Missing source fixture")
  source.directory = "C:/OpenCode/MovedProject"
  events.push({
    id: "evt_context_moved",
    created: Date.now(),
    type: "session.moved",
    durable: { aggregateID: fixture.sourceID, seq: 1, version: 1 },
    data: { sessionID: fixture.sourceID, projectID: source.projectID, location: { directory: source.directory } },
  })
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.targetID)}"]`).click()
  await page.getByRole("button", { name: "View context usage", exact: true }).click()
  await expect(overview).toBeVisible()
  await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.sourceID)}"]`).click()
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  await expect(overview.getByText("subscription@example.test", { exact: true })).toBeVisible()
  usage.remaining = 21
  await overview.getByRole("button", { name: "Refresh subscription usage" }).click()
  await expect(overview.getByRole("meter", { name: "subscription@example.test" })).toHaveAttribute(
    "aria-valuenow",
    "21",
  )
  await page.reload()
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  await expect(overview.getByText("subscription@example.test", { exact: true })).toBeVisible()
  await overview.getByRole("link", { name: /Inspect child navigation|Live child title/ }).click()
  await expect(page).toHaveURL(new RegExp(`${fixture.childID}$`))
})
