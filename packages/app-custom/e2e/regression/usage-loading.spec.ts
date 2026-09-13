import { expect, test, type Request } from "@playwright/test"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { currentSession, mockOpenCodeServer } from "../utils/mock-server"

for (const first of ["subscriptions", "children"] as const) {
  test(`mobile Usage remains interactive while loading ${first} first`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await mockOpenCodeServer(page, {
      directory: fixture.directory,
      project: fixture.project,
      sessions: fixture.sessions,
      provider: fixture.provider,
      pageMessages: (id) => ({ items: fixture.messages[id]?.slice(-2) ?? [] }),
    })
    await installStressSessionTabs(page)
    const subscriptions = Promise.withResolvers<void>()
    const children = Promise.withResolvers<void>()
    const started = { subscriptions: false, children: false }
    await page.route("**/api/rpc/custom.subscriptions/list?*", async (route) => {
      started.subscriptions = true
      await subscriptions.promise
      await route.fulfill({ json: { output: { status: "unconfigured", accounts: [] } } })
    })
    await page.route("**/api/session?*", async (route) => {
      if (!new URL(route.request().url()).searchParams.has("parentID")) return route.fallback()
      started.children = true
      await children.promise
      await route.fallback()
    })
    try {
      await page.goto(stressSessionHref(fixture.targetID))
      const tabs = page.getByRole("tablist", { name: "Session view", exact: true })
      await expect(tabs.getByRole("tab", { selected: true })).toHaveText("Session")
      await page.getByRole("textbox", { name: "Prompt", exact: true }).fill("Still interactive")
      await tabs.getByRole("tab", { name: "Usage", exact: true }).click()
      await expect.poll(() => started).toEqual({ subscriptions: true, children: true })
      const usage = page.locator('[data-slot="session-usage-content"]')
      const overview = usage.locator('[data-slot="context-overview"]')
      await expect(tabs.getByRole("tab", { selected: true })).toHaveText("Usage")
      await expect(page.locator('[data-slot="mobile-tabs-trigger"]')).toContainText(fixture.expected.targetTitle)
      await expect(usage.getByText("Total Cost", { exact: true })).toBeVisible()
      await expect(overview.getByRole("meter", { name: "Context", exact: true })).toBeVisible()
      await expect(overview.getByRole("status")).toHaveCount(2)
      await expect(overview.getByText("No subagents in this session yet.", { exact: true })).toHaveCount(0)
      if (process.env.OPENCODE_USAGE_SCREENSHOTS)
        await page.screenshot({ path: `${process.env.OPENCODE_USAGE_SCREENSHOTS}/${first}-pending.png` })
      await tabs.getByRole("tab", { name: "Session", exact: true }).click()
      await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toHaveText("Still interactive")
      await tabs.getByRole("tab", { name: "Usage", exact: true }).click()
      await expect(usage.getByText("Total Cost", { exact: true })).toBeVisible()
      if (first === "subscriptions") subscriptions.resolve()
      if (first === "children") children.resolve()
      await expect(overview.getByRole("status").filter({ hasText: "Loading" })).toHaveCount(1)
      await expect(usage.getByText("Total Cost", { exact: true })).toBeVisible()
      subscriptions.resolve()
      children.resolve()
      await expect(overview.getByRole("status").filter({ hasText: "Loading" })).toHaveCount(0)
      await expect(overview.getByRole("button", { name: "Refresh subscription usage" })).toBeEnabled()
    } finally {
      subscriptions.resolve()
      children.resolve()
    }
  })
}

