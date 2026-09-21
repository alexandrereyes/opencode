import type { Locator, Page } from "@playwright/test"
import { expect, test } from "@playwright/test"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { mockOpenCodeServer } from "../utils/mock-server"
import { pressPlatformShortcut } from "../utils/command-palette"

test.use({ serviceWorkers: "block" })

async function open(page: Page, text: string) {
  const session = { ...fixture.sessions[0], id: "ses_quote_layout" }
  await mockOpenCodeServer(page, {
    ...fixture,
    sessions: [session],
    pageMessages: () => ({
      items: [
        { id: "msg_layout_user", type: "user", time: { created: 1700000000000 }, text: "Check the annotated lines." },
        {
          id: "msg_layout_answer",
          type: "assistant",
          agent: "build",
          time: { created: 1700000000100, completed: 1700000001000 },
          model: { id: "claude-opus-4-6", providerID: "opencode" },
          content: [{ type: "text", text }],
        },
      ],
    }),
  })
  await page.goto(stressSessionHref(session.id))
  const body = page.locator('[data-timeline-part-id="msg_layout_answer:text:0"] [data-slot="text-part-body"]')
  await expect(body.locator('[data-component="markdown"]')).toHaveAttribute("data-markdown-ready", "")
  await page.getByRole("textbox", { name: "Prompt", exact: true }).focus()
  return body
}

async function annotate(page: Page, target: Locator, comment: string) {
  await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeFocused()
  const viewport = page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport')
  await viewport.press("Home")
  await expect(viewport).toHaveJSProperty("scrollTop", 0)
  await target.scrollIntoViewIfNeeded()
  await expect(target).toBeInViewport()
  await target.evaluate((element) => {
    const range = document.createRange()
    range.selectNodeContents(element)
    window.getSelection()?.removeAllRanges()
    window.getSelection()?.addRange(range)
  })
  await page.keyboard.press("Shift")
  await page.getByRole("button", { name: "Comment", exact: true }).click()
  const editor = page.getByRole("textbox", { name: "Your comment", exact: true })
  await expect(editor).toBeFocused()
  await editor.fill(comment)
  await page.getByRole("button", { name: "Done", exact: true }).click()
  await expect(editor).toHaveCount(0)
}

test("packs out-of-order annotations at the bottom without overlap and preserves their identities", async ({
  page,
}, info) => {
  await page.setViewportSize({ width: 1100, height: 720 })
  const body = await open(
    page,
    Array.from({ length: 12 }, (_, i) => `Earlier paragraph ${i}.`).join("\n\n") +
      "\n\n**Upper line**  \n**Lower line**\n\n" +
      "Later paragraph.\n\n".repeat(12),
  )
  for (const [index, name] of ["Lower line", "Upper line", "Upper line", "Lower line", "Upper line"].entries()) {
    await annotate(page, body.getByText(name, { exact: true }), `Annotation ${index + 1}: ${name}`)
  }
  const scroller = page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport')
  await scroller.press("Home")
  await body.getByText("Lower line", { exact: true }).evaluate((element) => {
    const scroll = element.closest<HTMLElement>(".scroll-view__viewport")!
    scroll.scrollTop += element.getBoundingClientRect().bottom - scroll.getBoundingClientRect().bottom + 2
  })
  const badges = page.locator('[data-slot="quote-anchor"]')
  await expect(badges).toHaveCount(5)
  await expect
    .poll(() =>
      body.getByText("Lower line", { exact: true }).evaluate((element) => {
        const viewport = element.closest<HTMLElement>(".scroll-view__viewport")!.getBoundingClientRect()
        return Math.abs(viewport.bottom - element.getBoundingClientRect().bottom)
      }),
    )
    .toBeLessThanOrEqual(3)
  await expect
    .poll(() =>
      badges.evaluateAll((elements) => {
        const bounds = document.querySelector('[data-slot="quote-anchor-rail"]')!.getBoundingClientRect()
        const viewport = document
          .querySelector('[data-slot="session-timeline-scroll"] .scroll-view__viewport')!
          .getBoundingClientRect()
        const boxes = elements.map((element) => element.getBoundingClientRect())
        return (
          bounds.top >= viewport.top &&
          bounds.bottom <= viewport.bottom &&
          boxes.every(
            (box, index) =>
              box.top >= bounds.top &&
              box.bottom <= bounds.bottom &&
              boxes
                .slice(0, index)
                .every(
                  (other) =>
                    box.bottom <= other.top ||
                    box.top >= other.bottom ||
                    box.right <= other.left ||
                    box.left >= other.right,
                ),
          )
        )
      }),
    )
    .toBe(true)
  for (const [index, name] of ["Lower line", "Upper line", "Upper line", "Lower line", "Upper line"].entries()) {
    await page.getByRole("button", { name: `Comment ${index + 1}`, exact: true }).click()
    await expect(page.getByRole("textbox", { name: "Your comment", exact: true })).toHaveText(
      `Annotation ${index + 1}: ${name}`,
    )
    await expect(page.locator('[data-slot="chat-quote-popover"] blockquote')).toHaveCount(0)
    await page.getByRole("button", { name: "Done", exact: true }).click()
  }
  await page.screenshot({ path: info.outputPath("quote-badge-stack.png") })
})

