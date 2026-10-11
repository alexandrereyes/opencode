import { expect, test, type Page } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { fixture } from "../smoke/session-timeline.fixture"
import { mockOpenCodeServer } from "../utils/mock-server"
import { installSseTransport } from "../utils/sse-transport"

for (const endpoint of ["/api/location", "/api/agent"]) {
  for (const recover of [false, true]) {
    test(`keeps the composer when ${endpoint} ${recover ? "recovers on retry" : "fails"}`, async ({ page }) => {
      const recovery = recoveryRequests(page)
      const directory = "/projects/working-tree"
      const sessionID = "ses_location_sync_failure"
      await mockOpenCodeServer(page, {
        directory: fixture.directory,
        project: fixture.project,
        provider: fixture.provider,
        sessions: [{ id: sessionID, projectID: fixture.project.id, directory, title: "Workspace sync" }],
        fileList: () => [],
        pageMessages: () => ({
          items: [{ id: "msg_saved", type: "user", text: "Keep working in this worktree", time: { created: 1 } }],
        }),
      })
      let requests = 0
      await page.route("**/api/**", (route) => {
        const url = new URL(route.request().url())
        if (url.pathname !== endpoint || url.searchParams.get("location[directory]") !== directory)
          return route.fallback()
        requests++
        if (recover && requests > 1) return route.fallback()
        return route.fulfill({ status: 500, body: "", headers: { "access-control-allow-origin": "*" } })
      })
      const failure = page.waitForResponse(
        (response) => new URL(response.url()).pathname === endpoint && response.status() === 500,
      )
      const settled = page.waitForResponse((response) => {
        const url = new URL(response.url())
        return (
          url.pathname === endpoint &&
          url.searchParams.get("location[directory]") === directory &&
          (recover ? response.ok() : requests === 3 && response.status() === 500)
        )
      })
      await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${sessionID}`)
      await failure
      await expect(page.getByText("Keep working in this worktree", { exact: true })).toBeVisible()
      const prompt = page.getByRole("textbox", { name: "Prompt", exact: true })
      await expect(prompt).toBeEditable()
      await prompt.fill("Continue after reconnecting")
      await expect(prompt).toHaveText("Continue after reconnecting")
      await settled
      await expect(prompt).toBeEditable()
      await expect(prompt).toHaveText("Continue after reconnecting")
      expect(requests).toBe(recover ? 2 : 3)
      await expect(page.getByText("Session location unavailable", { exact: true })).toHaveCount(0)
      await expect(page.getByRole("button", { name: "Choose directory", exact: true })).toHaveCount(0)
      expect(recovery).toEqual([])
      await page.screenshot({ path: test.info().outputPath("location-sync.png") })
    })
  }
}

for (const view of ["desktop", "mobile"] as const) {
  test(`replaces the composer when the location is not found and recovers by moving to another worktree (${view})`, async ({
    page,
  }) => {
    if (view === "mobile") await page.setViewportSize({ width: 390, height: 844 })
    const directory = "/projects/deleted-worktree"
    const destination = "/projects/existing-worktree"
    const sessionID = "ses_location_not_found"
    const session = { id: sessionID, projectID: fixture.project.id, directory, title: "Missing location" }
    const transport = await installSseTransport(page, { server: fixture.serverKey })
    await mockOpenCodeServer(page, {
      directory: fixture.directory,
      project: { ...fixture.project, sandboxes: [directory, destination] },
      provider: fixture.provider,
      sessions: [session],
      fileList: () => [],
      pageMessages: () => ({
        items: [{ id: "msg_saved", type: "user", text: "Keep this session history", time: { created: 1 } }],
      }),
    })
    const requests = await missingLocation(page, directory)
    const moves = await moveRequests(page, sessionID)

    await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${sessionID}`)
    const status = page.getByRole("status").filter({ hasText: "Session location unavailable" })
    await expect(status).toContainText(directory)
    await expect(page.getByText("Keep this session history", { exact: true })).toBeVisible()
    await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toHaveCount(0)
    // A typed not-found answer is final; retrying cannot succeed until the folder changes.
    expect(requests()).toBe(1)
    await page.screenshot({ path: test.info().outputPath(`location-missing-${view}.png`) })

    await transport.waitForConnection()
    await page.getByRole("button", { name: "Choose worktree", exact: true }).click()
    await expect(page.getByRole("menuitem", { name: "Local repository", exact: true })).toBeVisible()
    await page.getByRole("menuitem", { name: "Worktree", exact: true }).click()
    await expect(page.getByRole("menuitem", { name: "deleted-worktree", exact: true })).toHaveCount(0)
    await page.getByRole("menuitem", { name: "existing-worktree", exact: true }).click()
    await expect.poll(() => moves).toEqual([{ directory: destination }])

    session.directory = destination
    await transport.send({
      id: "evt_location_not_found_moved",
      type: "session.moved",
      created: 2,
      durable: { aggregateID: sessionID, seq: 1, version: 1 },
      data: { sessionID, location: { directory: destination }, projectID: fixture.project.id },
    })
    await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeEditable()
    await expect(status).toHaveCount(0)
    await expect(page.getByText("Keep this session history", { exact: true })).toBeVisible()
  })
}

