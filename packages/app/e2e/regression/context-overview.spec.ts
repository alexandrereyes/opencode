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
  const usage = { remaining: 59, requests: 0, stale: false }
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
            plan: "pro",
            authenticated: true,
            cooldownSeconds: 0,
            bankedResets: {
              available: 3,
              earliestExpiresAt: "2026-10-01T12:00:00Z",
              latestExpiresAt: "2026-10-05T12:00:00Z",
              nonExpiring: 0,
            },
            stale: usage.stale,
            hasCapacity: true,
            observedAt: new Date().toISOString(),
            resetAt: "2026-09-15T02:15:47Z",
          },
          {
            id: "exhausted-fixture",
            name: "exhausted@example.test",
            remaining: 0,
            enabled: true,
            plan: "pro",
            authenticated: true,
            cooldownSeconds: 0,
            bankedResets: {
              available: 0,
              earliestExpiresAt: null,
              latestExpiresAt: null,
              nonExpiring: 0,
            },
            stale: false,
            hasCapacity: false,
            observedAt: new Date().toISOString(),
            resetAt: null,
          },
          {
            id: "plus-fixture",
            name: "plus@example.test",
            remaining: 100,
            enabled: true,
            plan: "plus",
            authenticated: true,
            cooldownSeconds: 0,
            stale: false,
            hasCapacity: true,
            observedAt: new Date().toISOString(),
            resetAt: null,
          },
          {
            id: "disabled-fixture",
            name: "disabled@example.test",
            remaining: 80,
            enabled: false,
            plan: "plus",
            authenticated: true,
            cooldownSeconds: 0,
            stale: false,
            hasCapacity: true,
            observedAt: new Date().toISOString(),
            resetAt: null,
          },
          {
            id: "unauthenticated-fixture",
            name: "reauth@example.test",
            remaining: null,
            enabled: true,
            plan: "plus",
            authenticated: false,
            cooldownSeconds: 0,
            stale: true,
            hasCapacity: null,
            observedAt: null,
            resetAt: null,
          },
          {
            id: "stale-fixture",
            name: "stale@example.test",
            remaining: 41,
            enabled: true,
            plan: "plus",
            authenticated: true,
            cooldownSeconds: 0,
            stale: true,
            hasCapacity: true,
            observedAt: new Date().toISOString(),
            resetAt: null,
          },
        ],
      },
    })
  })
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  const overview = page.locator('[data-slot="context-overview"]')
  await expect(overview.getByText("subscription@example.test", { exact: true })).toBeHidden()
  await expect(overview.getByText("Banked resets · Pro", { exact: true })).toBeVisible()
  await expect(overview.getByText(/First expiry:/)).toBeVisible()
  await expect(overview.getByText(/Last expiry:/)).toBeVisible()
  await expect(overview.getByRole("meter", { name: "Available Pro pool", exact: true })).toHaveAttribute(
    "aria-valuenow",
    "59",
  )
  await expect(overview.getByText("Available balance · 59% remaining", { exact: true })).toBeVisible()
  await expect(overview.getByText("Pro accounts available now: 1/2", { exact: true })).toBeVisible()
  await overview.locator('[data-slot="subscription-pool"] > summary').click()
  const pro = overview.getByRole("group", { name: "subscription@example.test" })
  await expect(pro).toContainText("59% remaining · 41% used")
  await expect(pro).toContainText("Plan: Pro")
  await expect(pro).toContainText("Capacity confirmed · available")
  const exhausted = overview.getByRole("group", { name: "exhausted@example.test" })
  await expect(exhausted).toContainText("0% remaining · 100% used")
  await expect(exhausted).toContainText("Capacity confirmed · unavailable")
  await expect(exhausted).toContainText("No capacity available")
  const plus = overview.getByRole("group", { name: "plus@example.test" })
  await expect(plus).toContainText("100% remaining · 0% used")
  await expect(plus).toContainText("Plan: Plus")
  await expect(plus).toContainText("Outside the active Pro pool")
  await expect(overview.getByRole("group", { name: "disabled@example.test" })).toContainText("Subscription disabled")
  await expect(overview.getByRole("group", { name: "reauth@example.test" })).toContainText("Reauthentication required")
  const stale = overview.getByRole("group", { name: "stale@example.test" })
  await expect(stale).toContainText("41% remaining · 59% used")
  await expect(stale).toContainText("Capacity unconfirmed")
  await overview.locator('[data-slot="subscription-pool"] > summary').press("Enter")
  await expect(overview.getByText("plus@example.test", { exact: true })).toBeHidden()
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
  await expect(overview.getByRole("link", { name: /Live child title.*Running/ })).toBeVisible()
  await expect(
    overview.getByRole("region", { name: "Session", exact: true }).locator('[data-component="text-shimmer"]'),
  ).toHaveCount(0)
  const background = overview.getByRole("list", { name: "Background tasks" })
  await expect(background.getByRole("button", { name: /Live child title/ })).toBeVisible()
  await expect(background.locator('[data-component="text-shimmer"]')).toHaveAttribute("data-active", "true")
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
  await expect(overview.getByRole("meter", { name: "Available Pro pool", exact: true })).toHaveAttribute(
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
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  await expect(overview).toBeVisible()
  await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.sourceID)}"]`).click()
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  await expect(overview.getByRole("meter", { name: "Available Pro pool", exact: true })).toBeVisible()
  usage.remaining = 21
  await overview.getByRole("button", { name: "Refresh subscription usage" }).click()
  await expect(overview.getByRole("meter", { name: "Available Pro pool", exact: true })).toHaveAttribute(
    "aria-valuenow",
    "21",
  )
  await page.reload()
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  await expect(overview.getByRole("meter", { name: "Available Pro pool", exact: true })).toBeVisible()
  usage.stale = true
  await overview.getByRole("button", { name: "Refresh subscription usage" }).click()
  await expect(
    overview.locator('[data-slot="subscription-pool"] > summary').getByText("Weekly balance unknown", { exact: true }),
  ).toBeVisible()
  await expect(overview.getByText("Current measurements: 1/2", { exact: true })).toBeVisible()
  await overview.getByRole("link", { name: /Inspect child navigation|Live child title/ }).click()
  await expect(page).toHaveURL(new RegExp(`${fixture.childID}$`))
})

