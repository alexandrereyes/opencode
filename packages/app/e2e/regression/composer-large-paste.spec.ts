import { expect, test, type Locator } from "@playwright/test"
import { copyComposerText, expectComposerText, readComposerText } from "../utils/composer"
import { pressPlatformShortcut } from "../utils/command-palette"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectAppVisible } from "../utils/waits"

const draftID = "draft_large_paste"
const directory = "/repo/large-paste"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test.use({ permissions: ["clipboard-read", "clipboard-write"] })

test.beforeEach(async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "proj_large_paste",
      worktree: directory,
      vcs: "git",
      name: "large-paste",
      time: { created: 1700000000000, updated: 1700000000000 },
      sandboxes: [],
    },
    provider: { all: [], connected: [], default: {} },
    sessions: [],
    pageMessages: () => ({ items: [] }),
  })
  await page.addInitScript(
    ({ directory, draftID, server }) => {
      localStorage.setItem("opencode-theme-id", "oc-2")
      localStorage.setItem("opencode-color-scheme", "dark")
      localStorage.setItem(
        "opencode.global.dat:server",
        JSON.stringify({
          projects: { local: [{ worktree: directory, expanded: true }] },
          lastProject: { local: directory },
        }),
      )
      localStorage.setItem(
        "opencode.window.browser.dat:tabs",
        JSON.stringify([{ type: "draft", draftID, server, directory }]),
      )
    },
    { directory, draftID, server },
  )
  await page.goto(`/new-session?draftId=${draftID}`)
  const input = page.locator('[data-component="composer-editor"]')
  await expectAppVisible(input)
  await expect(input).toBeEditable()
  await input.click()
})

for (const lines of [6000, 25000]) {
  test(`keeps a ${lines}-line crash report editable in a new session`, async ({ page }) => {
    const input = page.getByRole("textbox", { name: "Prompt", exact: true })
    const mac = await page.evaluate(() => navigator.platform.startsWith("Mac"))
    const text = "Thread 0 Crashed:\n" + "0   Example  0x0000000100000000 frame + 32\n".repeat(lines) + "End of report"
    await page.evaluate((text) => navigator.clipboard.writeText(text), text)
    await page.keyboard.press("ControlOrMeta+V")
    await expect(input).toBeFocused()
    await expectCaretVisible(input)
    await expect(input.locator(".cm-line").filter({ hasText: "End of report" })).toBeVisible()
    const scroll = page.locator('[data-component="composer-scroll"]')
    await expect(scroll.locator(".scroll-view__viewport")).toHaveCSS("scrollbar-width", "none")
    await expect(scroll.locator(".scroll-view__thumb")).toBeVisible()
    await page.keyboard.type("!")
    await expectCaretVisible(input)
    await expect(input.locator(".cm-line").filter({ hasText: "End of report!" })).toBeVisible()
    const thumb = await scroll.locator(".scroll-view__thumb").boundingBox()
    const bounds = await scroll.boundingBox()
    if (!thumb || !bounds) throw new Error("Missing composer scrollbar bounds")
    await page.mouse.move(thumb.x + thumb.width / 2, thumb.y + thumb.height / 2)
    await page.mouse.down()
    await page.mouse.move(thumb.x + thumb.width / 2, bounds.y + 8 + thumb.height / 2)
    await page.mouse.up()
    await expect(scroll.locator(".scroll-view__viewport")).toHaveJSProperty("scrollTop", 0)
    await expect(input).toBeFocused()
    await pressPlatformShortcut(page, mac ? "ArrowUp" : "Home")
    await expect(input.locator(".cm-line").filter({ hasText: "Thread 0 Crashed:" })).toBeVisible()
    await pressPlatformShortcut(page, mac ? "ArrowDown" : "End")
    await expectCaretVisible(input)
    await expect(input.locator(".cm-line").filter({ hasText: "End of report!" })).toBeVisible()
    expect(await copyComposerText(page, input)).toBe(text + "!")
  })
}