test("replaces the composer when the custom plugin reports the session folder missing", async ({ page }) => {
  const directory = "/projects/removed-worktree"
  const sessionID = "ses_location_unavailable"
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    provider: fixture.provider,
    sessions: [{ id: sessionID, projectID: fixture.project.id, directory, title: "Removed worktree" }],
    fileList: () => [],
    pageMessages: () => ({ items: [{ id: "msg_saved", type: "user", text: "Removed folder", time: { created: 1 } }] }),
  })
  const locations: string[] = []
  page.on("request", (request) => {
    const url = new URL(request.url())
    if (url.pathname === "/api/location") locations.push(url.searchParams.get("location[directory]") ?? "")
  })
  // The directory guard asks the plugin before syncing a Location and skips one whose folder is gone.
  await page.route("**/api/rpc/custom.worktrees/available", (route) => {
    const body = route.request().postDataJSON() as { input?: { directory?: string } }
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "access-control-allow-origin": "*" },
      body: JSON.stringify({ output: body.input?.directory !== directory }),
    })
  })

  await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${sessionID}`)
  const status = page.getByRole("status").filter({ hasText: "Session location unavailable" })
  await expect(status).toContainText(directory)
  await expect(page.getByText("Removed folder", { exact: true })).toBeVisible()
  await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toHaveCount(0)
  await expect(page.getByRole("button", { name: "Choose directory", exact: true })).toBeVisible()
  expect(locations).not.toContain(directory)
})

test("moves a session whose location is missing to a chosen directory", async ({ page }) => {
  const directory = "/projects/deleted-folder"
  const destination = "/projects/chosen-folder"
  const sessionID = "ses_location_not_found_picker"
  const session = { id: sessionID, projectID: fixture.project.id, directory, title: "Missing folder" }
  const transport = await installSseTransport(page, { server: fixture.serverKey })
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: { ...fixture.project, vcs: undefined },
    provider: fixture.provider,
    sessions: [session],
    fileList: () => [],
    pageMessages: () => ({ items: [{ id: "msg_saved", type: "user", text: "Pick a folder", time: { created: 1 } }] }),
  })
  await missingLocation(page, directory)
  const moves = await moveRequests(page, sessionID)

  await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${sessionID}`)
  const status = page.getByRole("status").filter({ hasText: "Session location unavailable" })
  await expect(status).toContainText(directory)
  // Worktrees need a Git project; any folder can still be chosen.
  await expect(page.getByRole("button", { name: "Choose worktree", exact: true })).toHaveCount(0)
  const choose = page.getByRole("button", { name: "Choose directory", exact: true })

  await choose.click()
  const dialog = page.getByRole("dialog")
  await expect(dialog.getByText("Choose directory", { exact: true })).toBeVisible()
  await dialog.getByRole("button", { name: "Cancel", exact: true }).click()
  await expect(dialog).toHaveCount(0)
  await expect(choose).toBeFocused()
  expect(moves).toEqual([])

  await transport.waitForConnection()
  await choose.click()
  const path = dialog.getByRole("combobox")
  // The picker fills its starting folder once it loads; typing before that would be replaced.
  await expect(path).toHaveValue(/SmokeProject/)
  await path.fill(destination)
  await path.press("Enter")
  await expect(dialog.getByText(destination, { exact: true })).toBeVisible()
  await dialog.getByRole("button", { name: "Select folder", exact: true }).click()
  await expect.poll(() => moves).toEqual([{ directory: destination }])

  session.directory = destination
  await transport.send({
    id: "evt_location_not_found_picked",
    type: "session.moved",
    created: 2,
    durable: { aggregateID: sessionID, seq: 1, version: 1 },
    data: { sessionID, location: { directory: destination }, projectID: fixture.project.id },
  })
  await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeEditable()
  await expect(status).toHaveCount(0)
})

