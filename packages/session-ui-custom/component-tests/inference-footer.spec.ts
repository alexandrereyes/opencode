import { expect, story } from "../../storybook/playwright/story"

for (const width of [1280, 390]) {
  story(`shows inference metadata and trailing actions without hover at ${width}px`, async ({ mount, page }) => {
    await page.setViewportSize({ width, height: 844 })
    const content = await mount("inference-footer--completed")
    const footer = content.locator('[data-slot="text-part-copy-wrapper"]')
    await expect(footer).toHaveCSS("opacity", "1")
    await expect(footer.locator('[data-slot="text-part-meta-item"]')).toHaveText([
      "Claude Sonnet 4",
      "high",
      "build",
      "50.0 tok/s",
      "4s",
      "10/09 17:19",
    ])
    await expect(footer.locator('[data-slot="text-part-meta-item"] svg')).toHaveCount(6)
    await expect(footer.getByRole("button", { name: "Copy response", exact: true })).toBeVisible()
    expect(await footer.evaluate((element) => element.firstElementChild?.getAttribute("data-slot"))).toBe(
      "text-part-meta",
    )
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  })
}

story("aggregates model throughput and includes tool time only in total duration", async ({ mount }) => {
  const content = await mount("inference-footer--multi-step")
  const footer = content.locator('[data-slot="text-part-copy-wrapper"]')
  await expect(footer).toHaveCount(1)
  await expect(footer.locator('[data-slot="text-part-meta-item"]')).toHaveText([
    "Claude Sonnet 4",
    "high",
    "build",
    "40.0 tok/s",
    "34s",
    "10/09 17:19",
  ])
})

story("resets footer metrics at a synthetic input like the TUI", async ({ mount }) => {
  const content = await mount("inference-footer--synthetic-input")
  const footer = content.locator('[data-slot="text-part-copy-wrapper"]')
  await expect(footer).toHaveCount(1)
  await expect(footer.locator('[data-slot="text-part-meta-item"]')).toHaveText([
    "Claude Sonnet 4",
    "high",
    "build",
    "50.0 tok/s",
    "12s",
    "10/09 17:19",
  ])
})

story("omits throughput when an earlier inference has no stream boundary", async ({ mount }) => {
  const content = await mount("inference-footer--missing-stream")
  const footer = content.locator('[data-slot="text-part-copy-wrapper"]')
  await expect(footer).toHaveCount(1)
  await expect(footer.locator('[data-slot="text-part-meta-item"]')).toHaveText([
    "Claude Sonnet 4",
    "high",
    "build",
    "34s",
    "10/09 17:19",
  ])
})