test("clips code highlights to horizontal scrollports and keeps overlays below sticky headers and dialogs", async ({
  page,
}, info) => {
  await page.setViewportSize({ width: 1100, height: 800 })
  const body = await open(
    page,
    "Opening paragraph.\n\n```text\n" +
      "long_code_segment ".repeat(100) +
      "\n```\n\n" +
      "Following paragraph.\n\n".repeat(25),
  )
  const code = body.locator("pre code")
  await annotate(page, code, "Check the entire long line")
  const highlights = page.locator('[data-slot="quote-highlight"]')
  await expect.poll(() => highlights.count()).toBeGreaterThan(0)
  await code.evaluate((element) => {
    for (let scroll = element.parentElement; scroll; scroll = scroll.parentElement) {
      if (scroll.scrollWidth <= scroll.clientWidth || !/auto|scroll/.test(getComputedStyle(scroll).overflowX)) continue
      scroll.setAttribute("data-test-code-scroll", "")
      scroll.scrollLeft = scroll.scrollWidth / 2
      return
    }
    throw new Error("Expected the rendered code block to have a horizontal scrollport")
  })
  const scroll = page.locator("[data-test-code-scroll]")
  await expect.poll(() => scroll.evaluate((element) => element.scrollLeft)).toBeGreaterThan(0)
  await expect
    .poll(() =>
      highlights.evaluateAll((elements) => {
        const bounds = document.querySelector("[data-test-code-scroll]")!.getBoundingClientRect()
        return (
          elements.length > 0 &&
          elements.every((element) => {
            const box = element.getBoundingClientRect()
            return (
              box.left >= bounds.left &&
              box.right <= bounds.right &&
              box.top >= bounds.top &&
              box.bottom <= bounds.bottom
            )
          })
        )
      }),
    )
    .toBe(true)
  await page.screenshot({ path: info.outputPath("quote-code-clipped.png") })
  await page.getByRole("button", { name: "Comment 1", exact: true }).click()
  await expect(page.locator('[data-slot="chat-quote-popover"] blockquote')).toHaveCount(0)
  await page.locator("[data-session-title]").getByRole("button", { name: "More options", exact: true }).click()
  const menu = page.getByRole("menu")
  await expect(menu).toBeVisible()
  await expect
    .poll(() =>
      menu.evaluate((element) => {
        const box = element.getBoundingClientRect()
        return element.contains(document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2))
      }),
    )
    .toBe(true)
  await page.screenshot({ path: info.outputPath("quote-below-menu.png") })
  await page.keyboard.press("Escape")
  await expect(menu).toHaveCount(0)
  await page.locator('[data-slot="quote-anchor"]').focus()
  await pressPlatformShortcut(page, "Shift+P")
  const dialog = page.getByRole("dialog")
  await expect(dialog).toBeVisible()
  await expect
    .poll(() =>
      dialog.evaluate((element) => {
        const box = element.getBoundingClientRect()
        const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)
        return !!hit && element.contains(hit)
      }),
    )
    .toBe(true)
  await expect
    .poll(() =>
      page.locator('[data-slot="quote-anchor"]').evaluate((element) => {
        const box = element.getBoundingClientRect()
        return document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2) !== element
      }),
    )
    .toBe(true)
  await page.screenshot({ path: info.outputPath("quote-below-dialog.png") })
  await page.keyboard.press("Escape")
  await expect(dialog).toHaveCount(0)
  await page.getByRole("button", { name: "Done", exact: true }).click()
  const scroller = page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport')
  await scroller.press("Home")
  await expect(scroller).toHaveJSProperty("scrollTop", 0)
  await code.evaluate((element) => {
    const viewport = element.closest<HTMLElement>(".scroll-view__viewport")!
    const header = viewport.querySelector("[data-session-title]")!
    viewport.scrollTop += element.getBoundingClientRect().bottom - header.getBoundingClientRect().bottom - 2
  })
  await expect
    .poll(() =>
      highlights.evaluateAll((elements) => {
        const sticky = document.querySelector("[data-sticky-user]")!.getBoundingClientRect()
        return elements.every((element) => element.getBoundingClientRect().top >= sticky.bottom)
      }),
    )
    .toBe(true)
  await expect(page.locator('[data-slot="quote-anchor"]')).toHaveCount(0)
  await page.screenshot({ path: info.outputPath("quote-sticky-clipped.png") })
  await page.getByRole("button", { name: "Chat quotes · 1", exact: true }).click()
  await page.getByRole("button", { name: "Edit comment", exact: true }).click()
  await expect(page.locator('[data-slot="chat-quote-popover"] blockquote')).toContainText("long_code_segment")
  await page.screenshot({ path: info.outputPath("quote-unresolved-context.png") })
})