test("keeps the side panel tabs and review selection when the session moves", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  const directory = "/projects/tabs-before-move"
  const destination = "/projects/tabs-after-move"
  const sessionID = "ses_location_moved_tabs"
  const session = { id: sessionID, projectID: fixture.project.id, directory, title: "Moved tabs" }
  const transport = await installSseTransport(page, { server: fixture.serverKey })
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    provider: fixture.provider,
    sessions: [session],
    fileList: () => [
      {
        name: "README.md",
        path: "README.md",
        absolute: `${session.directory}/README.md`,
        type: "file",
        ignored: false,
      },
    ],
    fileContent: (path) => ({ type: "text", content: `contents:${session.directory}:${path}` }),
    vcsDiff: [fileDiff("src/alpha.ts"), fileDiff("src/beta.ts")],
    pageMessages: () => ({ items: [{ id: "msg_saved", type: "user", text: "Keep my tabs", time: { created: 1 } }] }),
  })
  await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${sessionID}`)
  await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeEditable()

  const panel = page.locator("#review-panel")
  const review = panel.locator("#session-side-panel-review-tab")
  const file = panel.locator('[data-slot="session-review-v2-file-name"]')
  await review.click()
  await panel.getByRole("button", { name: "beta.ts" }).click()
  await expect(file).toHaveText("beta.ts")
  await panel.getByRole("button", { name: "Open file" }).click()
  await panel.getByRole("button", { name: "README.md" }).click()
  const readme = panel.getByRole("tab", { name: "README.md", exact: true })
  await expect(readme).toHaveAttribute("aria-selected", "true")
  await expect(panel.getByText(`contents:${directory}:README.md`, { exact: true })).toBeVisible()

  await transport.waitForConnection()
  const resolved = page.waitForResponse((response) => {
    const url = new URL(response.url())
    return (
      url.pathname === "/api/location" && url.searchParams.get("location[directory]") === destination && response.ok()
    )
  })
  session.directory = destination
  await transport.send({
    id: "evt_location_moved_tabs",
    type: "session.moved",
    created: 2,
    durable: { aggregateID: sessionID, seq: 1, version: 1 },
    data: { sessionID, location: { directory: destination }, projectID: fixture.project.id },
  })
  await resolved
  await expect(page.locator('[data-type="location-switched"]').getByText(destination, { exact: true })).toBeVisible()
  await expect(readme).toHaveAttribute("aria-selected", "true")
  // The carried tab shows the file in the new directory.
  await expect(panel.getByText(`contents:${destination}:README.md`, { exact: true })).toBeVisible()
  await review.click()
  await expect(file).toHaveText("beta.ts")
})

test("follows a live session move while the agent catalog is still loading", async ({ page }) => {
  const recovery = recoveryRequests(page)
  const directory = "/projects/old-tree"
  const destination = "/projects/current-tree"
  const sessionID = "ses_location_moved_while_loading"
  const session = { id: sessionID, projectID: fixture.project.id, directory, title: "Moved session" }
  const requested = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  await page.addInitScript(() => {
    localStorage.setItem(
      "settings.v3",
      JSON.stringify({ general: { timelineDetail: { notices: { placement: "separate" } } } }),
    )
  })
  const transport = await installSseTransport(page, { server: fixture.serverKey })
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    provider: fixture.provider,
    sessions: [session],
    fileList: () => [],
    pageMessages: () => ({
      items: [{ id: "msg_saved", type: "user", text: "Follow the session move", time: { created: 1 } }],
    }),
  })
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url())
    if (url.pathname === "/api/agent" && url.searchParams.get("location[directory]") === directory) {
      requested.resolve()
      await release.promise
    }
    return route.fallback()
  })
  await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${sessionID}`)
  await requested.promise
  const prompt = page.getByRole("textbox", { name: "Prompt", exact: true })
  await expect(prompt).toBeEditable()
  await prompt.fill("Keep this draft")
  await expect(page.getByText("Session location unavailable", { exact: true })).toHaveCount(0)
  await transport.waitForConnection()
  const resolved = page.waitForResponse((response) => {
    const url = new URL(response.url())
    return url.pathname === "/api/agent" && url.searchParams.get("location[directory]") === destination && response.ok()
  })
  session.directory = destination
  await transport.send({
    id: "evt_location_moved_while_loading",
    type: "session.moved",
    created: 2,
    durable: { aggregateID: sessionID, seq: 1, version: 1 },
    data: { sessionID, location: { directory: destination }, projectID: fixture.project.id },
  })
  await resolved
  const delayed = page.waitForResponse((response) => {
    const url = new URL(response.url())
    return url.pathname === "/api/agent" && url.searchParams.get("location[directory]") === directory && response.ok()
  })
  release.resolve()
  await delayed
  await expect(prompt).toBeEditable()
  await expect(prompt).toHaveText("Keep this draft")
  await expect(page.getByText("Follow the session move", { exact: true })).toBeVisible()
  await expect(page.locator('[data-type="location-switched"]').getByText(destination, { exact: true })).toBeVisible()
  await expect(page.getByText("Session location unavailable", { exact: true })).toHaveCount(0)
  await expect(page.getByRole("button", { name: "Choose directory", exact: true })).toHaveCount(0)
  expect(recovery).toEqual([])
})

