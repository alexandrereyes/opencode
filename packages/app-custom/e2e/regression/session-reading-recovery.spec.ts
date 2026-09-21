import { expect, test, type Page } from "@playwright/test"
import type { SessionMessageInfo } from "@opencode/client/promise"
import { base64Encode } from "@opencode/util/encode"
import { pressPlatformShortcut } from "../utils/command-palette"
import { mockOpenCodeServer } from "../utils/mock-server"
import { installSseTransport } from "../utils/sse-transport"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"

const sourceID = fixture.sourceID
const targetID = fixture.targetID
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const viewportSelector = '[data-slot="session-timeline-scroll"] .scroll-view__viewport'
const deepID = "msg_reading_004_assistant"
const text = (count: number) =>
  Array.from(
    { length: count },
    (_, i) =>
      `Paragraph ${i}. A substantial reading passage with enough words to wrap differently when the available transcript width changes. This paragraph keeps its content while its measured height changes.`,
  ).join("\n\n")
const messages: SessionMessageInfo[] = Array.from({ length: 20 }, (_, i) => {
  const prefix = `msg_reading_${String(i).padStart(3, "0")}`
  return [
    { id: `${prefix}_user`, type: "user", text: `Reading prompt ${i}`, time: { created: 1000 + i * 2 } },
    {
      id: `${prefix}_assistant`,
      type: "assistant",
      agent: "build",
      model: { providerID: "opencode", id: "claude-opus-4-6" },
      metadata: { parentID: `${prefix}_user` },
      time: { created: 1001 + i * 2 },
      content: [{ type: "text", text: i === 4 ? text(100) : `Reading answer ${i}` }],
    },
  ] satisfies SessionMessageInfo[]
}).flat()

test.use({ viewport: { width: 1440, height: 900 }, serviceWorkers: "block" })

for (const count of [1, 18]) {
  test(`restores a deep intrarow offset after ${count} session visits and width changes`, async ({ page }) => {
    const extra = Array.from({ length: count }, (_, i) => ({
      ...fixture.sessions[1]!,
      id: `ses_reading_evict_${i}`,
      title: `Eviction session ${i}`,
    }))
    await setup(page, { extra })
    await readDeep(page)
    const before = await deepGeometry(page)
    expect(before.offset).toBeGreaterThan(1400)
    const original = await page.locator("[data-timeline-virtual-content]").elementHandle()
    for (const session of extra) {
      await navigate(page, session.id)
      await expect(page.getByText(`Small answer ${session.id}`, { exact: true })).toBeVisible()
    }
    await page.setViewportSize({ width: 600, height: 800 })
    await navigate(page, sourceID)
    await expect.poll(async () => Math.abs((await deepGeometry(page)).offset - before.offset)).toBeLessThan(3)
    expect(await original!.evaluate((el) => el.isConnected)).toBe(count === 1)
    await expect.poll(async () => (await deepGeometry(page)).height).not.toBe(before.height)
    await expect.poll(async () => Math.abs((await deepGeometry(page)).offset - before.offset)).toBeLessThan(3)
    await expect(page.locator("[data-timeline-virtual-content]")).toHaveCount(1)
  })
}

for (const pinned of [true, false]) {
  test(`inactive streaming returns to ${pinned ? "the new tail" : "the historical anchor"}`, async ({ page }) => {
    const transport = await setup(page)
    if (!pinned) await readDeep(page)
    const before = pinned ? undefined : await deepGeometry(page)
    await navigate(page, targetID)
    await expect(page.getByText(`Small answer ${targetID}`, { exact: true })).toBeVisible()
    await transport.send({
      id: "evt_reading_append",
      type: "session.text.ended",
      created: 4000,
      durable: { aggregateID: sourceID, seq: 1, version: 1 },
      data: {
        sessionID: sourceID,
        assistantMessageID: "msg_reading_019_assistant",
        ordinal: 0,
        text: `${text(70)}\n\nInactive stream final marker`,
      },
    })
    await navigate(page, sourceID)
    if (pinned) {
      await expect(page.getByText("Inactive stream final marker", { exact: true })).toBeInViewport()
      await expect.poll(() => distanceFromEnd(page)).toBeLessThan(2)
      return
    }
    await expect.poll(async () => Math.abs((await deepGeometry(page)).offset - before!.offset)).toBeLessThan(3)
    await page.getByRole("button", { name: "Jump to latest", exact: true }).click()
    await expect(page.getByText("Inactive stream final marker", { exact: true })).toBeInViewport()
  })
}

