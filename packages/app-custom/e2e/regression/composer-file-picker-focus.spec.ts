import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"

const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const directory = "/repo/file-picker-focus"
const sessionID = "ses_file_picker_focus_123456789"

test.use({ serviceWorkers: "block" })

for (const [width, height] of [
  [1440, 900],
  [390, 844],
]) {
  test(`picking files from the add menu returns focus to the editor at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await mockOpenCodeServer(page, {
      directory,
      project: {
        id: "proj_file_picker_focus",
        worktree: directory,
        vcs: "git",
        name: "file-picker-focus",
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
          projectID: "proj_file_picker_focus",
          directory,
          title: "File picker focus",
          time: { created: 1, updated: 1 },
        },
      ],
      pageMessages: () => ({ items: [] }),
      subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
    })
    await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
    const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
    await expect(editor).toBeEditable()

    await page.getByRole("button", { name: "Add images and files", exact: true }).click()
    const chooser = page.waitForEvent("filechooser")
    await page.getByRole("menuitem", { name: /^Images and files/ }).click()
    await (
      await chooser
    ).setFiles({
      name: "picked.png",
      mimeType: "image/png",
      buffer: Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=",
        "base64",
      ),
    })
    await expect(page.getByRole("img", { name: "picked.png", exact: true })).toBeVisible()
    await expect(editor).toBeFocused()
    await page.keyboard.type("typed")
    await expect(editor).toHaveText("typed")
  })
}
