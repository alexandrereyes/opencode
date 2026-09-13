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
  const usage = { remaining: 59, requests: 0, stale: false, locations: [] as string[] }
  const delayed = {
    enabled: false,
    captured: false,
    started: Promise.withResolvers<void>(),
    release: Promise.withResolvers<void>(),
    completed: Promise.withResolvers<void>(),
  }
  await page.route("**/api/rpc/custom.subscriptions/list?*", async (route) => {
    usage.requests++
    const location = new URL(route.request().url()).searchParams.get("location[directory]") ?? ""
    usage.locations.push(location)
    expect(route.request().postDataJSON()).toEqual({ input: {} })
    if (location === "C:/OpenCode/MovedProject") {
      await route.fulfill({ status: 404, body: "Missing plugin RPC" })
      return
    }
    const waiting = delayed.enabled && !delayed.captured
    if (waiting) {
      delayed.captured = true
      delayed.started.resolve()
      await delayed.release.promise
    }
    try {
      await route.fulfill({
        json: {
          output: {
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
                bankedResets: {
                  available: 2,
                  earliestExpiresAt: null,
                  latestExpiresAt: null,
                  nonExpiring: 2,
                },
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
                bankedResets: null,
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
                bankedResets: null,
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
                bankedResets: null,
                stale: true,
                hasCapacity: true,
                observedAt: new Date().toISOString(),
                resetAt: null,
              },
            ].toReversed(),
          },
        },
      })
    } finally {
      if (waiting) delayed.completed.resolve()
    }
  })
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  const overview = page.locator('[data-slot="context-overview"]')
  await expect(overview.getByText("subscription@example.test", { exact: true })).toBeHidden()
  await expect(overview.getByText("Banked resets · Pro", { exact: true })).toBeVisible()
  expect(usage.locations).toContain(fixture.directory)
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
  await expect(pro).toContainText("Banked resets: 3")
  await expect(pro).toContainText("Capacity confirmed · available")
  const exhausted = overview.getByRole("group", { name: "exhausted@example.test" })
  await expect(exhausted).toContainText("0% remaining · 100% used")
  await expect(exhausted).toContainText("Banked resets: 0")
  await expect(exhausted).toContainText("Capacity confirmed · unavailable")
  await expect(exhausted).toContainText("No capacity available")
  const plus = overview.getByRole("group", { name: "plus@example.test" })
  await expect(plus).toContainText("100% remaining · 0% used")
  await expect(plus).toContainText("Plan: Plus")
  await expect(plus).toContainText("Banked resets: 2")
  await expect(plus).toContainText("Outside the active Pro pool")
  await expect(overview.getByRole("group", { name: "disabled@example.test" })).toContainText("Subscription disabled")
  const reauth = overview.getByRole("group", { name: "reauth@example.test" })
  await expect(reauth).toContainText("Banked resets: Unavailable")
  await expect(reauth).toContainText("Reauthentication required")
  const stale = overview.getByRole("group", { name: "stale@example.test" })
  await expect(stale).toContainText("41% remaining · 59% used")
  await expect(stale).toContainText("Capacity unconfirmed")
  const accountGroups = overview.locator('[data-slot="subscription-pool"] [role="group"]')
  await expect(accountGroups).toHaveCount(6)
  await expect
    .poll(() => accountGroups.evaluateAll((elements) => elements.map((element) => element.getAttribute("aria-label"))))
    .toEqual([
      "subscription@example.test",
      "exhausted@example.test",
      "stale@example.test",
      "reauth@example.test",
      "disabled@example.test",
      "plus@example.test",
    ])
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
  usage.remaining = 21
  await overview.getByRole("button", { name: "Refresh subscription usage" }).click()
  await expect(overview.getByRole("meter", { name: "Available Pro pool", exact: true })).toHaveAttribute(
    "aria-valuenow",
    "21",
  )
  expect(usage.locations.at(-1)).toBe(fixture.directory)
  await page.reload()
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  await expect(overview.getByRole("meter", { name: "Available Pro pool", exact: true })).toBeVisible()
  usage.stale = true
  await overview.getByRole("button", { name: "Refresh subscription usage" }).click()
  await expect(
    overview.locator('[data-slot="subscription-pool"] > summary').getByText("Weekly balance unknown", { exact: true }),
  ).toBeVisible()
  await expect(overview.getByText("Current measurements: 1/2", { exact: true })).toBeVisible()
  const subscriptionPool = overview.locator('[data-slot="subscription-pool"]')
  await expect(subscriptionPool).not.toHaveAttribute("open", "")
  await subscriptionPool.locator("> summary").click()
  await expect(subscriptionPool).toHaveAttribute("open", "")
  await expect(accountGroups).toHaveCount(6)
  await expect
    .poll(() => accountGroups.evaluateAll((elements) => elements.map((element) => element.getAttribute("aria-label"))))
    .toEqual([
      "exhausted@example.test",
      "subscription@example.test",
      "stale@example.test",
      "reauth@example.test",
      "disabled@example.test",
      "plus@example.test",
    ])
  delayed.enabled = true
  await overview.getByRole("button", { name: "Refresh subscription usage" }).click()
  await delayed.started.promise
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
  await expect.poll(() => usage.locations.at(-1)).toBe("C:/OpenCode/MovedProject")
  await expect(overview.getByText("Subscription usage is unavailable. Try refreshing.", { exact: true })).toBeVisible()
  delayed.release.resolve()
  await delayed.completed.promise
  await expect(overview.getByText("Subscription usage is unavailable. Try refreshing.", { exact: true })).toBeVisible()
  await expect(overview.getByRole("meter", { name: "Available Pro pool", exact: true })).toHaveCount(0)
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
  const longTask = tasks.getByRole("button", { name: /Long task/ })
  await expect(longTask).toBeVisible()
  await expect(longTask).toHaveCSS("height", "32px")
  expect(await tasks.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true)
  await longTask.click()
  const dialog = page.getByRole("dialog", { name: "Background task", exact: true })
  await expect(dialog.locator("pre")).toHaveText(`Long task ${"command".repeat(40)}`)
  await page.keyboard.press("Escape")
  await expect(dialog).toBeHidden()
  await tasks.getByRole("button", { name: "Background task 12 Agent", exact: true }).click()
  await dialog.getByRole("link", { name: "Open subagent", exact: true }).click()
  await expect(page).toHaveURL(/ses_background_11$/)
})
