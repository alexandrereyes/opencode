import { expect, story } from "../../storybook/playwright/story"

for (const earlier of ["tool", "text", "reasoning"]) {
  story(`separates the completed final answer after ${earlier}`, async ({ mount }) => {
    const root = await mount("current-session-final-answer--divider", { args: { earlier, completed: false } })
    const divider = root.locator('[data-slot="session-final-answer-divider"]')
    await expect(root.getByText("The project configuration is consistent.", { exact: true })).toBeVisible()
    await expect(divider).toHaveCount(0)
    await root.getByRole("button", { name: "Complete response", exact: true }).click()
    await expect(divider).toHaveCount(1)
    await expect(divider).toBeVisible()
    await expect(root.getByText("The project configuration is consistent.", { exact: true })).toBeVisible()
    const dividerRow = root.locator('[data-timeline-row="FinalAnswerDivider"]')
    const answerRow = root
      .locator('[data-timeline-row="AssistantPart"]')
      .filter({ hasText: "The project configuration is consistent." })
    await expect(dividerRow).toHaveCSS("padding-top", "16px")
    await expect(divider).toHaveCSS("margin-bottom", "12px")
    await expect(answerRow).toHaveCSS("padding-top", "0px")
    await root.getByRole("button", { name: "Stream response", exact: true }).click()
    await expect(divider).toHaveCount(0)
  })
}

story("keeps the divider before the first final answer when a subagent finishes late", async ({ mount }) => {
  const root = await mount("current-session-final-answer--late-subagent")
  const divider = root.locator('[data-slot="session-final-answer-divider"]')
  const first = root.getByText("The project configuration is consistent.", { exact: true })
  const second = root.getByText("The last agent added another detail.", { exact: true })
  await expect(divider).toHaveCount(1)
  await expect(first).toBeVisible()
  await expect(second).toBeVisible()
  const dividerBounds = await root.locator('[data-timeline-row="FinalAnswerDivider"]').boundingBox()
  const firstBounds = await root
    .locator('[data-timeline-row="AssistantPart"]')
    .filter({ hasText: "The project configuration is consistent." })
    .boundingBox()
  const secondBounds = await root
    .locator('[data-timeline-row="AssistantPart"]')
    .filter({ hasText: "The last agent added another detail." })
    .boundingBox()
  expect(dividerBounds!.y).toBeLessThan(firstBounds!.y)
  expect(firstBounds!.y).toBeLessThan(secondBounds!.y)
})

const unseparated: Record<string, string | boolean>[] = [
  { earlier: "none" },
  { earlier: "reasoning", hideReasoning: true },
  { earlier: "notice", notices: "hidden" },
  { finish: "tool-calls" },
  { finish: "length" },
  { finish: "error" },
]
for (const args of unseparated) {
  story(`does not separate a non-final or standalone answer: ${JSON.stringify(args)}`, async ({ mount }) => {
    const root = await mount("current-session-final-answer--divider", { args })
    await expect(root.getByText("The project configuration is consistent.", { exact: true })).toBeVisible()
    await expect(root.locator('[data-slot="session-final-answer-divider"]')).toHaveCount(0)
  })
}

for (const notices of ["separate", "grouped"]) {
  story(`separates the final answer after a ${notices} subagent notice`, async ({ mount }) => {
    const root = await mount("current-session-final-answer--divider", { args: { earlier: "notice", notices } })
    await expect(root.getByText("The project configuration is consistent.", { exact: true })).toBeVisible()
    await expect(root.locator('[data-slot="session-final-answer-divider"]')).toBeVisible()
  })
}

for (const theme of ["light", "dark"]) {
  for (const width of [390, 1280]) {
    story(`final answer divider fits the ${theme} timeline at ${width}px`, async ({ mount, page }) => {
      await page.setViewportSize({ width, height: 800 })
      const root = await mount("current-session-final-answer--divider", { globals: { theme } })
      const divider = root.locator('[data-slot="session-final-answer-divider"]')
      await expect(divider).toBeVisible()
      await expect(divider).toHaveCSS("height", "1px")
      await expect(divider).toHaveAttribute("aria-hidden", "true")
      const bounds = await divider.boundingBox()
      expect(bounds!.width).toBeGreaterThan(0)
      expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width)
    })
  }
}
