import { expect, test, type Page } from "@playwright/test"
import { timelinePresets } from "@opencode/session-ui-custom/timeline/detail"
import { createTwoFilesPatch } from "diff"
import {
  assistantMessage,
  setupTimeline,
  textPart,
  toolPart,
  userMessage,
} from "../performance/timeline-stability/fixture"

const before = Array.from({ length: 80 }, (_, index) => `export const value${index} = ${index}\n`).join("")
const after = before.replaceAll(" = ", " = 1 + ")
const files = ["src/a.ts", "src/b.ts"].map((file) => ({
  file,
  status: "modified",
  additions: 80,
  deletions: 80,
  patch: createTwoFilesPatch(file, file, before, after),
}))
const answer = Array.from({ length: 40 }, (_, index) => `Answer paragraph ${index}.`).join("\n\n")
const reads = Array.from({ length: 12 }, (_, index) =>
  toolPart(`prt_sticky_read_${index}`, "read", "completed", { path: `src/file${index}.ts` }),
)

const top = (locator: ReturnType<Page["locator"]>) => locator.evaluate((node) => node.getBoundingClientRect().top)

async function setup(page: Page, viewport: { width: number; height: number }, locale?: string) {
  await setupTimeline(page, {
    settings: { timelineDetail: { ...timelinePresets[2].value, edit: { placement: "grouped", details: "expanded" } } },
    messages: [
      userMessage(),
      assistantMessage([
        ...reads,
        toolPart("prt_sticky_glob", "glob", "completed", { pattern: "*.ts" }),
        toolPart("prt_sticky_patch", "patch", "completed", {}, { metadata: { files } }),
        toolPart("prt_sticky_grep", "grep", "completed", { pattern: "value" }),
        // Enough answer after the group that the viewport stays scrollable once the group collapses.
        textPart("prt_sticky_answer", answer),
      ]),
    ],
    viewport,
    locale,
  })
  const scroller = page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport')
  const group = scroller.locator('[data-component="collapsed-tool-group"]')
  const header = group.locator(':scope > [data-component="collapsible"] > [data-slot="collapsible-trigger"]')
  await expect(header).toHaveAttribute("aria-expanded", "false")
  await header.click()
  await expect(header).toHaveAttribute("aria-expanded", "true")
  const file = group.locator('[data-component="sticky-accordion-header"]').filter({ hasText: "b.ts" })
  await expect(file).toBeVisible()
  // The expanded diffs render after opening and the followed timeline settles at the end of the answer.
  await expect.poll(() => scroller.evaluate((node) => node.scrollHeight - node.clientHeight)).toBeGreaterThan(5000)
  await expect(page.getByText("Answer paragraph 39.", { exact: true })).toBeInViewport()
  // Scroll up like a reader until the end of the group is near the bottom, inside the last diff's sticky range.
  const grep = group.getByText("pattern=value", { exact: true })
  const box = (await scroller.boundingBox())!
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.wheel(0, (await top(grep)) - (box.y + box.height - 120))
  await expect(grep).toBeInViewport()
  return { scroller, group, header, file, user: page.locator("[data-sticky-user]") }
}

const bottom = (locator: ReturnType<Page["locator"]>) => locator.evaluate((node) => node.getBoundingClientRect().bottom)

// Each stuck layer must receive input just inside its top edge, so nothing paints over another.
async function hits(page: Page, selectors: string[]) {
  return page.evaluate(
    (selectors) =>
      selectors.map((selector) => {
        // The last diff header is the one stuck at the end of the scrolled group.
        const node = [...document.querySelectorAll(`[data-slot="session-timeline-scroll"] ${selector}`)].at(-1)!
        const rect = node.getBoundingClientRect()
        return node.contains(document.elementFromPoint(rect.left + rect.width / 2, rect.top + 1))
      }),
    selectors,
  )
}

const layers = [
  "[data-sticky-user] [data-component='user-message']",
  '[data-component="collapsed-tool-group"] > [data-component="collapsible"] > [data-slot="collapsible-trigger"]',
  '[data-component="collapsed-tool-group"] [data-component="sticky-accordion-header"]',
]

for (const scenario of [
  { name: "desktop", viewport: { width: 1440, height: 900 } },
  { name: "desktop RTL", viewport: { width: 1440, height: 900 }, locale: "ar" },
]) {
  test(`stacks the open Used header between the pinned message and its diff headers (${scenario.name})`, async ({
    page,
  }) => {
    const stack = await setup(page, scenario.viewport, scenario.locale)
    const bar = page.locator('[data-slot="session-title-bar"]')
    await expect(bar).toBeVisible()
    if (scenario.locale) await expect(page.locator("html")).toHaveAttribute("dir", "rtl")

    // Adjacent reads collapse into one row inside the group.
    await expect(stack.group.locator('[data-component="read-tool-group"]')).toHaveCount(1)
    await expect(stack.group.locator('[data-slot="read-tool-group-file"]')).toHaveCount(12)

    await expect.poll(() => top(stack.user)).toBe(await bottom(bar))
    await expect.poll(async () => (await top(stack.header)) - (await bottom(stack.user))).toBe(0)
    await expect(stack.header).toHaveCSS("height", "36px")
    await expect.poll(async () => (await top(stack.file)) - (await bottom(stack.header))).toBe(0)
    expect(await hits(page, layers)).toEqual([true, true, true])

    // Collapsing from the stuck header keeps it where it was instead of jumping far below the group.
    const stuck = await top(stack.header)
    const height = await stack.scroller.evaluate((node) => node.scrollHeight)
    await stack.header.click()
    await expect(stack.header).toHaveAttribute("aria-expanded", "false")
    await expect(stack.group.locator('[data-slot="context-tool-group-item"]')).toHaveCount(0)
    // Wait for the virtual list to shrink before reading the settled position.
    await expect.poll(() => stack.scroller.evaluate((node) => node.scrollHeight)).toBeLessThan(height - 3000)
    await expect.poll(() => top(stack.header)).toBe(stuck)
    expect(await hits(page, layers.slice(0, 2))).toEqual([true, true])
  })
}

test.describe("phone", () => {
  test.use({ isMobile: true, hasTouch: true })

  test("stacks the open Used header below the pinned message", async ({ page }) => {
    const stack = await setup(page, { width: 390, height: 844 })
    await expect(page.locator('[data-slot="session-title-bar"]')).toHaveCount(0)

    await expect.poll(async () => (await top(stack.user)) - (await top(stack.scroller))).toBe(0)
    await expect.poll(async () => (await top(stack.header)) - (await bottom(stack.user))).toBe(0)
    await expect.poll(async () => (await top(stack.file)) - (await bottom(stack.header))).toBe(0)
    expect(await hits(page, layers)).toEqual([true, true, true])

    const stuck = await top(stack.header)
    const height = await stack.scroller.evaluate((node) => node.scrollHeight)
    await stack.header.tap()
    await expect(stack.header).toHaveAttribute("aria-expanded", "false")
    // Wait for the virtual list to shrink before reading the settled position.
    await expect.poll(() => stack.scroller.evaluate((node) => node.scrollHeight)).toBeLessThan(height - 3000)
    await expect.poll(() => top(stack.header)).toBe(stuck)
  })
})
