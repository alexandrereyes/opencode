import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { fixture } from "../smoke/session-timeline.fixture"
import { mockOpenCodeServer } from "../utils/mock-server"

test.use({ viewport: { width: 393, height: 852 }, isMobile: true, hasTouch: true })

for (const underfilled of [false, true]) {
  test(`mobile history: loads the final page ${underfilled ? "from an underfilled viewport" : "without moving the visible message"}`, async ({
    page,
  }) => {
    const messages = fixture.messages[fixture.sourceID].map((message, index, all) => {
      if (!underfilled || index < all.length - 2) return message
      if (message.type === "user") return { ...message, text: "Recent prompt" }
      if (message.type === "assistant")
        return { ...message, content: [{ type: "text" as const, text: "Recent answer" }] }
      return message
    })
    const initial = underfilled ? messages.slice(-2) : messages.slice(1)
    const release = Promise.withResolvers<void>()
    const requests: string[] = []
    page.on("request", (request) => {
      const url = new URL(request.url())
      if (!url.pathname.endsWith("/message") || url.searchParams.has("type")) return
      if (url.searchParams.has("cursor")) requests.push(request.url())
    })
    await mockOpenCodeServer(page, {
      directory: fixture.directory,
      project: fixture.project,
      provider: fixture.provider,
      sessions: fixture.sessions.filter((session) => session.id === fixture.sourceID),
      pageMessages: (_sessionID, _limit, before) =>
        before
          ? { items: messages.slice(0, messages.length - initial.length) }
          : { items: initial, cursor: initial[0].id },
      beforeMessagesResponse: ({ before }) => (before ? release.promise : Promise.resolve()),
    })
    // Location-history queries are independent of transcript pagination.
    await page.route(
      (url) => url.pathname.endsWith("/message") && url.searchParams.has("type"),
      (route) => route.fulfill({ json: { data: [], cursor: {} } }),
    )
    await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${fixture.sourceID}`)
    await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeEditable()
    const scroller = page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport')
    const button = scroller.getByRole("button", { name: "Load earlier messages", exact: true })
    await expect(button).toBeEnabled()
    await expect(scroller.locator("[data-timeline-virtual-content]")).toHaveCSS("visibility", "visible")
    if (underfilled) {
      await expect.poll(() => scroller.evaluate((element) => element.scrollHeight - element.clientHeight)).toBe(0)
    }
    await scroller.dispatchEvent("touchstart", { touches: [{ identifier: 1, clientX: 100, clientY: 100 }] })
    await scroller.dispatchEvent("touchmove", { touches: [{ identifier: 1, clientX: 100, clientY: 200 }] })
    await scroller.evaluate((element) => {
      element.scrollTop = 0
    })
    await scroller.dispatchEvent("touchend", { touches: [] })
    await expect(button).toBeInViewport()
    await expect.poll(() => scroller.evaluate((element) => element.scrollTop)).toBe(0)
    expect(requests).toHaveLength(0)

    try {
      await button.tap()
      await expect(scroller.getByRole("button", { name: "Loading earlier messages…", exact: true })).toBeDisabled()
      await expect.poll(() => requests.length).toBe(1)
      const message = initial.find((message) => message.type === "assistant")!
      const anchor = scroller.locator(`[data-timeline-part-id="${message.id}:text:0"]`)
      await expect(anchor).toBeInViewport()
      await expect(scroller.locator('[data-markdown-key="initial"]')).toHaveCount(0)
      const before = await anchor.evaluate((element) => element.getBoundingClientRect().top)
      const slack = await scroller.evaluate((element) => {
        const bottom = element.querySelector('[data-timeline-row="bottom-spacer"]')!.getBoundingClientRect().bottom
        return Math.max(0, element.getBoundingClientRect().bottom - bottom)
      })
      release.resolve()
      await expect(scroller.getByRole("button", { name: /earlier messages/ })).toHaveCount(0)
      await expect(scroller.locator('[data-markdown-key="initial"]')).toHaveCount(0)
      // An initially underfilled list must clamp to its new end. Only the former empty space
      // may displace the anchor; later row measurements must not introduce another jump.
      await expect
        .poll(async () =>
          Math.abs((await anchor.evaluate((element) => element.getBoundingClientRect().top)) - before - slack),
        )
        .toBeLessThanOrEqual(1)
      expect(requests).toHaveLength(1)
    } finally {
      release.resolve()
    }
  })
}
