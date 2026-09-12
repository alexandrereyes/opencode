import { expect, type Locator, type Page } from "@playwright/test"

export async function expectComposerText(editor: Locator, expected: string) {
  await expect
    .poll(() =>
      editor.locator(".cm-line").evaluateAll((lines) => lines.map((line) => line.textContent ?? "").join("\n")),
    )
    .toBe(expected)
}

export async function copyComposerText(page: Page, editor: Locator) {
  const modifier = await page.evaluate(() => (/(Mac|iPod|iPhone|iPad)/.test(navigator.platform) ? "Meta" : "Control"))
  await editor.press(`${modifier}+a`)
  await editor.press("ControlOrMeta+c")
  return page.evaluate(() => navigator.clipboard.readText())
}

export async function readComposerText(page: Page, editor: Locator) {
  const modifier = await page.evaluate(() => (/(Mac|iPod|iPhone|iPad)/.test(navigator.platform) ? "Meta" : "Control"))
  await editor.press(`${modifier}+a`)
  return editor.evaluate((element) => {
    const clipboard = new DataTransfer()
    element.dispatchEvent(new ClipboardEvent("copy", { bubbles: true, cancelable: true, clipboardData: clipboard }))
    return clipboard.getData("text/plain")
  })
}
