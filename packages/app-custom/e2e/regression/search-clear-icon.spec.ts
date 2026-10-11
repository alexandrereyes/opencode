import { expect, test, type Locator, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectAppVisible } from "../utils/waits"

const draftID = "draft_search_clear_icon"
const directory = "C:/OpenCode/SearchClearIcon"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const model = {
  id: "paid-model",
  name: "Paid Model",
  cost: { input: 1, output: 1 },
  limit: { context: 200_000 },
  capabilities: { tools: true, input: ["text"], output: ["text"] },
}

test.use({ viewport: { width: 1440, height: 900 } })

test.beforeEach(async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "proj_search_clear_icon",
      worktree: directory,
      vcs: "git",
      name: "search-clear-icon",
      time: { created: 1700000000000, updated: 1700000000000 },
      sandboxes: [],
    },
    provider: {
      all: [{ id: "opencode", name: "OpenCode", models: { [model.id]: model } }],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: model.id },
    },
    sessions: [],
    pageMessages: () => ({ items: [] }),
    vcsBranches: ["feature/api", "main"],
    subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
  })
  await page.addInitScript(
    ({ directory, draftID, server }) => {
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
  await expectAppVisible(page.locator('[data-component="composer-editor"]'))
})

test("project search clears with the filled icon", async ({ page }) => {
  await page.locator('[data-action="prompt-project"]').click()
  const search = page.locator("#prompt-project-menu").getByRole("textbox")
  await expect(search).toBeFocused()
  await expectClearControl(page, search)
})

test("branch search clears with the filled icon", async ({ page }) => {
  await page.locator('[data-action="prompt-workspace"]').click()
  await page.getByRole("menuitem", { name: "New", exact: true }).click()
  await page.getByRole("button", { name: "from main", exact: true }).click()
  const search = page.getByRole("textbox", { name: "Search branches", exact: true })
  await expect(search).toBeFocused()
  await expectClearControl(page, search)
})

test("model search clears with the filled icon, as does the manage dialog", async ({ page }) => {
  await page.locator('[data-action="composer-model"]').click()
  const search = page.getByPlaceholder("Search models", { exact: true })
  await expect(search).toBeFocused()
  await expectClearControl(page, search)

  await page.getByRole("button", { name: "Manage models", exact: true }).click()
  const dialog = page.getByRole("dialog")
  const filter = dialog.getByRole("searchbox", { name: "Search models", exact: true })
  await filter.fill("paid")
  const clear = dialog.getByRole("button", { name: "Clear", exact: true })
  await expect(clear.locator("use")).toHaveAttribute("href", "#opencode-v2-icon-circle-xmark")
  await clear.click()
  await expect(filter).toHaveValue("")
  await expect(clear).toHaveCount(0)
})

// The clear control is a faint filled icon with no hover fill; hover and keyboard focus raise it to the base color.
async function expectClearControl(page: Page, search: Locator) {
  await search.pressSequentially("ma")
  const clear = page.getByRole("button", { name: "Clear", exact: true })
  const icon = clear.locator("svg")
  await expect(icon.locator("use")).toHaveAttribute("href", "#opencode-v2-icon-circle-xmark")
  await expect(icon).toHaveAttribute("width", "16")
  const faint = await color(page, "--v2-icon-icon-faint")
  const base = await color(page, "--v2-icon-icon-base")
  await expect(clear).toHaveCSS("color", faint)
  await expect(clear).toHaveCSS("background-color", "rgba(0, 0, 0, 0)")
  await clear.hover()
  await expect(clear).toHaveCSS("color", base)
  await expect(clear).toHaveCSS("background-color", "rgba(0, 0, 0, 0)")
  await search.hover()
  await page.mouse.move(0, 0)
  await expect(clear).toHaveCSS("color", faint)
  // Focus that follows keyboard input matches :focus-visible.
  await search.press("End")
  await clear.focus()
  await expect(clear).toBeFocused()
  expect(await clear.evaluate((element) => element.matches(":focus-visible"))).toBe(true)
  await expect(clear).toHaveCSS("color", base)
  await search.focus()
  await clear.click()
  await expect(search).toHaveValue("")
  await expect(search).toBeFocused()
  await expect(clear).toHaveCount(0)
}

function color(page: Page, token: string) {
  return page.evaluate((token) => {
    const probe = document.createElement("span")
    probe.style.color = `var(${token})`
    document.body.append(probe)
    const value = getComputedStyle(probe).color
    probe.remove()
    return value
  }, token)
}
