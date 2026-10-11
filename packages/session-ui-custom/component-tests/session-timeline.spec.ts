import { expect, story } from "../../storybook/playwright/story"

story("aligns the subagent icon with the progress spinner", async ({ mount, page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" })
  const timeline = await mount("current-session-research-agents--delegate-focused-tasks")
  await timeline.locator('[data-component="collapsed-tool-group"] [data-slot="collapsible-trigger"]').click()
  const icon = timeline.locator('[data-component="task-tool-icon"] [data-slot="icon-svg"]')
  const spinner = timeline.locator(
    '[data-component="task-tool-spinner"] [data-component="session-progress-indicator-v2"]',
  )
  await expect(icon).toHaveCount(1)
  await expect(spinner).toHaveCount(1)
  const centered = (svg: typeof icon, selector: string) =>
    svg.evaluate((element, selector) => {
      const box = element.getBoundingClientRect()
      const mark = element.querySelector(selector)!.getBoundingClientRect()
      return {
        size: [box.width, box.height],
        inset: [mark.left - box.left, box.right - mark.right, mark.top - box.top, box.bottom - mark.bottom],
      }
    }, selector)
  const iconGeometry = await centered(icon, "use")
  const spinnerGeometry = await centered(spinner, "[data-reduced-motion]")
  expect(iconGeometry.size).toEqual(spinnerGeometry.size)
  expect(iconGeometry.inset).toEqual([1, 1, 1, 1])
  expect(spinnerGeometry.inset).toEqual([7, 7, 7, 7])
})

for (const width of [1280, 390]) {
  story(`shows the model variant in user message metadata at ${width}px`, async ({ mount, page }) => {
    await page.setViewportSize({ width, height: 844 })
    const timeline = await mount("current-session-error-spacing--error-and-updates")
    const meta = timeline.locator('[data-slot="user-message-meta-wrap"]')
    const variant = meta.locator('[data-slot="user-message-meta-variant"]')
    await expect(meta.locator('[data-slot="user-message-meta"]')).toHaveText("Build\u00A0·\u00A0Claude Sonnet 4")
    await expect(variant).toHaveText("balanced")
    await expect(variant.locator('[data-slot="icon-svg"]')).toHaveCount(1)
    await expect(meta.locator('[data-slot="user-message-meta-sep"]')).toHaveCount(2)
    await expect(meta.locator('[data-slot="user-message-meta-tail"]')).not.toBeEmpty()
    expect(await meta.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true)
  })
}

story("omits a default model variant from user and assistant metadata", async ({ mount }) => {
  const timeline = await mount("inference-footer--default-variant")
  const user = timeline.locator('[data-slot="user-message-meta-wrap"]')
  await expect(user.locator('[data-slot="user-message-meta"]')).toHaveText("Build\u00A0·\u00A0Claude Sonnet 4")
  await expect(user.locator('[data-slot="user-message-meta-variant"]')).toHaveCount(0)
  await expect(user.locator('[data-slot="user-message-meta-sep"]')).toHaveCount(1)
  const footer = timeline.locator('[data-slot="text-part-meta"]')
  await expect(footer.locator('[data-slot="text-part-meta-item"]')).toHaveText([
    "Claude Sonnet 4",
    "build",
    /tok\/s$/,
    /^\d+s$/,
    /^\d{2}\/\d{2} \d{2}:\d{2}$/,
  ])
  await expect(footer.locator('[data-slot="text-part-meta-item"] svg')).toHaveCount(5)
  await expect(footer.locator('use[href="#opencode-v2-icon-brain"]')).toHaveCount(0)
})

story("omits a missing model variant from user message metadata", async ({ mount }) => {
  const timeline = await mount("current-session-timeline-rows--conversation", { args: { scenario: "interruption" } })
  await expect(timeline.locator('[data-slot="user-message-meta"]')).toContainText("Build")
  await expect(timeline.locator('[data-slot="user-message-meta-variant"]')).toHaveCount(0)
  await expect(timeline.locator('[data-slot="user-message-meta-sep"]')).toHaveCount(1)
})

story("spaces an error between a shell result and expanded updates", async ({ mount }) => {
  const timeline = await mount("current-session-error-spacing--error-and-updates")
  const shell = timeline.locator('[data-component="bash-output"]')
  const error = timeline.locator('[data-kind="session-error-card"]')
  const updates = timeline.locator('[data-component="collapsed-tool-group"] [data-slot="collapsible-trigger"]')
  await expect(updates.locator('[data-slot="context-tool-group-prefix"]')).toHaveText("Updates")
  const shellBox = (await shell.boundingBox())!
  const errorBox = (await error.boundingBox())!
  const updatesBox = (await updates.boundingBox())!
  expect(errorBox.y - (shellBox.y + shellBox.height)).toBe(24)
  expect(updatesBox.y - (errorBox.y + errorBox.height)).toBe(8)
  expect(updatesBox.x).toBe(errorBox.x)
  await updates.click()
  const notice = timeline.locator('[data-slot="session-timeline-notice"]')
  await expect(notice).toContainText("Instructions updated")
  const expandedBox = (await updates.boundingBox())!
  expect((await notice.boundingBox())!.y - (expandedBox.y + expandedBox.height)).toBe(0)
  expect((await notice.boundingBox())!.x - expandedBox.x).toBe(12)
  expect(expandedBox.height).toBe(28)
})

story("spaces an error after a final answer without moving its divider", async ({ mount }) => {
  const timeline = await mount("current-session-error-spacing--final-answer-error-and-updates")
  const divider = timeline.locator('[data-timeline-row="FinalAnswerDivider"]')
  const answer = timeline.locator('[data-component="text-part"]')
  const error = timeline.locator('[data-kind="session-error-card"]')
  const updates = timeline.locator('[data-component="collapsed-tool-group"] [data-slot="collapsible-trigger"]')
  await expect(divider).toHaveAttribute("data-timeline-spacing", "content")
  await expect(divider).toHaveCSS("padding-top", "16px")
  const dividerBox = (await divider.locator('[data-slot="session-final-answer-divider"]').boundingBox())!
  const answerBox = (await answer.boundingBox())!
  const errorBox = (await error.boundingBox())!
  const updatesBox = (await updates.boundingBox())!
  expect(answerBox.y - (dividerBox.y + dividerBox.height)).toBe(36)
  expect(errorBox.y - (answerBox.y + answerBox.height)).toBe(24)
  expect(updatesBox.y - (errorBox.y + errorBox.height)).toBe(8)
})

story("centers the error icon on the first line of short and wrapped errors", async ({ mount }) => {
  const timeline = await mount("current-session-error-card--provider-errors")
  const cards = timeline.locator('[data-kind="session-error-card"]')
  await expect(cards).toHaveCount(2)
  const geometry = await cards.evaluateAll((elements) =>
    elements.map((card) => {
      const icon = card.querySelector('[data-slot="icon-svg"]')!.getBoundingClientRect()
      const message = card.querySelector('[data-slot="icon-svg"] + div')!
      const line = parseFloat(getComputedStyle(message).lineHeight)
      const box = message.getBoundingClientRect()
      return {
        lines: Math.round(box.height / line),
        offset: icon.top + icon.height / 2 - (box.top + line / 2),
      }
    }),
  )
  expect(geometry.map((card) => card.lines > 1)).toEqual([false, true])
  geometry.forEach((card) => expect(card.offset).toBeCloseTo(0, 0))
})

for (const width of [1280, 390]) {
  for (const streaming of [false, true]) {
    story(
      `renders Mermaid in the ${streaming ? "streaming" : "completed"} timeline at ${width}px`,
      async ({ mount, page }) => {
        await page.setViewportSize({ width, height: 900 })
        const root = await mount("current-session-mermaid--diagrams", { args: { streaming } })
        const timeline = root.locator('[data-component="session-timeline"]')
        const diagrams = timeline.locator('[data-component="markdown-mermaid"] > svg')
        await expect(diagrams).toHaveCount(2)
        await expect(diagrams.nth(0)).toBeVisible()
        await expect(diagrams.nth(0)).toContainText("Client")
        await expect(diagrams.nth(1)).toBeVisible()
        await expect(diagrams.nth(1)).toContainText("Send prompt")
        await expect(timeline.locator('[data-mermaid-ready="true"]')).toHaveCount(2)
        await expect(timeline.locator('[data-mermaid-ready="true"] > pre:visible')).toHaveCount(0)
        if (streaming) {
          await root.getByRole("button", { name: "Complete response" }).click()
          await expect(timeline.locator('[data-markdown-complete="true"]')).toHaveCount(2)
          await expect(diagrams).toHaveCount(2)
          await expect(diagrams.nth(0)).toBeVisible()
          await expect(diagrams.nth(1)).toBeVisible()
        }
      },
    )
  }
}

story("renders streamed reasoning without starting the app", async ({ mount }) => {
  const timeline = await mount("current-session-timeline-rows--streaming-reasoning-and-text")
  await expect(timeline.locator('[data-component="session-timeline"]')).toBeVisible()
  await timeline.locator('[data-component="reasoning-part"] [data-slot="collapsible-trigger"]').click()
  await expect(timeline.getByText("Checking the current contract", { exact: true })).toBeVisible()
})

story("aligns the retry icon with the error label", async ({ mount }) => {
  const timeline = await mount("current-session-timeline-rows--provider-retry")
  const card = timeline.locator('[data-kind="session-retry-card"]')
  const icon = card.locator('[data-slot="icon-svg"]')
  const label = card.locator('[data-slot="session-turn-retry-message"]')
  await expect(icon).toBeVisible()
  await expect(label).toBeVisible()
  const [iconY, labelY] = await Promise.all([
    icon.evaluate((element) => element.getBoundingClientRect().y),
    label.evaluate((element) => element.getBoundingClientRect().y),
  ])

  expect(iconY).toBe(labelY)
})

// Moved from packages/app/e2e/regression/session-timeline-context-state.spec.ts
story("preserves a collapsed context group through count and status updates", async ({ mount }) => {
  const timeline = await mount("current-session-research-agents--agent-research", { args: { scenario: "exploration" } })
  const group = timeline.locator('[data-timeline-part-ids="tool_context_read,tool_context_glob"]')
  const trigger = group.locator('[data-slot="collapsible-trigger"]')
  await expect(trigger).toHaveAttribute("aria-expanded", "false")
  await timeline.getByRole("button", { name: "Complete read" }).click()
  await expect(trigger).toHaveAttribute("aria-expanded", "false")
  await timeline.getByRole("button", { name: "Complete glob" }).click()
  await expect(trigger).toHaveAttribute("aria-expanded", "false")
})

// Moved from packages/app/e2e/regression/session-timeline-accessibility.spec.ts
story("space activates a focused timeline button instead of scrolling", async ({ mount, page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" })
  await page.setViewportSize({ width: 800, height: 240 })
  const timeline = await mount("current-session-terminal-work--terminal-commands", { args: { scenario: "collapsed" } })
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollHeight - innerHeight)).toBeGreaterThan(0)
  const trigger = timeline.getByRole("button", { name: "Used 1 Shell", exact: true })
  await expect(trigger).toHaveAttribute("aria-expanded", "false")
  await trigger.focus()
  const before = await page.evaluate(() => window.scrollY)
  await trigger.press("Space")
  await expect(trigger).toHaveAttribute("aria-expanded", "true")
  expect(await page.evaluate(() => window.scrollY)).toBe(before)
})

