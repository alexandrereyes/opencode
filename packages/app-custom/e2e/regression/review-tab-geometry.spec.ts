import { base64Encode } from "@opencode/util/encode"
import { expect, test, type Locator, type Page } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const directory = "C:/OpenCode/ReviewTabGeometry"
const projectID = "proj_review_tab_geometry"
const sessionID = "ses_review_tab_geometry"
const title = "Review tab geometry"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const files = Array.from({ length: 12 }, (_, index) => `src/module-${index}.ts`)

test.use({ viewport: { width: 1440, height: 900 } })

test.beforeEach(async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "review-tab-geometry",
      time: { created: 1700000000000, updated: 1700000000000 },
      sandboxes: [],
    },
    provider: { all: [], connected: [], default: {} },
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
    fileList: () => [],
    fileContent: (path) => ({ type: "text", content: `contents:${path}` }),
    pageMessages: () => ({ items: [] }),
  })
  const ptys: { id: string; title: string }[] = []
  await page.route("**/api/pty**", async (route) => {
    const path = new URL(route.request().url()).pathname
    const location = { directory, project: { id: projectID, directory } }
    if (route.request().method() === "DELETE") return route.fulfill({ status: 204 })
    if (path.endsWith("/connect-token"))
      return route.fulfill({ json: { location, data: { ticket: "e2e-ticket", expires_in: 60 } } })
    if (path === "/api/pty" && route.request().method() === "POST") {
      const pty = { id: `pty_geometry_${ptys.length + 1}`, title: `Terminal ${ptys.length + 1}` }
      ptys.push(pty)
      return route.fulfill({ json: { location, data: pty } })
    }
    return route.fulfill({ json: { location, data: ptys.find((pty) => path.endsWith(pty.id)) ?? ptys } })
  })
  await page.routeWebSocket(/\/api\/pty\/pty_geometry_\d+\/connect/, () => undefined)
  await page.addInitScript(
    ({ directory, server, sessionID, tabKey, files }) => {
      localStorage.setItem(
        "opencode.global.dat:server",
        JSON.stringify({
          projects: { local: [{ worktree: directory, expanded: true }] },
          lastProject: { local: directory },
        }),
      )
      localStorage.setItem(
        "opencode.global.dat:layout",
        JSON.stringify({
          sessionTabs: {
            [`local\u0000/${sessionID}`]: {
              all: ["context", ...files.map((file) => `file://${file}`)],
              active: `file://${files[3]}`,
            },
          },
        }),
      )
      localStorage.setItem("opencode.window.browser.dat:tabs.panes", JSON.stringify({ [tabKey]: { review: true } }))
      localStorage.setItem(
        "opencode.window.browser.dat:tabs",
        JSON.stringify([{ type: "session", server, sessionId: sessionID }]),
      )
    },
    { directory, server, sessionID, tabKey: `${server}\n/server/${base64Encode(server)}/session/${sessionID}`, files },
  )
})

for (const direction of ["ltr", "rtl"] as const) {
  test(`file tabs keep their icons unclipped and share the review toggle's row (${direction})`, async ({ page }) => {
    const panel = await openPanel(page, direction)
    const toggle = page.getByRole("button", { name: "Toggle review", exact: true })
    const center = await middle(toggle)

    // An inactive tab shows the monochrome icon. It must sit wholly inside its clipping trigger; in LTR it sits 8px
    // inside the pill with the label where it was. File names keep their own direction inside the trigger.
    const wrapper = panel.locator(`[data-slot="tabs-trigger-wrapper"][data-value="file://${files[1]}"]`)
    const geometry = await wrapper.evaluate((element) => {
      const pill = element.getBoundingClientRect()
      const trigger = element.querySelector('[data-slot="tabs-trigger"]')!.getBoundingClientRect()
      const icon = element.querySelector(".tab-fileicon-mono")!.getBoundingClientRect()
      const label = element.querySelector(".text-14-medium")!.getBoundingClientRect()
      return {
        icon: icon.left - pill.left,
        label: label.left - pill.left,
        clipped: icon.left < trigger.left || icon.right > trigger.right,
      }
    })
    expect(geometry.clipped).toBe(false)
    if (direction === "ltr") expect(geometry).toEqual({ icon: 8, label: 32, clipped: false })

    for (const control of [
      panel.getByRole("tab", { name: "module-3.ts", exact: true }),
      panel.getByRole("button", { name: "Open file", exact: true }),
      panel.locator('[data-slot="session-side-panel-actions"]'),
    ]) {
      await expect.poll(() => middle(control)).toBe(center)
    }
    await expect(panel.locator('[data-slot="tabs-list"]')).toHaveCSS("height", "48px")
  })

  test(`scrolled tabs stay hidden behind the open-file button (${direction})`, async ({ page }) => {
    const panel = await openPanel(page, direction)
    const list = panel.locator('[data-slot="tabs-list"]')
    await list.evaluate((element, direction) => {
      element.scrollLeft = ((direction === "rtl" ? -1 : 1) * (element.scrollWidth - element.clientWidth)) / 2
    }, direction)
    // Cover the "+" box and the strip's end edge beyond it.
    const clip = await list.evaluate((element, direction) => {
      const strip = element.getBoundingClientRect()
      const box = element.querySelector('button[aria-label="Open file"]')!.closest(".sticky")!.getBoundingClientRect()
      const left = direction === "rtl" ? strip.left : box.left
      const right = direction === "rtl" ? box.right : strip.right
      return { x: left, y: strip.top, width: right - left, height: strip.height - 1 }
    }, direction)
    expect(clip.width).toBeGreaterThanOrEqual(40)
    expect(await page.screenshot({ clip })).toEqual(
      await page.screenshot({ clip, style: '#review-panel [data-slot="tabs-trigger-wrapper"] { visibility: hidden }' }),
    )
  })
}

test("tabs and actions share the 51px row above a stacked side terminal", async ({ page }) => {
  const panel = await openPanel(page, "ltr")
  await page.keyboard.press("Control+Backquote")
  const terminal = page.getByRole("region", { name: "Terminal", exact: true })
  await expect(terminal.getByRole("tab", { name: "Terminal 1", exact: true })).toHaveAttribute("aria-selected", "true")
  const list = panel.locator('[data-slot="tabs-list"]')
  await expect(list).toHaveCSS("height", "51px")
  await expect(panel.locator('[data-slot="session-side-panel-actions"]')).toHaveCSS("height", "51px")
  const center = await middle(list)
  for (const control of [
    panel.getByRole("tab", { name: "module-3.ts", exact: true }),
    panel.getByRole("button", { name: "Open file", exact: true }),
    panel.locator('[data-slot="session-side-panel-actions"]'),
    page.getByRole("button", { name: "Toggle review", exact: true }),
  ]) {
    await expect.poll(() => middle(control)).toBe(center)
  }
})

async function openPanel(page: Page, direction: "ltr" | "rtl") {
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  await expectSessionTitle(page, title)
  await page.locator("html").evaluate((element, dir) => element.setAttribute("dir", dir), direction)
  const panel = page.locator("#review-panel")
  await expect(panel.getByRole("tab", { name: "module-3.ts", selected: true })).toBeVisible()
  await expect(page.getByRole("button", { name: "Toggle review", exact: true })).toHaveAttribute(
    "aria-expanded",
    "true",
  )
  await expect(page.locator('[data-slot="session-chat-panel"]')).toHaveAttribute("data-width-animating", "false")
  return panel
}

async function middle(locator: Locator) {
  const box = await locator.boundingBox()
  if (!box) throw new Error("Bounds are unavailable")
  return box.y + box.height / 2
}
