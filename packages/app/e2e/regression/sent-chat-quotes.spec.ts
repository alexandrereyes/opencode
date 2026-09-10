import type { SessionMessageUser } from "@opencode/client/promise"
import { expect, test } from "@playwright/test"
import { formatChatQuotes } from "../../src/composer/chat-quote"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { mockOpenCodeServer } from "../utils/mock-server"

test.use({ serviceWorkers: "block", permissions: ["clipboard-read", "clipboard-write"] })

const longQuote = {
  id: "quote_long",
  messageID: "msg_original",
  partID: "msg_original:text:0",
  text: [
    "Keep the complete connection string in the deployment configuration.",
    "Use the same database settings for the application and the worker.",
    "Check that the service can resolve the database hostname.",
    "A password containing special characters must be URL-encoded.",
    "Do not wrap the value in an extra pair of external quotes.",
    "Restart the deployment only after verifying the configuration.",
  ].join("\n"),
  comment: "Could you explain how to verify this before deploying?",
}
const shortQuote = { ...longQuote, id: "quote_short", text: "Check the deployment configuration.", comment: "" }

for (const variant of [
  { width: 1440, scheme: "dark" as const },
  { width: 390, scheme: "light" as const },
]) {
  for (const scenario of ["with-text", "quote-only", "multiple"]) {
    test(`sent quotes ${scenario} ${variant.width}px ${variant.scheme}`, async ({ page }, info) => {
      await page.setViewportSize({ width: variant.width, height: 900 })
      await page.emulateMedia({ colorScheme: variant.scheme })
      const session = { ...fixture.sessions[0], id: "ses_sent_quotes" }
      const quotes = scenario === "multiple" ? [longQuote, shortQuote] : [longQuote]
      const displayText = scenario === "with-text" ? "Please clarify this deployment advice." : ""
      const message: SessionMessageUser = {
        id: "msg_sent_quotes",
        type: "user",
        time: { created: 1700000000000 },
        text: [displayText, formatChatQuotes(quotes)].filter(Boolean).join("\n\n"),
        metadata: { displayText, comments: [], quotes },
      }
      const reverted: string[] = []
      await mockOpenCodeServer(page, {
        ...fixture,
        sessions: [session],
        pageMessages: () => ({ items: [message] }),
        message: () => message,
        onRevertStage: ({ messageID }) => reverted.push(messageID),
      })
      await page.goto(stressSessionHref(session.id))
      const bubble = page.locator('[data-component="user-message"]')
      const quote = bubble.locator('[data-component="user-message-quote"]').filter({ hasText: longQuote.comment })
      const excerpt = quote.getByRole("blockquote")
      const expand = quote.getByRole("button", { name: "Expand quote", exact: true })
      await expect(bubble.locator('[data-slot="user-message-text"]')).toBeVisible()
      await expect(bubble.getByText("Quoted from an earlier message", { exact: true })).toHaveCount(quotes.length)
      await expect(excerpt).toHaveText(longQuote.text)
      await expect(excerpt).toHaveCSS("-webkit-line-clamp", "4")
      await expect(excerpt).toHaveCSS("line-height", "20px")
      await expect.poll(() => excerpt.evaluate((element) => element.clientHeight)).toBe(80)
      await expect(quote.getByText(longQuote.comment, { exact: true })).toBeVisible()
      await expect(bubble).not.toContainText("Comments on earlier assistant messages:")
      await expect(bubble).not.toContainText("msg_original")
      await expect(bubble).not.toContainText("User comment:")
      await expect(bubble.locator('[data-slot="user-message-draft"]')).toHaveCount(displayText ? 1 : 0)
      if (displayText) await expect(bubble.getByText(displayText, { exact: true })).toBeVisible()
      if (scenario === "multiple") {
        const short = bubble.locator('[data-component="user-message-quote"]').filter({ hasText: shortQuote.text })
        await expect(short.getByRole("button")).toHaveCount(0)
        await expect(short.locator('[data-slot="user-message-quote-comment"]')).toHaveCount(0)
      }
      await expect(expand).toHaveAttribute("aria-expanded", "false")
      await expect(excerpt).toHaveId((await expand.getAttribute("aria-controls"))!)
      await page.screenshot({ path: info.outputPath(`sent-quotes-${scenario}-${variant.width}-${variant.scheme}.png`) })
      await expand.focus()
      await expand.press("Enter")
      const collapse = quote.getByRole("button", { name: "Collapse quote", exact: true })
      await expect(collapse).toHaveAttribute("aria-expanded", "true")
      await expect(excerpt).toHaveCSS("-webkit-line-clamp", "none")
      await expect.poll(() => excerpt.evaluate((element) => element.clientHeight > 80)).toBe(true)
      await expect(quote.getByText(longQuote.comment, { exact: true })).toBeVisible()
      await page.screenshot({ path: info.outputPath(`sent-quotes-expanded-${scenario}-${variant.width}.png`) })
      await collapse.press("Space")
      await expect(expand).toHaveAttribute("aria-expanded", "false")
      await bubble.hover()
      await bubble.getByRole("button", { name: "Copy message", exact: true }).click()
      await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(message.text)
      await expect.poll(() => bubble.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true)
      await bubble.getByRole("button", { name: "Revert message", exact: true }).click()
      await expect.poll(() => reverted).toEqual([message.id])
      const composerQuotes = page.locator('[data-component="chat-quotes"]')
      await expect(
        composerQuotes.getByRole("button", { name: `Chat quotes · ${quotes.length}`, exact: true }),
      ).toBeVisible()
    })
  }
}