test("shows every background task inline, including tasks beyond the old ten-item limit", async ({ page }) => {
  const children = Array.from({ length: 12 }, (_, index) => ({
    ...fixture.sessions[0],
    id: `ses_background_${index}`,
    parentID: fixture.sourceID,
    title: index === 0 ? `Long task ${"command".repeat(40)}` : `Background task ${index + 1}`,
  }))
  await mockOpenCodeServer(page, {
    sessions: [...fixture.sessions, ...children],
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages: (id) => ({ items: fixture.messages[id]?.slice(-2) ?? [] }),
    sessionStatus: Object.fromEntries(children.map((child) => [child.id, { type: "busy" }])),
  })
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  const tasks = page.getByRole("list", { name: "Background tasks" })
  await expect(tasks.getByRole("listitem")).toHaveCount(12)
  expect(await tasks.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true)
  const longTask = tasks.getByRole("button", { name: /Long task/ })
  expect(await longTask.evaluate((element) => element.getBoundingClientRect().height)).toBe(32)
  await longTask.click()
  const dialog = page.getByRole("dialog", { name: "Background task", exact: true })
  await expect(dialog.locator("pre")).toHaveText(`Long task ${"command".repeat(40)}`)
  await page.keyboard.press("Escape")
  await expect(dialog).toBeHidden()
  await tasks.getByRole("button", { name: "Background task 12 Agent", exact: true }).click()
  await dialog.getByRole("link", { name: "Open subagent", exact: true }).click()
  await expect(page).toHaveURL(/ses_background_11$/)
})
