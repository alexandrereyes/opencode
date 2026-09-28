import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"

const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const directory = "/repo/attachment-touch"
const sessionID = "ses_attachment_touch_123456789"

test.use({
  serviceWorkers: "block",
  hasTouch: true,
  isMobile: true,
  viewport: { width: 390, height: 844 },
  // Headless Chrome hands the first navigation a spare renderer that misses touch hover/pointer emulation.
  launchOptions: { args: ["--disable-features=SpareRendererForSitePerProcess"] },
})

test("attachment remove buttons stay visible without hover on touch devices", async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "proj_attachment_touch",
      worktree: directory,
      vcs: "git",
      name: "attachment-touch",
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
        projectID: "proj_attachment_touch",
        directory,
        title: "Attachment touch",
        time: { created: 1, updated: 1 },
      },
    ],
    pageMessages: () => ({ items: [] }),
    subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
  })
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  expect(await page.evaluate(() => matchMedia("(hover: none)").matches)).toBe(true)
  const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
  await expect(editor).toBeEditable()
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
        "touch.png",
        { type: "image/png" },
      ),
    )
    element.dispatchEvent(new ClipboardEvent("paste", { clipboardData: clipboard, bubbles: true, cancelable: true }))
  })
  await expect(page.getByRole("img", { name: "touch.png", exact: true })).toBeVisible()

  const remove = page.locator('[data-action="remove-attachment"]')
  await expect(remove).toHaveCSS("opacity", "1")
  await remove.tap()
  await expect(page.getByRole("img", { name: "touch.png", exact: true })).toHaveCount(0)
})
