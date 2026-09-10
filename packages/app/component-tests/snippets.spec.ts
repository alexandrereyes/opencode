import { expect, story } from "../../storybook/playwright/story"

story("prefixing a command preserves an inserted snippet and its expansion", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--snippets")
  const input = component.getByRole("textbox", { name: "Prompt", exact: true })
  await input.fill("#audit")
  await expect(component.getByRole("button", { name: "#code-review Review for correctness and clarity" })).toBeVisible()
  await input.press("Tab")
  await component.getByRole("button", { name: "Add images and files" }).click()
  await page.getByRole("menuitem", { name: "Commands" }).click()
  await component.getByRole("button", { name: "/review", exact: true }).click()
  await expect(input).toHaveText("/review #code-review ")
  await expect(input.locator('[data-mention="snippet"]')).toHaveText("#code-review")
  await input.press("Enter")
  await expect(component.getByRole("status")).toContainText(
    '"text":"/review Review this code for correctness.\\nSuggest concrete improvements. "',
  )
})

for (const theme of ["light", "dark"]) {
  story(`snippets search by alias, insert at the cursor and expand on send in ${theme}`, async ({ mount, page }) => {
    const component = await mount("opencode-composer-flow--snippets", { globals: { theme } })
    const input = component.getByRole("textbox", { name: "Prompt", exact: true })
    await input.fill("Before #audit after")
    await input.evaluate((editor) => {
      const selection = window.getSelection()
      const range = document.createRange()
      range.setStart(editor.firstChild!, 13)
      range.collapse(true)
      selection?.removeAllRanges()
      selection?.addRange(range)
      editor.dispatchEvent(new InputEvent("input", { bubbles: true }))
    })
    await expect(
      component.getByRole("button", { name: "#code-review Review for correctness and clarity" }),
    ).toBeVisible()
    await page.keyboard.press("Tab")
    const token = input.locator('[data-mention="snippet"]')
    await expect(token).toHaveText("#code-review")
    await expect(token).toHaveAttribute("contenteditable", "false")
    expect(await token.evaluate((element) => getComputedStyle(element).color)).not.toBe(
      await input.evaluate((element) => getComputedStyle(element).color),
    )
    await page.keyboard.type("INSERT")
    await expect(input).toHaveText("Before #code-review INSERT after")
    await page.keyboard.press("Enter")
    await expect(component.getByRole("status")).toContainText(
      '"text":"Before Review this code for correctness.\\nSuggest concrete improvements. INSERT after"',
    )
    await expect(input).toBeEmpty()
    await page.setViewportSize({ width: 390, height: 844 })
    await input.fill("#verify")
    await expect(component.getByRole("button", { name: "#tests Run focused tests" })).toBeInViewport()
    await page.keyboard.press("Escape")
    await expect(component.locator('[data-component="composer-suggestions"]')).toHaveCount(0)
    await expect(input).toHaveText("#verify")
  })
}
