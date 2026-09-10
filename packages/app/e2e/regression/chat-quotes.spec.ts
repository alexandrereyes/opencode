import type { SessionMessageInfo } from "@opencode/client/promise"
import { expect, test } from "@playwright/test"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { mockOpenCodeServer } from "../utils/mock-server"

test.use({ serviceWorkers: "block" })

for (const width of [1440, 390]) {
  test(`comments on selected assistant text at ${width}px`, async ({ page }, info) => {
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
      pageMessages: () => ({ items: messages }),
      onPrompt: ({ body }) => admissions.push(body),
    })
    await page.goto(stressSessionHref(session.id))
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
    const comment = page.getByRole("textbox", { name: "Your comment", exact: true })
    await expect(comment).toBeFocused()
    await comment.fill("Este é um teste de comentário")
    await page.getByRole("button", { name: "Done", exact: true }).click()
    const quotes = page.locator('[data-component="chat-quotes"]')
    const toggle = page.getByRole("button", { name: "Chat quotes · 1", exact: true })
    await expect(toggle).toHaveAttribute("aria-expanded", "false")
    await expect(comment).toHaveCount(0)
    await toggle.click()
    await expect(quotes.getByText("Este é um teste de comentário", { exact: true })).toBeVisible()
    await page.getByRole("button", { name: "Edit comment", exact: true }).click()
    await expect(comment).toHaveValue("Este é um teste de comentário")
    await comment.fill("Explique esse trecho, por favor.")
    await comment.press("ControlOrMeta+Enter")
    await expect(toggle).toHaveAttribute("aria-expanded", "false")
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
                  resolve(read.result.some((value) => String(value).includes("Explique esse trecho, por favor.")))
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
    await expect(quotes.getByText("Explique esse trecho, por favor.", { exact: true })).toBeVisible()
    const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
    await editor.click()
    await editor.press("Enter")
    await expect.poll(() => admissions.length).toBe(1)
    expect(admissions[0]).toMatchObject({
      text: expect.stringContaining("User comment: Explique esse trecho, por favor."),
      metadata: {
        quotes: [
          {
            messageID: "msg_quote_answer",
            partID: "msg_quote_answer:text:0",
            text: "Use the complete connection string without external quotes.",
            comment: "Explique esse trecho, por favor.",
            id: expect.any(String),
          },
        ],
      },
    })
    await expect(toggle).toHaveCount(0)
    await editor.press("ArrowUp")
    await expect(toggle).toBeVisible()
    if ((await toggle.getAttribute("aria-expanded")) === "false") await toggle.click()
    await page.getByRole("button", { name: "Remove quote", exact: true }).click()
    await expect(toggle).toHaveCount(0)
  })
}
