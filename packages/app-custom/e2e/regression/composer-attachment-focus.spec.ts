import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"

const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const directory = "/repo/attachment-focus"
const sessionID = "ses_attachment_focus_123456789"

test.use({ serviceWorkers: "block" })

for (const width of [1440, 390]) {
  test(`attachment typing keeps focus, selection, and the session mounted at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 })
    await mockOpenCodeServer(page, {
      directory,
      project: {
        id: "proj_attachment_focus",
        worktree: directory,
        vcs: "git",
        name: "attachment-focus",
        time: { created: 1, updated: 1 },
        sandboxes: [],
      },
      provider: {
        all: [
          {
            id: "opencode",
            name: "OpenCode",
            models: {
              test: {
                id: "test",
                name: "Test",
                capabilities: { tools: true, input: ["text", "image", "pdf"], output: ["text"] },
              },
            },
          },
        ],
        connected: ["opencode"],
        default: { providerID: "opencode", modelID: "test" },
      },
      sessions: [
        {
          id: sessionID,
          projectID: "proj_attachment_focus",
          directory,
          title: "Attachment focus",
          time: { created: 1, updated: 1 },
        },
      ],
      pageMessages: () => ({ items: [] }),
      findFiles: () => [],
    })
    await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
    const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
    await expect(editor).toBeEditable()
    await expect(page.getByRole("button", { name: "Test", exact: true })).toBeVisible()
    if (width === 1440) {
      if ((await page.getByRole("tab", { name: "Context", exact: true }).count()) === 0)
        await page.getByRole("button", { name: "View context usage", exact: true }).click()
      await page.getByRole("tab", { name: "Context", exact: true }).click()
      await expect(page.getByRole("tabpanel", { name: "Context", exact: true })).toBeVisible()
    }
    await editor.click()
    await editor.evaluate((element) => {
      const clipboard = new DataTransfer()
      clipboard.items.add(
        new File(
          [
            Uint8Array.from(
              atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII="),
              (c) => c.charCodeAt(0),
            ),
          ],
          "focus.png",
          { type: "image/png" },
        ),
      )
      element.dispatchEvent(new ClipboardEvent("paste", { clipboardData: clipboard, bubbles: true, cancelable: true }))
    })
    await expect(editor).toHaveText("[focus.png]")
    await expect(page.getByRole("img", { name: "focus.png", exact: true })).toBeVisible()
    // A thumbnail load must never detach the session through its ancestor Suspense boundary.
    const probe = await editor.evaluateHandle((element) => {
      const panel = document.querySelector('[role="tabpanel"]')
      const image = document.querySelector('[data-slot="composer-attachments"] img')
      const state = { removedEditor: 0, removedPanel: 0, removedImage: 0 }
      const observer = new MutationObserver((records) =>
        records.forEach((record) =>
          record.removedNodes.forEach((node) => {
            if (node === element || node.contains(element)) state.removedEditor++
            if (panel && (node === panel || node.contains(panel))) state.removedPanel++
            if (image && (node === image || node.contains(image))) state.removedImage++
          }),
        ),
      )
      observer.observe(document.body, { childList: true, subtree: true })
      return { element, state, observer }
    })
    await editor.click()
    await editor.press("End")
    await page.keyboard.type(" typing")
    await expect(editor).toBeFocused()
    await page.keyboard.press("Backspace")
    await page.keyboard.press("Backspace")
    await expect(editor).toHaveText("[focus.png] typi")
    expect(
      await probe.evaluate(({ element, state, observer }) => {
        observer.disconnect()
        return {
          ...state,
          sameEditor: element === document.querySelector('[role="textbox"][aria-label="Prompt"]'),
          caretInside: element.contains(window.getSelection()?.anchorNode ?? null),
        }
      }),
    ).toEqual({ removedEditor: 0, removedPanel: 0, removedImage: 0, sameEditor: true, caretInside: true })
    await probe.dispose()
    await page.locator('[data-action="remove-attachment"]').click()
    await expect(editor).toHaveText("typi")
    await expect(page.getByRole("img", { name: "focus.png", exact: true })).toHaveCount(0)
    await editor.press("ControlOrMeta+z")
    await expect(editor).toHaveText("[focus.png] typi")
    await expect(page.getByRole("img", { name: "focus.png", exact: true })).toBeVisible()
  })
}