// Moved from packages/app/e2e/regression/session-timeline-file-projection.spec.ts
story("renders a completed write through the production file component", async ({ mount }) => {
  const timeline = await mount("current-session-file-changes--changing-files", { args: { scenario: "write" } })
  const write = timeline.locator('[data-timeline-part-id="prt_file_projection_write"]')
  await expect(write.locator('[data-component="apply-patch-file-diff"]')).toBeVisible()
  await expect(write).toContainText("export const written = true")
})

// Moved from packages/app/e2e/regression/session-timeline-file-state.spec.ts
story("keeps patch file disclosures independent", async ({ mount }) => {
  const timeline = await mount("current-session-file-changes--changing-files", { args: { scenario: "patch" } })
  const wrapper = timeline.locator('[data-timeline-part-id="prt_nested_patch"]')
  const modified = wrapper.locator('[data-scope="apply-patch"] [data-type="update"] button')
  const added = wrapper.locator('[data-scope="apply-patch"] [data-type="add"] button')
  const deleted = wrapper.locator('[data-scope="apply-patch"] [data-type="delete"] button')
  await expect(wrapper.locator('[data-scope="apply-patch"] [aria-expanded="false"]')).toHaveCount(3)
  await deleted.click()
  await expect(deleted).toHaveAttribute("aria-expanded", "true")
  await expect(modified).toHaveAttribute("aria-expanded", "false")
  await modified.click()
  await expect(modified).toHaveAttribute("aria-expanded", "true")
  await deleted.click()
  await expect(deleted).toHaveAttribute("aria-expanded", "false")
  await expect(modified).toHaveAttribute("aria-expanded", "true")
  await expect(added).toHaveAttribute("aria-expanded", "false")
  await added.click()
  await expect(added).toHaveAttribute("aria-expanded", "true")
  await expect(modified).toHaveAttribute("aria-expanded", "true")
  await expect(deleted).toHaveAttribute("aria-expanded", "false")
})
