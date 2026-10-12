import { expect, story } from "../../storybook/playwright/story"

const runs = [
  "index.tsx, main.ts, rpc.ts, model.ts, toolbar.tsx",
  "connection.ts limit=120, index.tsx, environment.tsx, env.d.ts",
  "index.tsx, button.tsx, toggle.ts, index.tsx",
  "context.tsx",
]

story("collapses each run of reads inside a Used group into one row", async ({ mount }) => {
  const root = await mount("current-read-group--used-group", { args: { width: "960" } })
  const group = root.locator('[data-component="collapsed-tool-group"]')
  const header = group.getByRole("button", { name: "Used 65 Read, Shell", exact: true })
  await expect(header).toBeVisible()
  // The Used title keeps the custom segmented count, counting every read call.
  await expect(header.locator('[data-slot="context-tool-group-prefix"]')).toHaveText("Used")
  await expect(header.locator('[data-slot="context-tool-group-count"]')).toHaveText("65")
  await expect(header.locator('[data-slot="context-tool-group-count"]')).toHaveCSS(
    "font-variant-numeric",
    "tabular-nums",
  )
  await expect(
    header.locator('[data-component="context-tool-group-trigger"] [data-slot="basic-tool-tool-title"]'),
  ).toHaveText("Read, Shell")
  const reads = group.locator('[data-component="read-tool-group"]')
  await expect(reads).toHaveCount(9)
  for (const [index, text] of runs.entries())
    await expect(reads.nth(index).locator('[data-slot="basic-tool-tool-subtitle"]')).toHaveText(text)
  await expect(reads.first().locator('[data-slot="read-tool-group-file"]')).toHaveCount(5)
  await expect(reads.nth(1).locator('[data-slot="read-tool-group-file"]').first()).toHaveAttribute(
    "data-timeline-part-id",
    "read_group_read_2_0",
  )
  await expect(group.locator('[data-slot="context-tool-group-item"]').nth(1)).toHaveText(/^Thought/)

  const thought = group.locator('[data-component="reasoning-part"]').first()
  const color = (locator: typeof thought, slot: string) =>
    locator
      .locator(`[data-slot="${slot}"]`)
      .first()
      .evaluate((node) => getComputedStyle(node).color)
  expect(await color(reads.first(), "basic-tool-tool-title")).toBe(await color(thought, "basic-tool-tool-title"))
  expect(await color(reads.first(), "basic-tool-tool-subtitle")).toBe(await color(thought, "basic-tool-tool-subtitle"))
  const box = await reads.first().boundingBox()
  expect(box?.height).toBe(28)
})

story("truncates long read rows and expands them in place", async ({ mount }) => {
  const root = await mount("current-read-group--used-group", { args: { width: "420" } })
  const reads = root.locator('[data-component="read-tool-group"]')
  await expect(reads.first()).not.toHaveAttribute("role", "button")
  const row = reads.filter({ hasText: "runner.ts" })
  const files = row.locator('[data-slot="basic-tool-tool-subtitle"]')
  await expect(row).toHaveAttribute("role", "button")
  await expect(row).toHaveAttribute("aria-expanded", "false")
  await expect(files).toHaveCSS("text-overflow", "ellipsis")
  const collapsed = (await row.boundingBox())!.height
  await row.click()
  await expect(row).toHaveAttribute("aria-expanded", "true")
  await expect(files).toHaveCSS("white-space", "normal")
  expect((await row.boundingBox())!.height).toBeGreaterThan(collapsed)
  expect(await files.evaluate((node) => node.scrollWidth <= node.clientWidth)).toBe(true)
  await row.press("Enter")
  await expect(row).toHaveAttribute("aria-expanded", "false")
  expect((await row.boundingBox())!.height).toBe(collapsed)
  await row.press(" ")
  await expect(row).toHaveAttribute("aria-expanded", "true")
})

story("points the read row arrow toward the reading direction in RTL", async ({ mount }) => {
  const root = await mount("current-read-group--used-group", { args: { width: "420" }, globals: { direction: "rtl" } })
  const row = root.locator('[data-component="read-tool-group"]').filter({ hasText: "runner.ts" })
  const arrow = row.locator('[data-slot="read-tool-group-arrow"]')
  await expect(row).toHaveAttribute("aria-expanded", "false")
  // rotate(90deg) points the collapsed arrow left, toward the inline end.
  await expect(arrow).toHaveCSS("transform", "matrix(0, 1, -1, 0, 0, 0)")
  await row.click()
  await expect(arrow).toHaveCSS("transform", "none")
})

story("separates read files with the locale's list separators", async ({ mount }) => {
  const root = await mount("current-read-group--used-group", { args: { width: "960" }, globals: { locale: "de" } })
  const reads = root.locator('[data-component="read-tool-group"]')
  await expect(reads.first().locator('[data-slot="basic-tool-tool-subtitle"]')).toHaveText(
    "index.tsx, main.ts, rpc.ts, model.ts und toolbar.tsx",
  )
  // A spaced conjunction starts the next unbreakable file span; a comma ends the previous one.
  await expect(reads.first().locator('[data-slot="read-tool-group-file"]').nth(3)).toHaveText("model.ts")
  await expect(reads.first().locator('[data-slot="read-tool-group-file"]').nth(4)).toHaveText("und toolbar.tsx")
  await expect(reads.first().locator('[data-slot="read-tool-group-file"]').nth(2)).toHaveText("rpc.ts,")
})

story("merges adjacent reads when tools render outside a Used group", async ({ mount }) => {
  const root = await mount("current-read-group--without-used-group", { args: { width: "960" } })
  await expect(root.locator('[data-component="collapsed-tool-group"]')).toHaveCount(0)
  const reads = root.locator('[data-timeline-row="AssistantPart"] [data-component="read-tool-group"]')
  await expect(reads).toHaveCount(9)
  for (const [index, text] of runs.entries())
    await expect(reads.nth(index).locator('[data-slot="basic-tool-tool-subtitle"]')).toHaveText(text)
  await expect(root.locator('[data-component="reasoning-part"]')).toHaveCount(8)
})

story("keeps image, failed and instruction-loading reads on their own rows", async ({ mount }) => {
  const root = await mount("current-read-group--exceptions", { args: { width: "720" } })
  const group = root.locator('[data-component="collapsed-tool-group"]')
  const reads = group.locator('[data-component="read-tool-group"]')
  await expect(reads).toHaveCount(2)
  await expect(reads.nth(0)).toHaveAttribute("data-timeline-part-ids", "read_exception_a,read_exception_b")
  await expect(reads.nth(1)).toHaveAttribute("data-timeline-part-ids", "read_exception_d,read_exception_e")
  await expect(reads.nth(1).locator('[data-slot="basic-tool-tool-subtitle"]')).toHaveText("d.ts, e.ts")
  const items = group.locator('[data-slot="context-tool-group-item"]')
  await expect(items).toHaveCount(5)
  // The image read keeps the Read tool, whose preview opens from its own row.
  await expect(items.nth(1).locator('[data-component="read-tool-group"]')).toHaveCount(0)
  await expect(items.nth(1).getByRole("button", { name: /logo\.png/ })).toBeVisible()
  await expect(items.nth(2)).toContainText("missing.ts")
  await expect(items.nth(3).locator('[data-component="tool-loaded-item"]')).toBeVisible()
})
