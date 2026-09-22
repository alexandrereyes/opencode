import { expect, test } from "@playwright/test"
import type { OpenCodeEvent } from "@opencode/client/promise"
import { fixture } from "../smoke/session-timeline.fixture"
import { mockOpenCodeServer } from "../utils/mock-server"

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

test("mobile chat subtitles survive navigation updates while chat RPC is pending and follow directory moves", async ({
  page,
}) => {
  const root = "/data/chats"
  const session = {
    ...fixture.sessions[0],
    directory: `${root}/chat-subtitle`,
    title: "Mobile chat",
    time: { created: Date.now(), updated: Date.now() },
  }
  const events: OpenCodeEvent[] = []
  const request = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  const rpc = { hold: false }
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    provider: fixture.provider,
    sessions: [session],
    pageMessages: () => ({ items: [] }),
    events: () => events.splice(0),
  })
  await page.route("**/api/rpc/custom.chats/info", async (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback()
    if (rpc.hold) {
      request.resolve()
      await release.promise
    }
    await route.fulfill({ json: { output: { root } }, headers: { "access-control-allow-origin": "*" } })
  })
  // No open session tab: the mobile drawer builds this item from the navigation index.
  await page.goto("/")
  await expect(page.locator('[data-component="home-session-row"]').filter({ hasText: session.title })).toBeVisible()
  await page.getByRole("button", { name: "Tabs", exact: true }).tap()
  const drawer = page.locator('[data-slot="mobile-tabs-drawer"]')
  const row = drawer.locator("[data-titlebar-tab]")
  await expect(row.locator("[data-titlebar-tab-title]")).toHaveText(session.title)
  await expect(row.locator('[data-slot="tab-project"]')).toHaveText("Chats")
  rpc.hold = true

  for (const seq of [1, 2, 3]) {
    session.title = `Mobile chat update ${seq}`
    events.push({
      id: `evt_chat_subtitle_${seq}`,
      created: seq,
      type: "session.renamed",
      durable: { aggregateID: session.id, seq, version: 1 },
      data: { sessionID: session.id, title: session.title },
    })
    await expect(row.locator("[data-titlebar-tab-title]")).toHaveText(session.title)
    await request.promise
    await expect(row.locator('[data-slot="tab-project"]')).toHaveText("Chats")
  }

  session.directory = fixture.directory
  events.push({
    id: "evt_chat_subtitle_moved",
    created: 4,
    type: "session.moved",
    durable: { aggregateID: session.id, seq: 4, version: 1 },
    data: { sessionID: session.id, location: { directory: session.directory }, projectID: fixture.project.id },
  })
  await expect(row.locator('[data-slot="tab-project"]')).toHaveText("SmokeProject · main")
  const response = page.waitForResponse("**/api/rpc/custom.chats/info")
  release.resolve()
  await response
  await expect(row.locator('[data-slot="tab-project"]')).toHaveText("SmokeProject · main")
})
