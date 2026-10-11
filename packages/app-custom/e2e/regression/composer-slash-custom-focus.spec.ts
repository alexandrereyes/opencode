import { expect, test, type Page } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectComposerText } from "../utils/composer"

// Custom built-in slash commands run their action without the slash machine's editor focus; each must
// still move focus to its own surface and leave an empty main draft.
const directory = "/repo/slash-custom-focus"
const projectID = "proj_slash_custom_focus"
const sessionID = "ses_slash_custom_focus_123456789"
const ptyID = "pty_slash_custom_focus"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "*" }
const selections = ["enter", "pointer"] as const

test.use({
  serviceWorkers: "block",
  // Headless Chrome hands the first navigation a spare renderer that misses touch hover/pointer emulation.
  launchOptions: { args: ["--disable-features=SpareRendererForSitePerProcess"] },
})

test.describe("desktop", () => {
  test.use({ viewport: { width: 1440, height: 900 } })
  for (const selection of selections) {
    test(`/btw from the popover focuses the side composer (${selection})`, ({ page }) =>
      expectBtw(page, { selection, touch: false }))
    test(`/terminal from the popover focuses the terminal (${selection})`, ({ page }) =>
      expectTerminal(page, { selection, touch: false }))
  }
})

test.describe("touch", () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } })
  for (const selection of selections) {
    test(`/btw from the popover focuses the side composer (${selection})`, ({ page }) =>
      expectBtw(page, { selection, touch: true }))
    test(`/terminal from the popover focuses the terminal (${selection})`, ({ page }) =>
      expectTerminal(page, { selection, touch: true }))
  }
})

type Choice = { selection: (typeof selections)[number]; touch: boolean }

async function expectBtw(page: Page, choice: Choice) {
  await open(page)
  await choose(page, "btw", "session.btw", choice)
  await expect(page.getByRole("region", { name: "Ask a side question", exact: true })).toBeVisible()
  const side = page.locator(
    '[data-component="composer-region"] > :not(.composer-main) [data-component="composer-editor"]',
  )
  await expect(side).toBeFocused()
  await page.keyboard.type("side question")
  await expectComposerText(side, "side question")
  await expectComposerText(mainComposer(page), "")
}

async function expectTerminal(page: Page, choice: Choice) {
  const input: string[] = []
  await page.routeWebSocket(new RegExp(`/api/pty/${ptyID}/connect`), (socket) => {
    socket.onMessage((message) => input.push(message.toString()))
  })
  await open(page)
  await choose(page, "terminal", "terminal.toggle", choice)
  const terminal = page.locator("#terminal-panel").locator('[data-component="terminal"] textarea')
  await expect(terminal).toBeFocused()
  await page.keyboard.type("x")
  await expect.poll(() => input.includes("x")).toBe(true)
  await expectComposerText(mainComposer(page), "")
}

async function choose(page: Page, slash: string, id: string, choice: Choice) {
  const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
  if (choice.touch) await editor.tap()
  else await editor.click()
  await page.keyboard.type(`/${slash}`)
  const item = page.locator(`[data-suggestion-id="${id}"]`)
  await expect(item).toHaveAttribute("data-active", "")
  if (choice.selection === "enter") return page.keyboard.press("Enter")
  if (choice.touch) return item.tap()
  return item.click()
}

function mainComposer(page: Page) {
  return page.locator('.composer-main [data-component="composer-editor"]')
}

async function open(page: Page) {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "slash-custom-focus",
      time: { created: 1, updated: 1 },
      sandboxes: [],
    },
    provider: {
      all: [{ id: "opencode", name: "OpenCode", models: { test: { id: "test", name: "Test" } } }],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: "test" },
    },
    sessions: [{ id: sessionID, projectID, directory, title: "Slash custom focus", time: { created: 1, updated: 1 } }],
    pageMessages: () => ({ items: [] }),
    subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
  })
  const location = { directory, project: { id: projectID, directory } }
  const info = { id: ptyID, title: "Terminal 1", command: "sh", args: [], cwd: directory, status: "running", pid: 1 }
  await page.route("**/api/pty*", (route) => route.fulfill({ headers: cors, json: { location, data: info } }))
  await page.route(`**/api/pty/${ptyID}*`, (route) => route.fulfill({ headers: cors, json: { location, data: info } }))
  await page.route(`**/api/pty/${ptyID}/connect-token*`, (route) =>
    route.fulfill({ headers: cors, json: { location, data: { ticket: "e2e-ticket", expires_in: 60 } } }),
  )
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeEditable()
}
