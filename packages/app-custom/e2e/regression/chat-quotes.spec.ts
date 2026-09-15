import type { SessionMessageInfo } from "@opencode/client/promise"
import { expect, test } from "@playwright/test"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { mockOpenCodeServer } from "../utils/mock-server"

test.use({ serviceWorkers: "block" })

for (const width of [1440, 390]) {
  const scenario = test.extend({ hasTouch: width < 768 })
  scenario(`comments on selected assistant text at ${width}px`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 900 })
    const session = { ...fixture.sessions[0], id: "ses_chat_quotes" }
    const messages: SessionMessageInfo[] = [
      { id: "msg_quote_user", type: "user", time: { created: 1700000000000 }, text: "Explain deployment." },
      {
        id: "msg_quote_answer",
        type: "assistant",
        agent: "build",
        time: { created: 1700000000100, completed: 1700000001000 },
        model: { id: "claude-opus-4-6", providerID: "opencode" },
        content: [
          {
            type: "text",
            text: "Use the complete connection string without external quotes.\n\nCheck the deployment configuration.",
          },
        ],
      },
    ]
    const admissions: Record<string, unknown>[] = []
    await mockOpenCodeServer(page, {
      ...fixture,
      sessions: [session],
      snippets: [
        {
          id: "review",
          name: "review",
          description: "Review the selected text",
          aliases: ["audit"],
          content: "Expanded review instructions.",
        },
      ],
      skills: [
        {
          id: "audit",
          name: "Audit Skill",
          description: "Audit the selected context",
          location: "/skills/audit",
          content: "Audit instructions",
        },
      ],
      findFiles: () => ["src/config.ts"],
      pageMessages: () => ({ items: messages }),
      onPrompt: ({ body }) => admissions.push(body),
    })
    await page.goto(stressSessionHref(session.id))
    const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
    await page.locator('.composer-main input[type="file"]').setInputFiles({
      name: "draft.png",
      mimeType: "image/png",
      buffer: Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=",
        "base64",
      ),
    })
    await expect(page.getByRole("img", { name: "draft.png", exact: true })).toBeVisible()
    await editor.fill("Draft")
    await editor.press("Home")
    await editor.press("ArrowRight")
    const originalEditor = await editor.elementHandle()
    const part = page.locator('[data-timeline-part-id="msg_quote_answer:text:0"]')
    const text = part.getByText("Use the complete connection string without external quotes.", { exact: true })
    await expect(part.locator('[data-component="markdown"]')).toHaveAttribute("data-markdown-ready", "")
    await expect(text).toBeInViewport()
    // A real browser Range over rendered prose also supports multiline and inline markup.
    await text.evaluate((element) => {
      const range = document.createRange()
      range.selectNodeContents(element)
      window.getSelection()?.removeAllRanges()
      window.getSelection()?.addRange(range)
    })
    await page.keyboard.press("Shift")
    const action = page.getByRole("button", { name: "Comment", exact: true })
    await expect(action).toBeVisible()
    await action.click()
    const quotes = page.locator('[data-component="chat-quotes"]')
    const comment = page.getByRole("textbox", { name: "Your comment", exact: true })
    await expect(comment).toBeFocused()
    const main = page.locator(".composer-main")
    await expect(main).toBeAttached()
    if (width < 768) {
      await page.setViewportSize({ width, height: 500 })
      await expect(editor).toHaveCount(0)
      await expect(main).toBeHidden()
      expect(await main.evaluate((element) => element.getBoundingClientRect().height)).toBe(0)
      await expect(page.getByRole("button", { name: "Chat quotes · 1", exact: true })).toHaveCount(0)
      await expect(quotes.getByRole("blockquote")).toHaveCSS("-webkit-line-clamp", "3")
      await expect(quotes.getByRole("blockquote")).toHaveCSS("overflow-y", "hidden")
    } else {
      await expect(editor).toBeVisible()
      const disclosure = page.getByRole("button", { name: "Chat quotes · 1", exact: true })
      await disclosure.click()
      await expect(comment).toHaveCount(0)
      await page.setViewportSize({ width: 390, height: 900 })
      await expect(disclosure).toBeVisible()
      await expect(editor).toBeVisible()
      await disclosure.click()
      await expect(comment).toBeFocused()
      await expect(main).toBeHidden()
      await page.setViewportSize({ width, height: 900 })
      await expect(editor).toBeVisible()
      await expect(disclosure).toBeVisible()
    }
    await comment.blur()
    await expect(comment).toBeVisible()
    await page.getByText("Your comment", { exact: true }).click()
    await expect(comment).toBeFocused()
    await expect(comment).toHaveCSS("padding-top", "8px")
    await expect(comment).toHaveCSS("padding-left", "10px")
    await comment.fill(Array.from({ length: 20 }, (_, index) => `Long comment line ${index + 1}`).join("\n"))
    const commentScrollRoot = quotes.locator('[data-component="composer-scroll"]')
    const commentScroll = commentScrollRoot.locator(".scroll-view__viewport")
    await expect.poll(() => commentScroll.evaluate((element) => element.scrollHeight > element.clientHeight)).toBe(true)
    await expect(commentScrollRoot).toHaveCSS("max-height", width < 768 ? "125px" : "180px")
    await comment.fill("First line")
    await comment.press("Enter")
    await comment.pressSequentially("Second line")
    await expect(comment).toHaveJSProperty("innerText", "First line\nSecond line")
    await comment.fill("! #")
    await expect(page.locator('[data-suggestion-id="snippet:review"]')).toBeVisible()
    await comment.press("Escape")
    await expect(page.locator('[data-suggestion-id="snippet:review"]')).toHaveCount(0)
    await expect(comment).toBeFocused()
    await comment.fill("! $")
    await expect(page.locator('[data-suggestion-id="skill:audit"]')).toBeVisible()
    await comment.fill("#")
    const snippet = page.locator('[data-suggestion-id="snippet:review"]')
    await expect(snippet).toBeVisible()
    // The shell's containing block requires the existing portal. Verify that
    // the popup itself has no ancestor that changes its fixed coordinates.
    await expect(quotes.locator('[data-component="composer-suggestions"]')).toHaveCount(0)
    expect(
      await snippet.evaluate((element) => {
        const blockers: string[] = []
        for (
          let parent = element.closest('[data-component="composer-suggestions"]')?.parentElement;
          parent;
          parent = parent.parentElement
        ) {
          const style = getComputedStyle(parent)
          if (
            style.transform !== "none" ||
            style.filter !== "none" ||
            /layout|paint|strict|content/.test(style.contain)
          )
            blockers.push(parent.tagName)
        }
        return blockers
      }),
    ).toEqual([])
    const quoteList = quotes.locator('[data-slot="chat-quotes-list"]')
    await expect(quoteList).toHaveCSS("max-height", width < 768 ? "none" : "360px")
    await expect(quoteList).toHaveCSS("overflow-y", width < 768 ? "visible" : "auto")
    await expect
      .poll(() =>
        snippet.evaluate((element) => {
          const box = element.closest('[data-component="composer-suggestions"]')?.getBoundingClientRect()
          return !!box && box.top >= 0 && box.left >= 0 && box.right <= innerWidth && box.bottom <= innerHeight
        }),
      )
      .toBe(true)
    await expect
      .poll(() =>
        comment.evaluate((element) => {
          const anchor = element.closest('[data-component="composer"]')!.getBoundingClientRect()
          const popup = document.querySelector('[data-component="composer-suggestions"]')!.getBoundingClientRect()
          return anchor.top - popup.bottom
        }),
      )
      .toBeCloseTo(8, 0)
    await page.screenshot({ path: info.outputPath(`chat-quote-snippets-${width}.png`) })
    if (width < 768) {
      // WebKit reports client rects relative to the panned visual viewport, while
      // fixed CSS coordinates retain the layout origin. Model that browser boundary
      // for every element, not just the popup or the application's calculation.
      await page.evaluate(() => {
        const original = Element.prototype.getBoundingClientRect
        Element.prototype.getBoundingClientRect = function () {
          const rect = original.call(this)
          return new DOMRect(rect.x, rect.y - (window.visualViewport?.offsetTop ?? 0), rect.width, rect.height)
        }
        window.addEventListener(
          "restore-client-rects",
          () => {
            Element.prototype.getBoundingClientRect = original
          },
          { once: true },
        )
      })
      for (const event of ["resize", "scroll"]) {
        await comment.evaluate((element, event) => {
          const top =
            element.getBoundingClientRect().top +
            (window.visualViewport?.offsetTop ?? 0) -
            (event === "resize" ? 120 : 100)
          Object.defineProperties(window.visualViewport, {
            offsetTop: { configurable: true, value: top },
            height: { configurable: true, value: innerHeight - top },
          })
          window.visualViewport?.dispatchEvent(new Event(event))
        }, event)
        await expect
          .poll(() =>
            snippet.evaluate((element) => {
              const box = element.closest('[data-component="composer-suggestions"]')!.getBoundingClientRect()
              const viewport = window.visualViewport!
              return box.height > 0 && box.height < 136 && box.top >= 0 && box.bottom <= viewport.height
            }),
          )
          .toBe(true)
        await expect
          .poll(() =>
            comment.evaluate((element) => {
              const anchor = element.closest('[data-component="composer"]')!.getBoundingClientRect()
              const popup = document.querySelector('[data-component="composer-suggestions"]')!.getBoundingClientRect()
              return anchor.top - popup.bottom
            }),
          )
          .toBeCloseTo(8, 0)
      }
      await snippet.tap()
      await expect(comment).toBeFocused()
      await page.evaluate(() => {
        window.dispatchEvent(new Event("restore-client-rects"))
        Reflect.deleteProperty(window.visualViewport!, "offsetTop")
        Reflect.deleteProperty(window.visualViewport!, "height")
        window.visualViewport?.dispatchEvent(new Event("resize"))
      })
      await expect(comment).toBeVisible()
      await expect(main).toBeHidden()
    } else {
      await comment.press("Enter")
    }
    await comment.pressSequentially("$")
    await expect(page.locator('[data-suggestion-id="skill:audit"]')).toBeVisible()
    await comment.press("Enter")
    await comment.pressSequentially("@config")
    await expect(page.locator('[data-suggestion-id="file:src/config.ts"]')).toBeVisible()
    await comment.press("Enter")
    await expect(comment).toContainText("#review $audit @src/config.ts")
    const quoteCard = quotes.getByRole("article")
    await expect(quoteCard.getByRole("button", { name: "Send", exact: true })).toHaveCount(0)
    await expect(quoteCard.getByRole("button", { name: "Add", exact: true })).toHaveCount(0)
    expect(await originalEditor?.textContent()).toBe("Draft")
    await page.screenshot({ path: info.outputPath(`chat-quote-editor-${width}.png`) })
    await page.getByRole("button", { name: "Done", exact: true }).click()
    await expect(editor).toBeVisible()
    if (width >= 768) await expect(editor).toBeFocused()
    if (width < 768) await expect(editor).not.toBeFocused()
    expect(await originalEditor?.evaluate((element) => element.isConnected)).toBe(true)
    await expect(page.getByRole("img", { name: "draft.png", exact: true })).toBeVisible()
    if (width < 768) await page.setViewportSize({ width, height: 900 })
    await editor.focus()
    await editor.pressSequentially("X")
    await expect(editor).toHaveText("DXraft")
    await editor.fill("")
    await main.locator('[data-action="remove-attachment"]').click()
    expect(admissions).toHaveLength(0)
    const toggle = page.getByRole("button", { name: "Chat quotes · 1", exact: true })
    await expect(toggle).toHaveAttribute("aria-expanded", "false")
    await expect(comment).toHaveCount(0)
    await toggle.click()
    await expect(quotes.getByText("#review $audit @src/config.ts", { exact: true })).toBeVisible()

    const secondText = part.getByText("Check the deployment configuration.", { exact: true })
    await secondText.evaluate((element) => {
      const range = document.createRange()
      range.selectNodeContents(element)
      window.getSelection()?.removeAllRanges()
      window.getSelection()?.addRange(range)
    })
    await page.keyboard.press("Shift")
    await action.click()
    await expect(comment).toBeFocused()
    await expect(quotes.getByRole("article")).toHaveCount(width < 768 ? 1 : 2)
    await expect(quotes.locator('[data-slot="chat-quote"]')).toHaveCount(2)
    await expect(quotes.getByRole("article").filter({ hasText: "Check the deployment configuration." })).toBeVisible()
    await comment.fill("#")
    await expect(snippet).toBeVisible()
    await expect(quoteList).toHaveCSS("max-height", width < 768 ? "none" : "360px")
    await expect(quoteList).toHaveCSS("overflow-y", width < 768 ? "visible" : "auto")
    await expect
      .poll(() => snippet.evaluate((element) => element.getBoundingClientRect().bottom <= innerHeight))
      .toBe(true)
    await comment.press("Escape")
    await expect(snippet).toHaveCount(0)
    await comment.fill("Second quote comment")
    await comment.press("Escape")
    await expect(editor).toBeVisible()
    if (width >= 768) await expect(editor).toBeFocused()
    const twoQuotesToggle = page.getByRole("button", { name: "Chat quotes · 2", exact: true })
    await twoQuotesToggle.click()
    await expect(quotes.getByText("#review $audit @src/config.ts", { exact: true })).toBeVisible()
    const secondQuote = quotes.getByRole("article").filter({ hasText: "Check the deployment configuration." })
    await expect(secondQuote.getByText("Second quote comment", { exact: true })).toBeVisible()
    await secondQuote.getByRole("button", { name: "Edit comment", exact: true }).click()
    await expect(comment).toHaveText("Second quote comment")
    await secondQuote.getByRole("button", { name: "Remove quote", exact: true }).click()
    await expect(comment).toHaveCount(0)
    await expect(editor).toBeVisible()
    await expect(toggle).toBeVisible()

    await page.getByRole("button", { name: "Edit comment", exact: true }).click()
    await expect(comment).toContainText("#review $audit @src/config.ts")
    await comment.press("ControlOrMeta+Enter")
    await expect(toggle).toHaveAttribute("aria-expanded", "false")
    await toggle.click()
    await page.getByRole("button", { name: "Edit comment", exact: true }).click()
    await comment.press("Escape")
    await expect(toggle).toHaveAttribute("aria-expanded", "false")
    await expect(editor).toBeVisible()
    if (width >= 768) await expect(editor).toBeFocused()
    await expect(page.getByRole("button", { name: "Send", exact: true })).toBeEnabled()
    await page.screenshot({ path: info.outputPath(`chat-quotes-${width}.png`) })
    await expect
      .poll(() =>
        page.evaluate(
          () =>
            new Promise<boolean>((resolve, reject) => {
              const request = indexedDB.open("opencode-drafts", 1)
              request.onerror = () => reject(request.error)
              request.onsuccess = () => {
                const db = request.result
                const read = db.transaction("documents").objectStore("documents").getAll()
                read.onsuccess = () => {
                  resolve(
                    read.result.some(
                      (value) =>
                        String(value).includes("Expanded review instructions.") &&
                        String(value).includes("src/config.ts"),
                    ),
                  )
                  db.close()
                }
                read.onerror = () => {
                  reject(read.error)
                  db.close()
                }
              }
            }),
        ),
      )
      .toBe(true)
    await page.reload()
    await expect(toggle).toBeVisible()
    if ((await toggle.getAttribute("aria-expanded")) === "false") await toggle.click()
    await expect(quotes.getByText("#review $audit @src/config.ts", { exact: true })).toBeVisible()
    await editor.click()
    await editor.press(width < 768 ? "Shift+Enter" : "Enter")
    await expect.poll(() => admissions.length).toBe(1)
    expect(admissions[0]).toMatchObject({
      text: expect.stringContaining("User comment: Expanded review instructions. $audit @src/config.ts"),
      files: [expect.objectContaining({ uri: expect.stringContaining("/src/config.ts") })],
      skills: [expect.objectContaining({ id: "audit", name: "Audit Skill" })],
      metadata: {
        quotes: [
          {
            messageID: "msg_quote_answer",
            partID: "msg_quote_answer:text:0",
            text: "Use the complete connection string without external quotes.",
            comment: "#review $audit @src/config.ts ",
            commentPrompt: expect.arrayContaining([
              expect.objectContaining({ type: "snippet", id: "review", expansion: "Expanded review instructions." }),
              expect.objectContaining({ type: "skill", id: "audit", name: "Audit Skill" }),
              expect.objectContaining({ type: "file", path: "src/config.ts" }),
            ]),
            id: expect.any(String),
          },
        ],
      },
    })
    await expect(toggle).toHaveCount(0)
    await editor.press("ArrowUp")
    await expect(comment).toHaveText("#review $audit @src/config.ts")
    await page.getByRole("button", { name: "Remove quote", exact: true }).click()
    await expect(toggle).toHaveCount(0)
    await expect(editor).toBeVisible()
  })
}