test("refreshes a session moved during disconnection without losing the draft", async ({ page }) => {
  const recovery = recoveryRequests(page)
  const directory = "/projects/before-reconnect"
  const destination = "/projects/after-reconnect"
  const sessionID = "ses_location_reconnect"
  const session = { id: sessionID, projectID: fixture.project.id, directory, title: "Reconnected session" }
  const transport = await installSseTransport(page, { server: fixture.serverKey })
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    provider: fixture.provider,
    sessions: [session],
    fileList: () => [],
    pageMessages: () => ({
      items: [{ id: "msg_saved", type: "user", text: "Resume in the current worktree", time: { created: 1 } }],
    }),
  })
  await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${sessionID}`)
  const prompt = page.getByRole("textbox", { name: "Prompt", exact: true })
  await expect(prompt).toBeEditable()
  await prompt.fill("Draft before disconnect")
  const connection = await transport.waitForConnection()
  const resolved = page.waitForResponse((response) => {
    const url = new URL(response.url())
    return (
      url.pathname === "/api/location" && url.searchParams.get("location[directory]") === destination && response.ok()
    )
  })
  session.directory = destination
  await transport.close()
  await transport.waitForConnection({ after: connection.id })
  await resolved
  await expect(prompt).toBeEditable()
  await expect(prompt).toHaveText("Draft before disconnect")
  await expect(page.getByText("Resume in the current worktree", { exact: true })).toBeVisible()
  await expect(page.getByText("Session location unavailable", { exact: true })).toHaveCount(0)
  await expect(page.getByRole("button", { name: "Choose directory", exact: true })).toHaveCount(0)
  expect(recovery).toEqual([])
})

test("ignores an old failed location read after reconnecting", async ({ page }) => {
  const recovery = recoveryRequests(page)
  const directory = "/projects/reconnected-tree"
  const sessionID = "ses_location_stale_response"
  const requested = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  const transport = await installSseTransport(page, { server: fixture.serverKey })
  await mockOpenCodeServer(page, {
    directory: fixture.directory,
    project: fixture.project,
    provider: fixture.provider,
    sessions: [{ id: sessionID, projectID: fixture.project.id, directory }],
    fileList: () => [],
    pageMessages: () => ({ items: [] }),
  })
  let requests = 0
  await page.route("**/api/location?**", async (route) => {
    if (new URL(route.request().url()).searchParams.get("location[directory]") !== directory) return route.fallback()
    requests++
    if (requests > 1) return route.fallback()
    requested.resolve()
    await release.promise
    return route.fulfill({
      status: 500,
      body: "",
      headers: { "access-control-allow-origin": "*" },
    })
  })
  await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${sessionID}`)
  await requested.promise
  const prompt = page.getByRole("textbox", { name: "Prompt", exact: true })
  await expect(prompt).toBeEditable()
  await prompt.fill("Keep typing here")
  const connection = await transport.waitForConnection()
  const metadata = page.waitForResponse((response) => new URL(response.url()).pathname === `/api/session/${sessionID}`)
  const resolved = page.waitForResponse((response) => {
    const url = new URL(response.url())
    return (
      url.pathname === "/api/location" && url.searchParams.get("location[directory]") === directory && response.ok()
    )
  })
  await transport.close()
  await transport.waitForConnection({ after: connection.id })
  await metadata
  release.resolve()
  await resolved
  await expect(prompt).toBeEditable()
  await expect(prompt).toHaveText("Keep typing here")
  await expect(page.getByText("Session location unavailable", { exact: true })).toHaveCount(0)
  await expect(page.getByRole("button", { name: "Choose directory", exact: true })).toHaveCount(0)
  expect(requests).toBe(2)
  expect(recovery).toEqual([])
})

