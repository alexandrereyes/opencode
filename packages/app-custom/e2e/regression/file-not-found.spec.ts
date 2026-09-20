import type { OpenCodeEvent } from "@opencode/client/promise"
import { base64Encode } from "@opencode/util/encode"
import { expect, test, type Route } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const directory = "C:/OpenCode/FileNotFound"
const projectID = "proj_file_not_found"
const sessionID = "ses_file_not_found"
const title = "File not found"
const filename = "README.md"
const content = "original file contents"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test.use({
  viewport: { width: 1440, height: 900 },
  channel: process.env.PLAYWRIGHT_CHANNEL,
})

test("clears stale file content on not found and recovers when the file returns", async ({ page }) => {
  const events: OpenCodeEvent[] = []
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "file-not-found",
      time: { created: 1700000000000, updated: 1700000000000 },
      sandboxes: [],
    },
    provider: {
      all: [
        {
          id: "opencode",
          name: "OpenCode",
          models: { test: { id: "test", name: "Test", limit: { context: 200_000 } } },
        },
      ],
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
    vcsDiff: [],
    fileList: (path) => (path ? [] : [fileNode(filename)]),
    fileContent: () => content,
    events: () => events.splice(0),
    pageMessages: () => ({ items: [] }),
  })
  await page.addInitScript(
    ({ directory, server, sessionID, tabKey }) => {
      localStorage.setItem(
        "opencode.global.dat:server",
        JSON.stringify({
          projects: { local: [{ worktree: directory, expanded: true }] },
          lastProject: { local: directory },
        }),
      )
      localStorage.setItem("opencode.global.dat:layout", JSON.stringify({ review: { diffStyle: "split" } }))
      localStorage.setItem("opencode.window.browser.dat:tabs.panes", JSON.stringify({ [tabKey]: { review: true } }))
      localStorage.setItem(
        "opencode.global.dat:review-panel-v2",
        JSON.stringify({ sidebarOpened: true, sidebarWidth: 240, expandMode: "collapse" }),
      )
      localStorage.setItem(
        "opencode.window.browser.dat:tabs",
        JSON.stringify([{ type: "session", server, sessionId: sessionID }]),
      )
    },
    { directory, server, sessionID, tabKey: `${server}\n/server/${base64Encode(server)}/session/${sessionID}` },
  )

  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  await expectSessionTitle(page, title)

  const panel = page.locator("#review-panel")
  await panel.getByRole("button", { name: "Open file" }).click()
  await panel.getByRole("button", { name: filename, exact: true }).click()
  await expect(panel.getByRole("tab", { name: filename, selected: true })).toBeVisible()
  await expect(panel.getByText(content, { exact: true })).toBeVisible()

  const missingReadPattern = `**/api/fs/read/${filename}*`
  const missingRead = (route: Route) =>
    route.fulfill({
      status: 404,
      contentType: "application/json",
      body: JSON.stringify({
        _tag: "FileNotFoundError",
        path: filename,
        message: `File not found: ${filename}`,
      }),
    })
  await page.route(missingReadPattern, missingRead)
  const missingResponse = page.waitForResponse(
    (response) => response.url().includes(`/api/fs/read/${filename}`) && response.status() === 404,
  )
  events.push(filesystemEvent("unlink"))
  await missingResponse

  const missingLabel = `File not found: ${filename}`
  const missingTab = panel.getByRole("tab", { name: missingLabel, selected: true })
  await expect(missingTab).toBeVisible()
  await expect(missingTab).toHaveAccessibleName(missingLabel)
  await expect(missingTab.locator("[data-file-not-found]")).toHaveCSS("text-decoration-line", "line-through")
  await expect(panel.getByText(content, { exact: true })).toHaveCount(0)
  await expect(panel.getByText(missingLabel, { exact: true })).toBeVisible()

  await page.unroute(missingReadPattern, missingRead)
  const restoredResponse = page.waitForResponse(
    (response) => response.url().includes(`/api/fs/read/${filename}`) && response.status() === 200,
  )
  events.push(filesystemEvent("add"))
  await restoredResponse

  const restoredTab = panel.getByRole("tab", { name: filename, selected: true })
  await expect(restoredTab).toBeVisible()
  await expect(restoredTab).toHaveAccessibleName(filename)
  await expect(restoredTab.locator("[data-file-not-found]")).toHaveCount(0)
  await expect(panel.getByText(missingLabel, { exact: true })).toHaveCount(0)
  await expect(panel.getByText(content, { exact: true })).toBeVisible()
})

function filesystemEvent(event: "add" | "unlink"): OpenCodeEvent {
  return {
    id: `evt_${event}`,
    created: 1,
    type: "filesystem.changed",
    location: { directory },
    data: { file: filename, event },
  }
}

function fileNode(path: string) {
  return {
    name: path,
    path,
    absolute: `${directory}/${path}`,
    type: "file",
    ignored: false,
  }
}