test("missing subscriptions RPC and late family responses preserve the current session and navigation", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1440, height: 1000 })
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    sessions: fixture.sessions,
    provider: fixture.provider,
    pageMessages: (id) => ({ items: fixture.messages[id]?.slice(-2) ?? [] }),
  })
  await installStressSessionTabs(page)
  const usage = page.locator('[data-slot="session-usage-content"]')
  const overview = usage.locator('[data-slot="context-overview"]')
  // Hydrate the family through the real UI before testing cached children.
  // The initial session index contains roots, not necessarily descendants.
  await page.goto(stressSessionHref(fixture.sourceID))
  await expect(overview.getByRole("link", { name: /Inspect child navigation/ })).toBeVisible()
  await expect(overview.getByRole("status").filter({ hasText: "Loading" })).toHaveCount(0)
  await page.getByRole("tab", { name: "Review", exact: true }).click()
  await expect(usage).toBeHidden()
  const family = Promise.withResolvers<void>()
  const familyRequest = Promise.withResolvers<Request>()
  const quota = Promise.withResolvers<void>()
  const started = { family: false, quota: false }
  await page.route("**/api/rpc/custom.subscriptions/list?*", async (route) => {
    started.quota = true
    await quota.promise
    await route.fulfill({ status: 404, body: "Missing plugin RPC" })
  })
  await page.route("**/api/session?*", async (route) => {
    const query = new URL(route.request().url()).searchParams
    if (query.get("parentID") !== fixture.sourceID || query.get("limit") !== "100") return route.fallback()
    familyRequest.resolve(route.request())
    started.family = true
    await family.promise
    await route.fulfill({ status: 503, body: "Unavailable" })
  })
  try {
    await page.getByRole("tab", { name: "Context", exact: true }).click()
    await expect.poll(() => started).toEqual({ family: true, quota: true })
    await expect(usage.getByText("Total Cost", { exact: true })).toBeVisible()
    await expect(overview.getByRole("link", { name: /Inspect child navigation/ })).toBeVisible()
    quota.resolve()
    await expect(
      overview.getByText("Subscription usage is unavailable. Try refreshing.", { exact: true }),
    ).toBeVisible()
    await expect(usage.getByText("Total Cost", { exact: true })).toBeVisible()
    await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.targetID)}"]`).click()
    await expect(page).toHaveURL(new RegExp(`${fixture.targetID}$`))
    await expect(usage.getByText(fixture.expected.targetTitle, { exact: true })).toBeVisible()
    const request = await familyRequest.promise
    const completed = Promise.withResolvers<void>()
    const finish = (candidate: Request) => {
      if (candidate !== request) return
      page.off("requestfinished", finish)
      page.off("requestfailed", finish)
      completed.resolve()
    }
    page.on("requestfinished", finish)
    page.on("requestfailed", finish)
    const response = page.waitForResponse((response) => response.request() === request)
    family.resolve()
    // The client cancels bodies for unexpected statuses; Chromium need not emit
    // requestfinished for that stream. Accept either terminal event for this exact request.
    expect((await response).status()).toBe(503)
    await completed.promise
    await expect(usage.getByText(fixture.expected.targetTitle, { exact: true })).toBeVisible()
    await expect(overview.getByText("No subagents in this session yet.", { exact: true })).toBeVisible()
    await expect(overview.getByRole("link", { name: /Inspect child navigation/ })).toHaveCount(0)
    await expect(overview.getByText("Could not load all subagents. Reopen this tab to retry.")).toHaveCount(0)
    await page.getByRole("tab", { name: "Review", exact: true }).click()
    await expect(usage).toBeHidden()
    await page.getByRole("tab", { name: "Context", exact: true }).click()
    await expect(usage.getByText(fixture.expected.targetTitle, { exact: true })).toBeVisible()
    await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.sourceID)}"]`).click()
    await expect(overview.getByText("Could not load all subagents. Reopen this tab to retry.")).toBeVisible()
    await expect(overview.getByRole("link", { name: /Inspect child navigation/ })).toBeVisible()
    await expect(usage.getByText("Total Cost", { exact: true })).toBeVisible()
  } finally {
    family.resolve()
    quota.resolve()
  }
})

for (const leave of ["navigate", "unmount"] as const) {
  test(`late successful family response cannot overwrite the current session after ${leave}`, async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 1000 })
    const target = fixture.sessions.find((session) => session.id === fixture.targetID)!
    await mockOpenCodeServer(page, {
      directory: fixture.directory,
      project: fixture.project,
      sessions: fixture.sessions.map((session) => (session.id === target.id ? { ...session, cost: 7 } : session)),
      provider: fixture.provider,
      pageMessages: (id) => ({ items: fixture.messages[id]?.slice(-2) ?? [] }),
    })
    await installStressSessionTabs(page)
    const family = Promise.withResolvers<void>()
    const familyRequest = Promise.withResolvers<Request>()
    const started = Promise.withResolvers<void>()
    await page.route("**/api/session?*", async (route) => {
      const query = new URL(route.request().url()).searchParams
      if (query.get("parentID") !== fixture.sourceID || query.get("limit") !== "100") return route.fallback()
      familyRequest.resolve(route.request())
      started.resolve()
      await family.promise
      await route.fulfill({
        json: {
          data: [
            currentSession(
              { ...target, parentID: fixture.sourceID, title: "Stale target title", cost: 1 },
              fixture.directory,
            ),
          ],
          cursor: {},
        },
      })
    })
    try {
      await page.goto(stressSessionHref(fixture.sourceID))
      await started.promise
      const usage = page.locator('[data-slot="session-usage-content"]')
      await expect(usage.getByText("Total Cost", { exact: true })).toBeVisible()
      if (leave === "unmount") {
        await page.getByRole("tab", { name: "Review", exact: true }).click()
        await expect(usage).toHaveCount(0)
      }
      await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.targetID)}"]`).click()
      if (leave === "unmount") await page.getByRole("tab", { name: "Context", exact: true }).click()
      await expect(usage.getByText(fixture.expected.targetTitle, { exact: true })).toBeVisible()
      const totalCost = usage
        .locator("div")
        .filter({ has: page.getByText("Total Cost", { exact: true }) })
        .filter({ hasText: /^Total Cost\$7\.00$/ })
      await expect(totalCost).toBeVisible()
      const request = await familyRequest.promise
      const response = page.waitForResponse((response) => response.request() === request)
      family.resolve()
      await (await response).finished()
      // Keep Context mounted while checking that the delivered old snapshot was ignored.
      await expect(usage.getByText(fixture.expected.targetTitle, { exact: true })).toBeVisible()
      await expect(totalCost).toBeVisible()
      await expect(usage.getByText("Stale target title", { exact: true })).toHaveCount(0)
    } finally {
      family.resolve()
    }
  })
}