function recoveryRequests(page: Page) {
  const requests: string[] = []
  page.on("request", (request) => {
    const path = new URL(request.url()).pathname
    if (request.method() === "POST" && /^\/api\/(session\/[^/]+\/move$|worktree(?:\/|$))/.test(path))
      requests.push(path)
  })
  return requests
}

async function missingLocation(page: Page, directory: string) {
  let requests = 0
  await page.route("**/api/location?**", (route) => {
    if (new URL(route.request().url()).searchParams.get("location[directory]") !== directory) return route.fallback()
    requests++
    return route.fulfill({
      status: 404,
      // The server's wire body for a missing Location, which the client decodes into its own typed error.
      json: { _tag: "LocationNotFoundError", location: { directory }, message: `Location not found: ${directory}` },
      headers: { "access-control-allow-origin": "*" },
    })
  })
  return () => requests
}

async function moveRequests(page: Page, sessionID: string) {
  const moves: unknown[] = []
  await page.route(`**/api/session/${sessionID}/move`, (route) => {
    if (route.request().method() !== "POST") return route.fallback()
    moves.push(route.request().postDataJSON())
    return route.fulfill({ status: 204, headers: { "access-control-allow-origin": "*" } })
  })
  return moves
}

function fileDiff(file: string) {
  return {
    file,
    additions: 1,
    deletions: 1,
    status: "modified",
    patch: `diff --git a/${file} b/${file}\n--- a/${file}\n+++ b/${file}\n@@ -1 +1 @@\n-export const value = 'before'\n+export const value = 'after'\n`,
  }
}
