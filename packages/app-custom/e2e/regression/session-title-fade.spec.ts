import { expect, test } from "@playwright/test"
import { timelinePresets } from "@opencode/session-ui-custom/timeline/detail"
import { createTwoFilesPatch } from "diff"
import { assistantMessage, setupTimeline, toolPart, userMessage } from "../performance/timeline-stability/fixture"

const before = Array.from({ length: 80 }, (_, index) => `export const value${index} = ${index}\n`).join("")
const after = before.replaceAll(" = ", " = 1 + ")
const files = ["src/a.ts", "src/b.ts"].map((file) => ({
  file,
  status: "modified",
  additions: 80,
  deletions: 80,
  patch: createTwoFilesPatch(file, file, before, after),
}))

test("keeps rows stuck below the session title out of its fade", async ({ page }) => {
  await setupTimeline(page, {
    settings: { timelineDetail: timelinePresets[0].value },
    messages: [
      userMessage(),
      assistantMessage([toolPart("prt_fade_patch", "patch", "completed", {}, { metadata: { files } })]),
    ],
    viewport: { width: 1440, height: 900 },
  })
  const title = page.locator("[data-session-title]")
  const fade = page.locator('[data-slot="session-title-fade"]')
  const sticky = page.locator("[data-sticky-user] [data-component='user-message']")
  const scroller = page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport')
  await expect(page.locator('[data-component="apply-patch-tool"]')).toBeVisible()
  await expect(title.getByRole("heading", { level: 1 })).toBeVisible()
  // The patch tool paints before its rows are measured; until then the list cannot scroll and the followed
  // timeline settles at the end once the diffs land, so wait until the offset below is reachable.
  await expect
    .poll(() => scroller.evaluate((element) => element.scrollHeight - element.clientHeight))
    .toBeGreaterThan(1200)

  await scroller.evaluate((element) => (element.scrollTop = 600))
  await expect.poll(() => scroller.evaluate((element) => element.scrollTop)).toBe(600)

  const message = (await sticky.boundingBox())!
  expect(message.y).toBe((await title.boundingBox())!.y + 48)
  // The stuck message's top edge sits where the fade starts; it must paint and receive input above it.
  const hits = await page.evaluate(
    ({ box }) =>
      [box.y + 1, box.y + 8, box.y + 15].map((y) => {
        const target = document.elementFromPoint(box.x + box.width / 2, y)
        return !!target?.closest("[data-sticky-user]")
      }),
    { box: message },
  )
  expect(hits).toEqual([true, true, true])
  const bar = (await title.locator('[data-slot="session-title-bar"]').boundingBox())!
  expect(bar.height).toBe(48)
  expect(message.y).toBe(bar.y + bar.height)
  await expect(fade).toHaveAttribute("aria-hidden", "true")
  await expect(fade).toHaveCSS("pointer-events", "none")
  expect(await fade.boundingBox()).toEqual({ x: bar.x, y: bar.y + bar.height, width: bar.width, height: 16 })
  await expect(fade).toHaveCSS("background-image", /linear-gradient/)

  // The title controls stay interactive above the fade.
  const heading = (await title.getByRole("heading", { level: 1 }).boundingBox())!
  expect(
    await page.evaluate(({ x, y }) => document.elementFromPoint(x, y)?.closest("h1") !== null, {
      x: heading.x + heading.width / 2,
      y: heading.y + heading.height / 2,
    }),
  ).toBe(true)
})

test("keeps the phone timeline free of the session title fade", async ({ page }) => {
  await setupTimeline(page, {
    settings: { timelineDetail: timelinePresets[0].value },
    messages: [
      userMessage(),
      assistantMessage([toolPart("prt_fade_patch", "patch", "completed", {}, { metadata: { files } })]),
    ],
    viewport: { width: 390, height: 844 },
  })
  await expect(page.locator('[data-component="apply-patch-tool"]')).toBeVisible()
  await expect(page.locator("[data-session-title]")).toHaveCount(0)
  await expect(page.locator('[data-slot="session-title-fade"]')).toHaveCount(0)
})