test("retains quote disclosure through virtual remounts and cached session switches", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  const message: SessionMessageUser = {
    id: "msg_quote_cached",
    type: "user",
    time: { created: 1700000100000 },
    text: formatChatQuotes([longQuote]),
    metadata: { displayText: "", comments: [], quotes: [longQuote] },
  }
  const history: SessionMessageUser[] = Array.from({ length: 80 }, (_, index) => ({
    id: `msg_history_${index}`,
    type: "user",
    time: { created: 1700000000000 + index * 1000 },
    text: `Earlier message ${index}`,
  }))
  await mockOpenCodeServer(page, {
    ...fixture,
    pageMessages: (id) => ({
      items:
        id === fixture.sourceID
          ? [
              ...history,
              message,
              { ...history[0]!, id: "msg_after_quote", text: "A later message", time: { created: 1700000101000 } },
            ]
          : [history[0]!],
    }),
  })
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  const bubble = page.locator('[data-timeline-part-id="msg_quote_cached:text:0"]')
  await bubble.getByRole("button", { name: "Expand quote", exact: true }).click()
  const collapse = bubble.getByRole("button", { name: "Collapse quote", exact: true })
  await expect(collapse).toHaveAttribute("aria-expanded", "true")
  await page.locator('[data-slot="session-timeline-scroll"]').hover()
  await page.mouse.wheel(0, -100000)
  await expect(page.getByText("Earlier message 0", { exact: true })).toBeInViewport()
  await expect(bubble).toHaveCount(0)
  await page.mouse.wheel(0, 100000)
  await expect(collapse).toHaveAttribute("aria-expanded", "true")
  await expect(bubble.getByRole("blockquote")).toHaveCSS("-webkit-line-clamp", "none")
  await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.targetID)}"]`).click()
  await expect(page.getByText("Earlier message 0", { exact: true })).toBeInViewport()
  await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.sourceID)}"]`).click()
  await expect(collapse).toHaveAttribute("aria-expanded", "true")
  await collapse.click()
  await expect(bubble.getByRole("button", { name: "Expand quote", exact: true })).toHaveAttribute(
    "aria-expanded",
    "false",
  )
})

test("isolates mixed-direction quotes and keeps disclosure keyboard accessible in RTL", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 900 })
  const quote = {
    ...longQuote,
    text: "تحقق من إعدادات الاتصال في src/config.ts\nhttps://example.test/database\n" + longQuote.text,
    comment: "راجع الإعدادات في src/config.ts قبل النشر.",
  }
  const session = { ...fixture.sessions[0], id: "ses_rtl_quotes" }
  await mockOpenCodeServer(page, {
    ...fixture,
    sessions: [session],
    pageMessages: () => ({
      items: [
        {
          id: "msg_rtl_quote",
          type: "user",
          time: { created: 1700000000000 },
          text: formatChatQuotes([quote]),
          metadata: { displayText: "", comments: [], quotes: [quote] },
        },
      ],
    }),
  })
  await page.goto(stressSessionHref(session.id))
  const bubble = page.locator('[data-component="user-message-quote"]')
  const expand = bubble.getByRole("button", { name: "Expand quote", exact: true })
  await expect(expand).toHaveAttribute("aria-expanded", "false")
  await page.locator("html").evaluate((element) => {
    element.setAttribute("dir", "rtl")
    element.setAttribute("lang", "ar")
  })
  await expect(bubble.getByRole("blockquote")).toHaveCSS("direction", "rtl")
  await expect(bubble.getByRole("blockquote")).toHaveCSS("border-right-width", "1px")
  await expand.focus()
  await expand.press("Space")
  await expect(bubble.getByRole("button", { name: "Collapse quote", exact: true })).toBeFocused()
  await expect(bubble.getByRole("blockquote")).toHaveText(quote.text)
  await expect(bubble.getByText(quote.comment, { exact: true })).toHaveCSS("direction", "rtl")
  await expect.poll(() => bubble.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true)
})