for (const cancel of [false, true]) {
  test(`${cancel ? "gesture cancels" : "recovers"} a bookmark after reconnect replaces history with the latest page`, async ({
    page,
  }) => {
    const state = { recent: false, pages: 0 }
    const requested = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const transport = await setup(page, {
      pageMessages: (id, limit, before) => {
        if (id !== sourceID) return { items: small(id) }
        if (!state.recent) return { items: messages }
        const end = before ? messages.findIndex((m) => m.id === before) : messages.length
        const start = Math.max(0, end - Math.min(limit, 8))
        if (before) state.pages += 1
        return { items: messages.slice(start, end), cursor: start > 0 ? messages[start]!.id : undefined }
      },
      beforeMessagesResponse: async ({ sessionID, before }) => {
        if (sessionID !== sourceID || !before || !state.recent || !cancel) return
        requested.resolve()
        await release.promise
      },
    })
    await readDeep(page)
    const before = await deepGeometry(page)
    await navigate(page, targetID)
    await expect(page.getByText(`Small answer ${targetID}`, { exact: true })).toBeVisible()
    state.recent = true
    const connection = await transport.waitForConnection()
    await transport.disconnect()
    await transport.waitForConnection({ after: connection.id })
    const latest = page.waitForResponse(
      (response) =>
        response.url().includes(`/api/session/${sourceID}/message?`) &&
        !new URL(response.url()).searchParams.has("cursor") &&
        !new URL(response.url()).searchParams.has("type"),
    )
    await navigate(page, sourceID)
    await latest
    if (cancel) {
      await requested.promise
      const viewport = page.locator(viewportSelector)
      await viewport.hover()
      await page.mouse.wheel(0, 100000)
      await expect.poll(() => distanceFromEnd(page)).toBeLessThan(2)
      release.resolve()
      await expect(page.getByText("Reading answer 19", { exact: true })).toBeInViewport()
      await expect.poll(() => distanceFromEnd(page)).toBeLessThan(2)
      await expect.poll(() => state.pages).toBe(1)
      return
    }
    await expect.poll(async () => Math.abs((await deepGeometry(page)).offset - before.offset)).toBeLessThan(3)
    expect(state.pages).toBeGreaterThan(1)
  })
}

for (const gesture of ["wheel", "selection"]) {
  test(`a ${gesture} in a short session still follows content when it later grows`, async ({ page }) => {
    const transport = await setup(page)
    await navigate(page, targetID)
    const answer = page.getByText(`Small answer ${targetID}`, { exact: true })
    await expect(answer).toBeVisible()
    await expect
      .poll(() => page.locator(viewportSelector).evaluate((el) => el.scrollHeight - el.clientHeight))
      .toBeLessThan(2)
    if (gesture === "wheel") {
      await page.locator(viewportSelector).hover()
      await page.mouse.wheel(0, -100)
    } else {
      await answer.evaluate((el) => {
        const range = document.createRange()
        range.selectNodeContents(el)
        window.getSelection()?.removeAllRanges()
        window.getSelection()?.addRange(range)
        el.dispatchEvent(new MouseEvent("click", { bubbles: true }))
      })
    }
    await transport.send({
      id: `evt_short_${gesture}`,
      type: "session.text.ended",
      created: 4000,
      durable: { aggregateID: targetID, seq: 1, version: 1 },
      data: {
        sessionID: targetID,
        assistantMessageID: `msg_${targetID}_assistant`,
        ordinal: 0,
        text: `${text(70)}\n\nShort session grew to this marker`,
      },
    })
    await expect(page.getByText("Short session grew to this marker", { exact: true })).toBeInViewport()
    await expect.poll(() => distanceFromEnd(page)).toBeLessThan(2)
  })
}

