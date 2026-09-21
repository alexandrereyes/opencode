import { expect, story } from "../../storybook/playwright/story"

for (const width of [390, 1280]) {
  for (const direction of ["ltr", "rtl"]) {
    story(`keeps long question actions reachable at ${width}px ${direction}`, async ({ mount, page }) => {
      await page.setViewportSize({ width, height: 700 })
      const component = await mount("app-current-session-surface--long-question-request", {
        globals: { direction },
      })
      const dock = component.locator('[data-component="dock-prompt"][data-kind="question"]')
      const content = dock.locator('[data-slot="question-content"]')
      await expect(dock.locator('[data-slot="question-header-topic"]')).toHaveText("Layout")
      await expect(dock.locator('[data-slot="question-header-summary"]')).toHaveText("Question 1 of 2 in this round")
      const next = dock.getByRole("button", { name: "Next", exact: true })
      await expect(next).toBeInViewport({ ratio: 1 })
      await expect.poll(() => content.evaluate((el) => el.scrollHeight > el.clientHeight)).toBe(true)
      await dock.getByRole("radio", { name: /^Release scope 8/ }).click()
      await expect(next).toBeInViewport({ ratio: 1 })
      await next.click()
      await expect(dock.locator('[data-slot="question-header-topic"]')).toHaveText("Include")
      await expect(dock.locator('[data-slot="question-header-summary"]')).toHaveText("Question 2 of 2 in this round")
      const submit = dock.getByRole("button", { name: "Submit", exact: true })
      await expect(submit).toBeInViewport({ ratio: 1 })
      await dock.getByRole("checkbox", { name: /^Release scope 1/ }).focus()
      await page.keyboard.press("End")
      await expect(dock.getByRole("checkbox", { name: /Type your own answer/ })).toBeFocused()
      await page.keyboard.press("Enter")
      await dock.locator("textarea").fill("A custom release scope")
      await page.setViewportSize({ width, height: 420 })
      await expect(submit).toBeInViewport({ ratio: 1 })
      await dock.getByRole("button", { name: "Back", exact: true }).click()
      await expect(dock.getByRole("radio", { name: /^Release scope 8/ })).toHaveAttribute("aria-checked", "true")
      await next.click()
      await expect(dock.getByRole("checkbox", { name: /Type your own answer/ })).toContainText("A custom release scope")
      await expect(submit).toBeInViewport({ ratio: 1 })
      await submit.click()
      await expect(component.getByRole("status")).toHaveText("Submitted the answer locally")
    })
  }
}

story("keeps the text answer above a keyboard that only resizes the visual viewport", async ({ mount, page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const component = await mount("app-current-session-surface--long-question-request")
  const dock = component.locator('[data-component="dock-prompt"][data-kind="question"]')
  await dock.getByRole("radio", { name: /Type your own answer/ }).click()
  const input = dock.locator("textarea")
  await input.fill("Keep this answer while the keyboard opens")

  // Desktop automation has no native iOS keyboard. Preserve the layout viewport
  // while reproducing its visual viewport resize and subsequent focus pan.
  for (const offset of [0, 120]) {
    await page.evaluate((offset) => {
      const viewport = window.visualViewport!
      Object.defineProperties(viewport, {
        height: { configurable: true, value: 390 },
        offsetTop: { configurable: true, value: offset },
        pageTop: { configurable: true, value: offset },
      })
      viewport.dispatchEvent(new Event("resize"))
      viewport.dispatchEvent(new Event("scroll"))
    }, offset)
    await expect
      .poll(() =>
        dock.evaluate((element) => {
          const viewport = window.visualViewport!
          const field = element.querySelector("textarea")!.getBoundingClientRect()
          const content = element.querySelector('[data-slot="question-content"]')!.getBoundingClientRect()
          const footer = element.querySelector('[data-slot="question-footer"]')!.getBoundingClientRect()
          return (
            field.top >= Math.max(content.top, viewport.offsetTop) &&
            field.bottom <= content.bottom &&
            footer.bottom <= viewport.offsetTop + viewport.height
          )
        }),
      )
      .toBe(true)
    await expect(input).toBeFocused()
    await expect(input).toHaveValue("Keep this answer while the keyboard opens")
  }
  await page.evaluate(() => {
    const viewport = window.visualViewport!
    Object.defineProperties(viewport, {
      height: { configurable: true, value: 844 },
      offsetTop: { configurable: true, value: 0 },
      pageTop: { configurable: true, value: 0 },
    })
    viewport.dispatchEvent(new Event("resize"))
  })
  await expect(component.locator('[data-component="session-question-dock"]')).toHaveCSS("padding-bottom", "0px")
  await expect(dock.getByRole("button", { name: "Next", exact: true })).toBeInViewport({ ratio: 1 })
})

story("keeps the question expanded when WebKit pans client rectangles with the keyboard", async ({ mount, page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const component = await mount("app-current-session-surface--long-question-request")
  const dock = component.locator('[data-component="dock-prompt"][data-kind="question"]')
  await dock.getByRole("radio", { name: /Type your own answer/ }).click()
  await dock.locator("textarea").fill("Answer during viewport panning")
  // Model WebKit's visual-relative DOMRects, not just a smaller viewport.
  await page.evaluate(() => {
    document.documentElement.style.transform = "translateY(-450px)"
    Object.defineProperties(window.visualViewport!, {
      height: { configurable: true, value: 390 },
      offsetTop: { configurable: true, value: 450 },
      pageTop: { configurable: true, value: 450 },
    })
    window.visualViewport!.dispatchEvent(new Event("resize"))
    window.visualViewport!.dispatchEvent(new Event("scroll"))
  })
  await expect
    .poll(() =>
      dock.evaluate((element) => {
        const input = element.querySelector("textarea")!.getBoundingClientRect()
        const content = element.querySelector('[data-slot="question-content"]')!.getBoundingClientRect()
        const footer = element.querySelector('[data-slot="question-footer"]')!.getBoundingClientRect()
        return (
          content.height >= 100 &&
          input.top >= Math.max(0, content.top) &&
          input.bottom <= content.bottom &&
          footer.bottom <= 390
        )
      }),
    )
    .toBe(true)
  await expect(dock.locator("textarea")).toBeFocused()
  await expect(dock.locator("textarea")).toHaveValue("Answer during viewport panning")
})
