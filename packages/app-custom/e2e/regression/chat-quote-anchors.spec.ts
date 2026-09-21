import type { SessionMessageInfo } from "@opencode/client/promise"
import { expect, test } from "@playwright/test"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { mockOpenCodeServer } from "../utils/mock-server"

test.use({ serviceWorkers: "block" })

for (const width of [1440, 390]) {
  const scenario = test.extend({ hasTouch: width < 768 })
  scenario(`draft anchors preserve repeated formatted text at ${width}px`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 900 })
    const session = fixture.sessions[0]!
    const messages: SessionMessageInfo[] = [
      { id: "msg_anchor_user", type: "user", time: { created: 1700000000000 }, text: "Explain these phrases." },
      {
        id: "msg_anchor_answer",
        type: "assistant",
        agent: "build",
        time: { created: 1700000000100, completed: 1700000001000 },
        model: { id: "claude-opus-4-6", providerID: "opencode" },
        content: [
          { type: "text", text: "Repeat this phrase.\n\n**Repeat** this `phrase`.\n\nA final sentence to annotate." },
        ],
      },
    ]
    const history: SessionMessageInfo[] = Array.from({ length: 80 }, (_, index) => ({
      id: `msg_anchor_history_${index}`,
      type: "user",
      time: { created: 1690000000000 + index * 1000 },
      text: `Anchor history ${index}`,
    }))
    await mockOpenCodeServer(page, {
      ...fixture,
      pageMessages: (id) => ({ items: id === session.id ? [...history, ...messages] : [history[0]!] }),
    })
    await page.goto(stressSessionHref(session.id))
    const part = page.locator('[data-timeline-part-id="msg_anchor_answer:text:0"]')
    await expect(part.locator('[data-component="markdown"]')).toHaveAttribute("data-markdown-ready", "")
    const body = part.locator('[data-slot="text-part-body"]')
    const original = await body.innerHTML()
    await body.evaluate((element) => {
      const range = document.createRange()
      range.setStart(element.querySelector("strong")!.firstChild!, 0)
      range.setEnd(element.querySelector("code")!.firstChild!, 6)
      window.getSelection()?.removeAllRanges()
      window.getSelection()?.addRange(range)
    })
    await page.keyboard.press("Shift")
    await page.getByRole("button", { name: "Comment", exact: true }).click()
    const comment = page.getByRole("textbox", { name: "Your comment", exact: true })
    await expect(comment).toBeFocused()
    await comment.fill("Keep the second occurrence.")
    await page.getByRole("button", { name: "Done", exact: true }).click()
    if (width >= 768) await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeFocused()
    const badge = page.getByRole("button", { name: "Comment 1", exact: true })
    await expect(badge).toBeVisible()
    expect(await body.innerHTML()).toBe(original)
    const highlights = page.locator('[data-slot="quote-highlight"]')
    await expect.poll(() => highlights.count()).toBeGreaterThan(0)
    const aligned = async () =>
      body.evaluate((element) => {
        const target = element.querySelector("strong")!.getBoundingClientRect()
        const rects = Array.from(document.querySelectorAll('[data-slot="quote-highlight"]')).map((node) =>
          node.getBoundingClientRect(),
        )
        return rects.some((rect) => Math.abs(rect.top - target.top) < 2 && Math.abs(rect.left - target.left) < 2)
      })
    await expect.poll(aligned).toBe(true)
    await badge.focus()
    await expect(page.locator('[data-quote-id][data-active="true"]')).toHaveCount(1)
    await badge.press("Enter")
    await expect(comment).toHaveText("Keep the second occurrence.")
    await comment.press("Escape")
    await page.setViewportSize({ width: width === 390 ? 480 : 1000, height: 700 })
    await body.scrollIntoViewIfNeeded()
    await expect.poll(aligned).toBe(true)
    await page.reload()
    await expect(badge).toBeVisible()
    await expect.poll(aligned).toBe(true)
    if (width < 768) await badge.tap()
    if (width >= 768) await badge.click()
    await expect(comment).toHaveText("Keep the second occurrence.")
    await comment.press("Escape")
    if (width >= 768) {
      const scroller = page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport')
      await scroller.press("Home")
      await scroller.evaluate((element) => {
        element.scrollTop = 0
      })
      await expect(page.getByText("Anchor history 0", { exact: true })).toBeInViewport()
      await expect(badge).toHaveCount(0)
      await scroller.evaluate((element) => {
        element.scrollTop = element.scrollHeight
      })
      await expect(badge).toBeVisible()
      await expect.poll(aligned).toBe(true)
    }
    await body.evaluate((element) => {
      element.setAttribute("dir", "rtl")
    })
    await page.setViewportSize({ width, height: 900 })
    await body.scrollIntoViewIfNeeded()
    await expect.poll(aligned).toBe(true)
    await badge.click()
    await expect(comment).toHaveText("Keep the second occurrence.")
    if (width >= 768)
      await expect
        .poll(async () => {
          const box = await page.locator('[data-slot="chat-quote-popover"]').boundingBox()
          const anchor = await badge.boundingBox()
          return (
            !!box &&
            !!anchor &&
            (Math.abs(box.y - (anchor.y + anchor.height + 8)) < 2 || Math.abs(box.y + box.height + 8 - anchor.y) < 2)
          )
        })
        .toBe(true)
    await page.screenshot({ path: info.outputPath(`quote-anchor-editor-${width}.png`) })
    await comment.press("Escape")
    await expect(comment).toHaveCount(0)
    const prompt = page.getByRole("textbox", { name: "Prompt", exact: true })
    await expect(prompt).toBeVisible()
    if (width >= 768) await expect(prompt).toBeFocused()
    const final = body.getByText("A final sentence to annotate.", { exact: true })
    await final.scrollIntoViewIfNeeded()
    await expect(final).toBeInViewport()
    await final.evaluate((element) => {
      const range = document.createRange()
      range.selectNodeContents(element)
      window.getSelection()?.removeAllRanges()
      window.getSelection()?.addRange(range)
    })
    await page.keyboard.press("Shift")
    await page.getByRole("button", { name: "Comment", exact: true }).click()
    await expect(comment).toBeFocused()
    await comment.fill("Second annotation")
    await comment.press("Escape")
    await expect(page.getByRole("button", { name: "Comment 2", exact: true })).toBeVisible()
    await badge.click()
    await page.getByRole("button", { name: "Remove quote", exact: true }).click()
    await expect(page.getByRole("button", { name: "Comment 2", exact: true })).toHaveCount(0)
    await badge.click()
    await expect(comment).toHaveText("Second annotation")
    await page.getByRole("button", { name: "Remove quote", exact: true }).click()
    await expect(badge).toHaveCount(0)
    await expect(highlights).toHaveCount(0)
    await expect(comment).toHaveCount(0)
  })
}
