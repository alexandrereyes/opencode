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
      const next = dock.getByRole("button", { name: "Next", exact: true })
      await expect(next).toBeInViewport({ ratio: 1 })
      await expect.poll(() => content.evaluate((el) => el.scrollHeight > el.clientHeight)).toBe(true)
      await dock.getByRole("radio", { name: /^Release scope 8/ }).click()
      await expect(next).toBeInViewport({ ratio: 1 })
      await next.click()
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