test("closing pending Usage keeps unknown sections until the panel unmounts", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1000 })
  await page.emulateMedia({ reducedMotion: "no-preference" })
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    sessions: fixture.sessions,
    provider: fixture.provider,
    pageMessages: (id) => ({ items: fixture.messages[id]?.slice(-2) ?? [] }),
  })
  await installStressSessionTabs(page)
  const gate = Promise.withResolvers<void>()
  await page.route("**/api/rpc/custom.subscriptions/list?*", async (route) => {
    await gate.promise
    await route.fulfill({ json: { output: { status: "unconfigured", accounts: [] } } })
  })
  await page.route("**/api/session?*", async (route) => {
    if (!new URL(route.request().url()).searchParams.has("parentID")) return route.fallback()
    await gate.promise
    await route.fallback()
  })
  try {
    await page.goto(stressSessionHref(fixture.targetID))
    const overview = page.locator('[data-slot="context-overview"]')
    const subagents = overview
      .locator("details")
      .filter({ has: page.locator("summary").filter({ hasText: /^Subagents/ }) })
    const subscriptions = overview
      .locator("section")
      .filter({ has: page.getByRole("heading", { name: "Subscriptions", exact: true }) })
    const pendingSections = subagents.or(subscriptions)
    await expect(subagents.getByRole("status")).toHaveCount(1)
    await expect(subscriptions.getByRole("status")).toHaveCount(1)
    await expect(pendingSections.getByRole("status")).toHaveCount(2)
    const toggle = page.getByRole("button", { name: "Toggle review", exact: true })
    await expect(toggle).toHaveAttribute("aria-expanded", "true")
    // Observe the real closing animation rather than sleeping or sampling after unmount.
    const closing = pendingSections.evaluateAll(
      (sections) =>
        new Promise<{ text: string; loading: number }[]>((resolve) => {
          const element = sections[0]?.closest('[data-slot="context-overview"]')
          if (!element) throw new Error("Missing pending Usage sections")
          const samples: { text: string; loading: number }[] = []
          const observer = new MutationObserver(() => {
            if (!element.isConnected) {
              observer.disconnect()
              resolve(samples)
              return
            }
            if (document.querySelector('[aria-controls="review-panel"]')?.getAttribute("aria-expanded") !== "false")
              return
            samples.push({
              text: element.textContent ?? "",
              loading: sections.reduce(
                (count, section) => count + section.querySelectorAll('[role="status"]').length,
                0,
              ),
            })
          })
          observer.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true })
        }),
    )
    await toggle.click()
    const samples = await closing
    expect(samples.length).toBeGreaterThan(0)
    for (const sample of samples) {
      expect(sample.loading).toBe(2)
      expect(sample.text).not.toContain("No subagents in this session yet.")
      expect(sample.text).not.toContain("Subscription usage is unavailable.")
      expect(sample.text).toContain("Subagents—")
    }
  } finally {
    gate.resolve()
  }
})

test("MCP catalog loads locally without presenting an empty catalog", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    sessions: fixture.sessions,
    provider: fixture.provider,
    pageMessages: (id) => ({ items: fixture.messages[id]?.slice(-2) ?? [] }),
  })
  await installStressSessionTabs(page)
  const gate = Promise.withResolvers<void>()
  const started = Promise.withResolvers<void>()
  await page.route(
    (url) => url.pathname === "/api/mcp",
    async (route) => {
      started.resolve()
      await gate.promise
      await route.fallback()
    },
  )
  try {
    await page.goto(stressSessionHref(fixture.targetID))
    await started.promise
    const tabs = page.getByRole("tablist", { name: "Session view", exact: true })
    await tabs.getByRole("tab", { name: "Usage", exact: true }).click()
    const usage = page.locator('[data-slot="session-usage-content"]')
    const mcp = usage.locator("details").filter({ has: page.locator("summary").filter({ hasText: /^MCP/ }) })
    await expect(usage.getByText("Total Cost", { exact: true })).toBeVisible()
    await expect(mcp.locator("summary")).toHaveText("MCP—")
    await expect(mcp.getByRole("status")).toContainText("Loading")
    await tabs.getByRole("tab", { name: "Session", exact: true }).click()
    await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeVisible()
    await tabs.getByRole("tab", { name: "Usage", exact: true }).click()
    gate.resolve()
    await expect(mcp.locator("summary")).toHaveText("MCP0/0")
    await expect(mcp.getByRole("status")).toHaveCount(0)
  } finally {
    gate.resolve()
  }
})
