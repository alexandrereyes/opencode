import { expect, test, type Page } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectComposerText } from "../utils/composer"

const directory = "/repo/model-dialog-focus"
const projectID = "proj_model_dialog_focus"
const sessionID = "ses_model_dialog_focus_123456789"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test.use({
  serviceWorkers: "block",
  // Headless Chrome hands the first navigation a spare renderer that misses touch hover/pointer emulation.
  launchOptions: { args: ["--disable-features=SpareRendererForSitePerProcess"] },
})

test.describe("desktop", () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test("focuses the model search when /model opens the dialog", async ({ page }) => {
    await expectModelSearchFocus(page)
  })
})

test.describe("touch", () => {
  test.use({
    hasTouch: true,
    isMobile: true,
    viewport: { width: 390, height: 844 },
  })

  test("focuses the model search when /model opens the dialog", async ({ page }) => {
    await expectModelSearchFocus(page)
  })
})

async function expectModelSearchFocus(page: Page) {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "model-dialog-focus",
      time: { created: 1, updated: 1 },
      sandboxes: [],
    },
    provider: {
      all: [{ id: "opencode", name: "OpenCode", models: { test: { id: "test", name: "Test" } } }],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: "test" },
    },
    sessions: [{ id: sessionID, projectID, directory, title: "Model dialog focus", time: { created: 1, updated: 1 } }],
    pageMessages: () => ({ items: [] }),
    subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
  })
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
  await expect(editor).toBeEditable()
  // The open dialog hides the composer from the accessibility tree, so read its text by component.
  const composer = page.locator('[data-component="composer-editor"]')
  await expect(composer).toHaveCount(1)
  const dialog = page.getByRole("dialog", { name: "Select model", exact: true })
  const search = dialog.getByRole("textbox", { name: "Search models", exact: true })

  await editor.click()
  await page.keyboard.type("/model")
  await expect(page.locator('[data-suggestion-id="model.choose"]')).toHaveAttribute("data-active", "")
  // Type without waiting: the dialog must already own focus when the command returns.
  await page.keyboard.press("Enter")
  await page.keyboard.type("gpt")
  await expect(dialog).toBeVisible()
  await expect(search).toHaveValue("gpt")
  await expect(search).toBeFocused()
  await expectComposerText(composer, "")

  await page.keyboard.press("Escape")
  await expect(dialog).toBeHidden()
  await expect(editor).toBeFocused()
  await expectComposerText(composer, "")

  await page.keyboard.type("keep me")
  await page.getByRole("button", { name: "Add images and files" }).click()
  await page.getByRole("menuitem", { name: "Commands" }).click()
  await page.locator('[data-suggestion-id="model.choose"]').click()
  await page.keyboard.type("test")
  await expect(search).toHaveValue("test")
  await expectComposerText(composer, "keep me")
}