async function expectCaretVisible(input: Locator) {
  await expect
    .poll(() =>
      input.evaluate((element) => {
        const selection = window.getSelection()
        if (!selection?.isCollapsed || !selection.rangeCount || !element.contains(selection.anchorNode)) return false
        const caret = selection.getRangeAt(0).getBoundingClientRect()
        const viewport = (element.closest("[data-scrollable]") ?? element).getBoundingClientRect()
        return caret.height > 0 && caret.top >= viewport.top - 1 && caret.bottom <= viewport.bottom + 1
      }),
    )
    .toBe(true)
}

for (const width of [390, 1280]) {
  for (const direction of ["ltr", "rtl"]) {
    test(`reveals a multiline paste in the middle at ${width}px in ${direction}`, async ({ page }) => {
      await page.setViewportSize({ width, height: 800 })
      await page.evaluate((direction) => (document.documentElement.dir = direction), direction)
      const input = page.getByRole("textbox", { name: "Prompt", exact: true })
      const suffix = "\nExisting trailing content".repeat(100)
      await input.fill("Before " + suffix)
      await input.press("ControlOrMeta+a")
      await page.keyboard.press("ArrowLeft")
      await page.keyboard.press("ArrowRight")
      const text = "Pasted line /tmp/example.ts 123 \u0645\u0631\u062d\u0628\u0627\n".repeat(100) + "End of paste"
      await input.evaluate((element, text) => {
        const clipboard = new DataTransfer()
        clipboard.setData("text/plain", text)
        element.dispatchEvent(
          new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: clipboard }),
        )
      }, text)
      await expectCaretVisible(input)
      await page.keyboard.type("!")
      await expectCaretVisible(input)
      expect(await readComposerText(page, input)).toBe("B" + text + "!efore " + suffix)
    })
  }
}

for (const text of [
  "single line <b> &amp;",
  "first\nsecond",
  "\n\n  indented\ttext  \n\nlast\n\n",
  'literal <b>bold</b> &amp; & < > "quotes"\n<script>not code</script>\n<img src="example">',
  "first\r\nsecond\rthird",
]) {
  test(`preserves text and native undo: ${JSON.stringify(text)}`, async ({ page }) => {
    const input = page.getByRole("textbox", { name: "Prompt", exact: true })
    const mac = await page.evaluate(() => navigator.platform.startsWith("Mac"))
    await page.evaluate((text) => navigator.clipboard.writeText(text), text)
    await page.keyboard.press("ControlOrMeta+V")
    const expected = text.replace(/\r\n?/g, "\n")
    await expectComposerText(input, expected)
    await expect(input.locator("b, script, img")).toHaveCount(0)
    await pressPlatformShortcut(page, "Z")
    await expectComposerText(input, "")
    await pressPlatformShortcut(page, mac ? "Shift+Z" : "Y")
    await expectComposerText(input, expected)
  })
}

test("replaces only the selected text and leaves the caret after the paste", async ({ page }) => {
  const input = page.getByRole("textbox", { name: "Prompt", exact: true })
  const mac = await page.evaluate(() => navigator.platform.startsWith("Mac"))
  await page.evaluate(() => navigator.clipboard.writeText("one\ntwo"))
  await input.fill("before replace after")
  await expect(input).toHaveText("before replace after")
  await input.press("Home")
  for (let index = 0; index < "before ".length; index++) await input.press("ArrowRight")
  for (let index = 0; index < "replace".length; index++) await input.press("Shift+ArrowRight")
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("one\ntwo")
  await expect(input).toBeFocused()
  await input.press("ControlOrMeta+V")
  await expectComposerText(input, "before one\ntwo after")
  await page.keyboard.type("!")
  await expectComposerText(input, "before one\ntwo! after")
  await pressPlatformShortcut(page, "Z")
  await expect(input).toHaveText("before replace after")
  await pressPlatformShortcut(page, mac ? "Shift+Z" : "Y")
  await expectComposerText(input, "before one\ntwo! after")
})
