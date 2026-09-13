import { expect, test } from "@playwright/test"
import type { ModelInfo, OpenCodeEvent, SessionMessageInfo } from "@opencode/client/promise"
import { mockOpenCodeServer } from "../utils/mock-server"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"

test("subagent context uses bounded measurements, stays local while pending, and revalidates cached children", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1440, height: 1000 })
  const events: OpenCodeEvent[] = []
  const secondID = "ses_context_second"
  const secondDirectory = "C:/OpenCode/ChildProject"
  const sessions = [
    ...fixture.sessions.map((session) =>
      session.id === fixture.childID
        ? { ...session, agent: "solmedium", cost: 1.25, tokens: tokens(986_800) }
        : { ...session },
    ),
    {
      ...fixture.sessions[2],
      id: secondID,
      directory: secondDirectory,
      title: "Second context worker",
      agent: "astra",
      cost: 0.5,
    },
  ]
  const large: ModelInfo = {
    id: "context-large",
    modelID: "context-large",
    providerID: "opencode",
    name: "Context large",
    capabilities: { tools: true, input: ["text"], output: ["text"] },
    variants: [{ id: "medium" }],
    time: { released: 0 },
    cost: [],
    status: "active",
    enabled: true,
    limit: { context: 1_048_576, output: 32_000 },
  }
  const small: ModelInfo = {
    ...large,
    id: "context-small",
    modelID: "context-small",
    limit: { context: 100_000, output: 8_000 },
  }
  const messages: Record<string, SessionMessageInfo[]> = {
    [fixture.childID]: [
      assistant("msg_context_001", 1, 900_000, large),
      assistant("msg_context_002", 2, 86_800, large),
    ],
    [secondID]: [assistant("msg_second_001", 1, 25_000, small)],
  }
  await mockOpenCodeServer(page, {
    sessions,
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages: (id) => ({ items: messages[id] ?? fixture.messages[id]?.slice(-2) ?? [] }),
    events: () => events.splice(0),
  })
  const pending = Promise.withResolvers<void>()
  const requested = Promise.withResolvers<void>()
  const state = { hold: true, fail: false }
  const calls: string[] = []
  await page.route("**/api/session/*/message?*", async (route) => {
    const url = new URL(route.request().url())
    const id = url.pathname.split("/")[3]
    if (url.searchParams.get("type") !== "assistant") return route.fallback()
    expect([fixture.childID, secondID]).toContain(id)
    expect(url.searchParams.get("order")).toBe("desc")
    expect(Number(url.searchParams.get("limit"))).toBeGreaterThan(0)
    expect(Number(url.searchParams.get("limit"))).toBeLessThanOrEqual(20)
    expect(url.searchParams.has("cursor")).toBe(false)
    calls.push(id)
    if (id === fixture.childID && state.hold) {
      requested.resolve()
      await pending.promise
    }
    if (id === fixture.childID && state.fail) return route.fulfill({ status: 500, body: "unavailable" })
    return route.fulfill({ json: { data: messages[id].toReversed(), cursor: {} } })
  })
  await page.route("**/api/model?*", (route) => {
    const directory = new URL(route.request().url()).searchParams.get("location[directory]") ?? fixture.directory
    return route.fulfill({
      json: {
        location: { directory, project: { id: fixture.project.id, directory, canonical: directory } },
        data: directory === secondDirectory ? [small] : [large],
      },
    })
  })
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  await requested.promise
  const overview = page.locator('[data-slot="context-overview"]')
  const first = overview.getByRole("link", { name: /Inspect child navigation/ })
  const second = overview.getByRole("link", { name: /Second context worker/ })
  const firstMeta = first.locator('[data-slot="subagent-context"]')
  const secondMeta = second.locator('[data-slot="subagent-context"]')
  await expect(page.getByRole("tab", { name: "Context", exact: true })).toHaveAttribute("aria-selected", "true")
  await expect(overview.getByRole("region", { name: "Session", exact: true })).toBeVisible()
  await expect(firstMeta).toHaveText("solmedium—")
  await expect(secondMeta).toHaveText("astra25K (25%)")
  state.hold = false
  pending.resolve()
  await expect(firstMeta).toHaveText("solmedium86.8K (8.3%)")
  await expect(first.locator('[data-component="progress-circle"][data-appearance="indicator"]')).toHaveCount(1)
  await expect(first.getByRole("button")).toHaveCount(0)
  await expect(first).toHaveAttribute("href", stressSessionHref(fixture.childID))
  await expect(first).toContainText("$1.25")

  // Started carries no tokens in both Core and the data-client projection.
  const started: OpenCodeEvent = {
    id: "evt_context_started",
    created: 3,
    type: "session.step.started",
    durable: { aggregateID: fixture.childID, seq: 1, version: 1 },
    data: {
      sessionID: fixture.childID,
      assistantMessageID: "msg_context_003",
      agent: "solmedium",
      model: { providerID: large.providerID, id: large.id },
    },
  }
  const callsBeforeLive = calls.length
  events.push(started, {
    id: "evt_context_running",
    created: 3,
    type: "session.execution.started",
    durable: { aggregateID: fixture.childID, seq: 2, version: 1 },
    data: { sessionID: fixture.childID },
  })
  await expect(first).toContainText("Running")
  await expect(firstMeta).toHaveText("solmedium86.8K (8.3%)")
  messages[fixture.childID].push(assistant("msg_context_003", 3, 5_800, large))
  events.push({
    id: "evt_context_ended",
    created: 4,
    type: "session.step.ended",
    durable: { aggregateID: fixture.childID, seq: 3, version: 1 },
    data: {
      sessionID: fixture.childID,
      assistantMessageID: "msg_context_003",
      finish: "stop",
      cost: 0,
      tokens: tokens(5_800),
    },
  })
  await expect(firstMeta).toHaveText("solmedium5.8K (0.6%)")
  await expect(secondMeta).toHaveText("astra25K (25%)")
  expect(calls.length).toBe(callsBeforeLive)

  // A restored page reconnects with the old child measurement still in cache.
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pagehide")))
  messages[fixture.childID].push(assistant("msg_context_004", 5, 30_000, large))
  const reconnected = page.waitForResponse(
    (response) =>
      response.url().includes(`/api/session/${fixture.childID}/message?`) && response.url().includes("type=assistant"),
  )
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pageshow")))
  await reconnected
  await expect(firstMeta).toHaveText("solmedium30K (2.9%)")

  // Reopening must revalidate even though the ended event populated the shared cache.
  await page.getByRole("tab", { name: "Review", exact: true }).click()
  await expect(overview).toBeHidden()
  messages[fixture.childID].push(assistant("msg_context_005", 6, 40_000, large))
  const revalidated = page.waitForResponse(
    (response) =>
      response.url().includes(`/api/session/${fixture.childID}/message?`) && response.url().includes("type=assistant"),
  )
  await page.getByRole("tab", { name: "Context", exact: true }).click()
  await revalidated
  await expect(firstMeta).toHaveText("solmedium40K (3.8%)")

  // Revert removes a snapshot-only measurement, not merely a cached message.
  messages[fixture.childID] = messages[fixture.childID].filter((message) => message.id < "msg_context_003")
  events.push({
    id: "evt_context_reverted",
    created: 6,
    type: "session.revert.committed",
    durable: { aggregateID: fixture.childID, seq: 4, version: 1 },
    data: { sessionID: fixture.childID, to: "msg_context_003" },
  })
  await expect(firstMeta).toHaveText("solmedium86.8K (8.3%)")
  await expect(secondMeta).toHaveText("astra25K (25%)")
  state.fail = true
  const failed = page.waitForResponse(
    (response) => response.url().includes(`/api/session/${fixture.childID}/message?`) && response.status() === 500,
  )
  events.push({
    id: "evt_context_uncached_end",
    created: 7,
    type: "session.step.ended",
    durable: { aggregateID: fixture.childID, seq: 5, version: 1 },
    data: {
      sessionID: fixture.childID,
      assistantMessageID: "msg_context_missing",
      finish: "stop",
      cost: 0,
      tokens: tokens(10_000),
    },
  })
  await failed
  await expect(firstMeta).toHaveText("solmedium86.8K (8.3%)")
  await expect(overview.getByRole("region", { name: "Session", exact: true })).toBeVisible()
  if (process.env.SUBAGENT_CONTEXT_SCREENSHOT)
    await page.screenshot({ path: testInfo.outputPath("subagent-context.png") })
  state.fail = false
  await page.setViewportSize({ width: 390, height: 844 })
  await page.getByRole("tab", { name: "Usage", exact: true }).click()
  await expect(firstMeta).toHaveText("solmedium86.8K (8.3%)")
  await expect(secondMeta).toHaveText("astra25K (25%)")
  expect(await overview.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true)
  if (process.env.SUBAGENT_CONTEXT_SCREENSHOT)
    await page.screenshot({ path: testInfo.outputPath("subagent-context-mobile.png") })
  await first.click()
  await expect(page).toHaveURL(new RegExp(`${fixture.childID}$`))
})

function tokens(input: number) {
  return { input, output: 0, reasoning: 0, cache: { read: 0, write: 0 } }
}

function assistant(id: string, created: number, input: number, model: ModelInfo): SessionMessageInfo {
  return {
    id,
    type: "assistant",
    agent: "solmedium",
    model: { providerID: model.providerID, id: model.id, variant: "medium" },
    time: { created, completed: created },
    content: [],
    tokens: tokens(input),
  }
}