test("uses the loaded owning message when the saved row disappears without reading older pages", async ({ page }) => {
  const state = { pages: 0 }
  const transport = await setup(page, {
    pageMessages: (id, _limit, before) => {
      if (id !== sourceID) return { items: small(id) }
      if (before) {
        state.pages += 1
        return { items: messages.slice(0, 4) }
      }
      return {
        items: [
          ...Array.from({ length: 20 }, (_, i) => ({
            id: `msg_before_reading_${i}`,
            type: "user" as const,
            text: `Earlier prompt ${i}`,
            time: { created: i },
          })),
          ...messages,
        ],
        cursor: "earlier-page",
      }
    },
  })
  await readDeep(page)
  await navigate(page, targetID)
  await expect(page.getByText(`Small answer ${targetID}`, { exact: true })).toBeVisible()
  await transport.send({
    id: "evt_removed_reading_row",
    type: "session.text.ended",
    created: 4000,
    durable: { aggregateID: sourceID, seq: 1, version: 1 },
    data: { sessionID: sourceID, assistantMessageID: deepID, ordinal: 0, text: "" },
  })
  await navigate(page, sourceID)
  await expect(page.locator("#message-msg_reading_004_user")).toBeInViewport()
  await expect(page.locator(`[data-timeline-part-id="${deepID}:text:0"]`)).toHaveCount(0)
  expect(state.pages).toBe(0)
})

function small(id: string): SessionMessageInfo[] {
  return [
    { id: `msg_${id}_user`, type: "user", text: `Small prompt ${id}`, time: { created: 1 } },
    {
      id: `msg_${id}_assistant`,
      type: "assistant",
      agent: "build",
      model: { providerID: "opencode", id: "claude-opus-4-6" },
      metadata: { parentID: `msg_${id}_user` },
      time: { created: 2 },
      content: [{ type: "text", text: `Small answer ${id}` }],
    },
  ]
}

