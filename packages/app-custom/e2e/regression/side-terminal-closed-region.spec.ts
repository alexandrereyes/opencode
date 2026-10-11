import { base64Encode } from "@opencode/util/encode"
import { expect, test, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const directory = "C:/OpenCode/SideTerminalRegion"
const sessionID = "ses_side_terminal_region"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test.beforeEach(async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "proj_side_terminal_region",
      worktree: directory,
      vcs: "git",
      name: "side-terminal-region",
      time: { created: 1, updated: 1 },
      sandboxes: [],
    },
    provider: { all: [], connected: [], default: {} },
    sessions: [
      {
        id: sessionID,
        slug: "side-terminal-region",
        projectID: "proj_side_terminal_region",
        directory,
        title: "Side terminal region",
        version: "dev",
        time: { created: 1, updated: 1 },
      },
    ],
    pageMessages: () => ({ items: [] }),
  })
  const ptys: { id: string; title: string }[] = []
  await page.route("**/api/pty**", async (route) => {
    const path = new URL(route.request().url()).pathname
    const location = { directory, project: { id: "proj_side_terminal_region", directory } }
    if (route.request().method() === "DELETE") return route.fulfill({ status: 204 })
    if (path.endsWith("/connect-token"))
      return route.fulfill({ json: { location, data: { ticket: "e2e-ticket", expires_in: 60 } } })
    if (path === "/api/pty" && route.request().method() === "POST") {
      const pty = { id: `pty_region_${ptys.length + 1}`, title: `Terminal ${ptys.length + 1}` }
      ptys.push(pty)
      return route.fulfill({ json: { location, data: pty } })
    }
    return route.fulfill({ json: { location, data: ptys.find((pty) => path.endsWith(pty.id)) ?? ptys } })
  })
  await page.routeWebSocket(/\/api\/pty\/pty_region_\d+\/connect/, () => undefined)
})

test("a closed side region stays hidden over the side terminal", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  await expectSessionTitle(page, "Side terminal region")

  const toggle = page.getByRole("button", { name: "Toggle review", exact: true })
  const region = page.locator('[data-slot="session-side-region-presence"]')
  const dock = page.locator('[data-slot="session-side-terminal-region"]')
  const terminal = page.getByRole("region", { name: "Terminal", exact: true })
  await expect(toggle).toHaveAttribute("aria-expanded", "true")
  await page.keyboard.press("Control+Backquote")
  await expect(terminal.getByRole("tab", { name: "Terminal 1", exact: true })).toHaveAttribute("aria-selected", "true")
  await settled(page)
  await expect(region).toHaveCSS("visibility", "visible")

  await toggle.click()
  await expect(toggle).toHaveAttribute("aria-expanded", "false")
  await settled(page)
  // The closed region stays mounted at zero height on the terminal's top edge.
  await expect(region).toBeAttached()
  await expect
    .poll(async () => {
      const box = await region.boundingBox()
      const top = await dock.boundingBox()
      return !!box && !!top && box.height === 0 && box.y === top.y
    })
    .toBe(true)
  await expect(region).toHaveCSS("visibility", "hidden")

  // Leaving and re-entering the wide layout ends the close animation without unmounting the region.
  await page.setViewportSize({ width: 700, height: 900 })
  await expect(toggle).toBeHidden()
  await page.setViewportSize({ width: 1440, height: 900 })
  await expect(terminal.getByRole("tab", { name: "Terminal 1", exact: true })).toBeVisible()
  await settled(page)
  await expect(region).toBeAttached()
  await expect(region).not.toHaveAttribute("data-opened")
  await expect(region).toHaveCSS("visibility", "hidden")

  await toggle.click()
  await expect(toggle).toHaveAttribute("aria-expanded", "true")
  await settled(page)
  await expect(region).toHaveCSS("visibility", "visible")
  await expect.poll(async () => (await region.boundingBox())?.height ?? 0).toBeGreaterThan(0)
})

async function settled(page: Page) {
  await expect
    .poll(() =>
      page.evaluate(() =>
        document
          .getAnimations()
          .filter((animation) => animation.timeline instanceof DocumentTimeline)
          .every((animation) => animation.playState === "finished"),
      ),
    )
    .toBe(true)
}
