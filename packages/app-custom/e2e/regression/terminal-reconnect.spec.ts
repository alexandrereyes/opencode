import { base64Encode } from "@opencode/util/encode"
import { expect, test, type Page, type WebSocketRoute } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const directory = "C:/OpenCode/TerminalReconnect"
const projectID = "proj_terminal_reconnect"
const sessionID = "ses_terminal_reconnect"
const title = "Terminal reconnect"
const ptyID = "pty_terminal_reconnect"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "*" }

test.describe("desktop", () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test("reconnects the same terminal after a transient connection failure", ({ page }) => expectReconnect(page, false))
})

test.describe("phone", () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } })

  test("reconnects the same terminal after a transient connection failure", ({ page }) => expectReconnect(page, true))
})

async function expectReconnect(page: Page, phone: boolean) {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "terminal-reconnect",
      time: { created: 1700000000000, updated: 1700000000000 },
      sandboxes: [],
    },
    provider: {
      all: [{ id: "opencode", name: "OpenCode", models: { test: { id: "test", name: "Test" } } }],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: "test" },
    },
    sessions: [
      {
        id: sessionID,
        slug: sessionID,
        projectID,
        directory,
        title,
        version: "dev",
        time: { created: 1700000000000, updated: 1700000000000 },
      },
    ],
    pageMessages: () => ({ items: [] }),
  })
  const created: string[] = []
  await page.route("**/api/pty*", (route) => {
    if (route.request().method() === "POST") created.push(ptyID)
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: cors,
      body: JSON.stringify({ location: ptyLocation(), data: ptyInfo() }),
    })
  })
  await page.route(`**/api/pty/${ptyID}*`, (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: cors,
      body: JSON.stringify({ location: ptyLocation(), data: ptyInfo() }),
    }),
  )
  let tickets = 0
  await page.route(`**/api/pty/${ptyID}/connect-token*`, (route) => {
    if (route.request().method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors })
    tickets += 1
    // The second ticket request fails as an unavailable server would; the PTY itself is still running.
    if (tickets === 2) return route.fulfill({ status: 503, headers: cors, body: "Service Unavailable" })
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: cors,
      body: JSON.stringify({ location: ptyLocation(), data: { ticket: "e2e-ticket", expires_in: 60 } }),
    })
  })
  const sockets: { url: string; route: WebSocketRoute }[] = []
  await page.routeWebSocket(new RegExp(`/api/pty/${ptyID}/connect`), (route) => {
    sockets.push({ url: route.url(), route })
  })
  await page.addInitScript(
    ({ directory, server, sessionID }) => {
      localStorage.setItem(
        "opencode.global.dat:server",
        JSON.stringify({
          projects: { local: [{ worktree: directory, expanded: true }] },
          lastProject: { local: directory },
        }),
      )
      localStorage.setItem(
        "opencode.window.browser.dat:tabs",
        JSON.stringify([{ type: "session", server, sessionId: sessionID }]),
      )
      localStorage.setItem("settings.v3", JSON.stringify({ general: { terminalPlacement: "bottom" } }))
    },
    { directory, server, sessionID },
  )

  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  const terminal = page.locator("#terminal-panel").locator('[data-component="terminal"]')
  if (phone) {
    // The phone layout has no session header; its terminal opens as a view from the navigation menu.
    await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeEditable()
    await page
      .locator('[data-slot="session-mobile-view-navigation"]')
      .getByRole("button", { name: "More options", exact: true })
      .tap()
    await page.getByRole("menuitem", { name: "Terminal", exact: true }).tap()
  } else {
    await expectSessionTitle(page, title)
    await page.keyboard.press("Control+Backquote")
  }
  await expect(terminal).toBeVisible()
  await expect.poll(() => sockets.length).toBe(1)
  await terminal.evaluate((element) => element.setAttribute("data-connection-probe", "original"))

  await sockets[0]!.route.close({ code: 1011, reason: "Temporary disconnection" })
  await expect.poll(() => tickets).toBe(3)
  await expect.poll(() => sockets.length).toBe(2)
  expect(new URL(sockets[1]!.url).pathname).toBe(`/api/pty/${ptyID}/connect`)
  await expect(terminal).toBeVisible()
  await expect(terminal).toHaveAttribute("data-connection-probe", "original")
  await expect(terminal.locator("textarea")).toBeEditable()
  expect(created).toEqual([ptyID])
}

function ptyLocation() {
  return { directory, project: { id: projectID, directory } }
}

function ptyInfo() {
  return { id: ptyID, title: "Terminal 1", command: "cmd.exe", args: [], cwd: directory, status: "running", pid: 1 }
}