test("pending message intent wins before the cold timeline's follow effects run", async ({ page }) => {
  await setup(page, { pending: "msg_reading_004_user" })
  await expect(page.locator("#message-msg_reading_004_user")).toBeInViewport()
  await expect(page).toHaveURL(/#message-msg_reading_004_user$/)
  await expect.poll(() => distanceFromEnd(page)).toBeGreaterThan(5000)
})

test("manual arrival at the end clears a message hash and resumes streaming", async ({ page }) => {
  const transport = await setup(page)
  await readDeep(page)
  await expect(page).toHaveURL(/#message-msg_reading_004_user$/)
  await page.locator(viewportSelector).hover()
  await page.mouse.wheel(0, 100000)
  await expect.poll(() => distanceFromEnd(page)).toBeLessThan(2)
  await expect(page).not.toHaveURL(/#message-/)
  await transport.send({
    id: "evt_hash_manual_end",
    type: "session.text.ended",
    created: 4000,
    durable: { aggregateID: sourceID, seq: 1, version: 1 },
    data: {
      sessionID: sourceID,
      assistantMessageID: "msg_reading_019_assistant",
      ordinal: 0,
      text: `${text(70)}\n\nManual end resumed marker`,
    },
  })
  await expect(page.getByText("Manual end resumed marker", { exact: true })).toBeInViewport()
  await expect.poll(() => distanceFromEnd(page)).toBeLessThan(2)
})

test("search pauses following and manual arrival at the end resumes it with the query open", async ({ page }) => {
  const transport = await setup(page)
  await pressPlatformShortcut(page, "F")
  const search = page.locator('[data-component="timeline-search-bar"] input')
  await search.fill("Paragraph 50.")
  await expect(page.locator(`[data-timeline-part-id="${deepID}:text:0"]`)).toBeVisible()
  await expect.poll(() => distanceFromEnd(page)).toBeGreaterThan(1000)
  const before = await deepGeometry(page)
  const send = (id: string, marker: string) =>
    transport.send({
      id,
      type: "session.text.ended",
      created: 4000,
      durable: { aggregateID: sourceID, seq: 1, version: 1 },
      data: {
        sessionID: sourceID,
        assistantMessageID: "msg_reading_019_assistant",
        ordinal: 0,
        text: `${text(70)}\n\n${marker}`,
      },
    })
  await send("evt_search_paused", "Search paused marker")
  await expect.poll(async () => Math.abs((await deepGeometry(page)).offset - before.offset)).toBeLessThan(3)
  await page.locator(viewportSelector).hover()
  await page.mouse.wheel(0, 100000)
  await expect(page.getByText("Search paused marker", { exact: true })).toBeInViewport()
  await expect.poll(() => distanceFromEnd(page)).toBeLessThan(2)
  await send("evt_search_resumed", "Search resumed marker")
  await expect(page.getByText("Search resumed marker", { exact: true })).toBeInViewport()
  await expect(search).toHaveValue("Paragraph 50.")
  await expect.poll(() => distanceFromEnd(page)).toBeLessThan(2)
})

async function setup(
  page: Page,
  input: {
    pending?: string
    extra?: typeof fixture.sessions
    pageMessages?: Parameters<typeof mockOpenCodeServer>[1]["pageMessages"]
    beforeMessagesResponse?: Parameters<typeof mockOpenCodeServer>[1]["beforeMessagesResponse"]
  } = {},
) {
  const transport = await installSseTransport(page, { server })
  await mockOpenCodeServer(page, {
    ...fixture,
    sessions: [...fixture.sessions, ...(input.extra ?? [])],
    pageMessages: input.pageMessages ?? ((id) => ({ items: id === sourceID ? messages : small(id) })),
    beforeMessagesResponse: input.beforeMessagesResponse,
  })
  await installStressSessionTabs(page)
  if (input.pending)
    await page.addInitScript(
      ({ key, pending }) =>
        localStorage.setItem(
          "opencode.global.dat:layout",
          JSON.stringify({
            sessionView: { [key]: { scroll: {}, pendingMessage: pending, pendingMessageAt: Date.now() } },
          }),
        ),
      { key: `local\0${base64Encode(fixture.directory)}/${sourceID}`, pending: input.pending },
    )
  await page.route(
    (url) => url.pathname.endsWith("/message") && url.searchParams.has("type"),
    (route) => route.fulfill({ json: { data: [], cursor: {} } }),
  )
  await page.goto(stressSessionHref(sourceID))
  if (input.pending) await expect(page.locator(`#message-${input.pending}`)).toBeInViewport()
  else {
    await expect(page.getByText("Reading answer 19", { exact: true })).toBeInViewport()
    await expect.poll(() => distanceFromEnd(page)).toBeLessThan(2)
  }
  await transport.waitForConnection()
  return transport
}

async function navigate(page: Page, id: string, hash = "") {
  await page.evaluate(
    (href) => {
      const link = document.querySelector<HTMLAnchorElement>("[data-reading-navigation]") ?? document.createElement("a")
      link.dataset.readingNavigation = ""
      link.textContent = "Reading test navigation"
      link.href = href
      link.style.cssText = "position:fixed;top:0;right:0;z-index:99999;background:white"
      if (!link.isConnected) document.body.append(link)
    },
    `${stressSessionHref(id)}${hash}`,
  )
  await page.getByRole("link", { name: "Reading test navigation", exact: true }).click()
}

async function readDeep(page: Page) {
  const viewport = page.locator(viewportSelector)
  await navigate(page, sourceID, "#message-msg_reading_004_user")
  const part = page.locator(`[data-timeline-part-id="${deepID}:text:0"]`)
  await expect(part.locator('[data-component="markdown"][data-markdown-ready]')).toBeVisible()
  await expect
    .poll(() =>
      part.evaluate((el) => {
        const row = el.closest<HTMLElement>("[data-timeline-key]")!
        return Math.abs(row.offsetHeight - row.firstElementChild!.getBoundingClientRect().height)
      }),
    )
    .toBeLessThan(1)
  await part.hover({ position: { x: 100, y: 100 } })
  await viewport.dispatchEvent("wheel", { deltaY: -1 })
  await part.evaluate((el) => {
    const root = el.closest<HTMLElement>(".scroll-view__viewport")!
    const row = el.closest<HTMLElement>("[data-timeline-key]")!
    root.scrollTop += row.getBoundingClientRect().top - root.getBoundingClientRect().top + 1500
  })
  await expect.poll(async () => Math.abs((await deepGeometry(page)).offset - 1500)).toBeLessThan(2)
}

async function deepGeometry(page: Page) {
  return page.locator(viewportSelector).evaluate((root, id) => {
    const part = root.querySelector<HTMLElement>(`[data-timeline-part-id="${id}:text:0"]`)
    const row = part?.closest<HTMLElement>("[data-timeline-key]")
    if (!row) return { offset: -100000, height: 0 }
    return {
      offset: root.getBoundingClientRect().top - row.getBoundingClientRect().top,
      height: row.getBoundingClientRect().height,
    }
  }, deepID)
}

async function distanceFromEnd(page: Page) {
  return page.locator(viewportSelector).evaluate((el) => el.scrollHeight - el.clientHeight - el.scrollTop)
}
