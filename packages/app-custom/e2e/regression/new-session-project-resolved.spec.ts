import { expect, test } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectAppVisible } from "../utils/waits"

const draftID = "draft_new_session_project_resolved"
const main = "C:/OpenCode/ResolvedRepo"
const other = "C:/OpenCode/ResolvedOther"
const feature = "C:/Worktrees/ResolvedRepo-feature"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

for (const viewport of [
  { width: 1440, height: 900 },
  { width: 390, height: 844 },
]) {
  test(`selects the resolved project for an unlisted worktree at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport)
    await mockOpenCodeServer(page, {
      directory: feature,
      project: {
        id: "proj_new_session_project_resolved",
        worktree: main,
        vcs: "git",
        name: "resolved-repo",
        time: { created: 1, updated: 1 },
        sandboxes: [],
      },
      provider: { all: [], connected: [], default: {} },
      sessions: [],
      pageMessages: () => ({ items: [] }),
    })
    // The draft's worktree is not yet in the project's worktree inventory, so only its resolved ID identifies it.
    await page.route(/\/api\/worktree(\?|$)/, (route) =>
      route.request().method() === "GET" ? route.fulfill({ json: [{ directory: main }] }) : route.fallback(),
    )
    await page.addInitScript(
      ({ draftID, server, main, other, feature }) => {
        localStorage.setItem(
          "opencode.global.dat:server",
          JSON.stringify({
            projects: {
              local: [
                { worktree: other, expanded: true },
                { worktree: main, expanded: true },
              ],
            },
            lastProject: { local: other },
          }),
        )
        localStorage.setItem(
          "opencode.window.browser.dat:tabs",
          JSON.stringify([{ type: "draft", draftID, server, directory: feature }]),
        )
      },
      { draftID, server, main, other, feature },
    )

    await page.goto(`/new-session?draftId=${draftID}`)
    await expectAppVisible(page.locator('[data-component="composer-editor"]'))
    const trigger = page.locator('[data-action="prompt-project"]')
    await expect(trigger).toHaveText("resolved-repo")
    await trigger.click()
    await expect(page.getByRole("menuitemradio")).toHaveText(["Chats", "ResolvedOther", "resolved-repo"])
    await expect(page.getByRole("menuitemradio", { checked: true })).toHaveText(["resolved-repo"])
  })
}
