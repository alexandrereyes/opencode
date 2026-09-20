import { expect, test } from "@playwright/test"
import { currentSession, mockOpenCodeServer } from "../utils/mock-server"

const directory = "C:/Projects/workspace-live-counts"
const workspace = `${directory}/live`
const empty = `${directory}/empty`
const project = {
  id: "proj_workspace_live_counts",
  canonical: directory,
  name: "Live counts",
  vcs: "git",
  time: { created: 1, updated: 1 },
  sandboxes: [workspace],
}

test.use({ viewport: { width: 1440, height: 1000 }, colorScheme: "dark" })

test("updates counts from live sessions and hides empty deletion while inventory sessions refetch", async ({ page }) => {
  const sessions: ({ id: string } & Record<string, unknown>)[] = []
  await mockOpenCodeServer(page, {
    directory,
    project,
    provider: { all: [], connected: [], default: {} },
    sessions,
    pageMessages: () => ({ items: [] }),
  })
  await page.addInitScript((directory) => {
    localStorage.setItem(
      "opencode.global.dat:server",
      JSON.stringify({ projects: { local: [{ worktree: directory, expanded: true }] } }),
    )
  }, directory)
  await page.goto("/")
  await page.getByRole("button", { name: "Settings", exact: true }).click()
  const settings = page.getByTestId("settings-screen")
  await settings.getByRole("tab", { name: "Worktrees", exact: true }).click()
  await expect(settings.getByText("0 sessions in Live counts", { exact: true })).toBeVisible()

  const live = currentSession(
    {
      id: "ses_workspace_live",
      projectID: project.id,
      title: "Live workspace session",
      directory: workspace,
      time: { created: 2, updated: 2 },
    },
    directory,
  )
  sessions.push(live)
  await page.evaluate(
    ({ session, projectID, workspace }) => {
      const host = window as Window & { __mockServerStream?: { push: (events: unknown[]) => void } }
      if (!host.__mockServerStream) throw new Error("Missing fixture event stream")
      host.__mockServerStream.push([
        {
          id: "evt_workspace_live_created",
          created: 2,
          type: "session.created",
          durable: { aggregateID: session.id, seq: 0, version: 1 },
          data: {
            sessionID: session.id,
            projectID,
            location: { directory: workspace },
            slug: "workspace-live",
            title: session.title,
            version: "2.0.0",
          },
        },
      ])
    },
    { session: live, projectID: project.id, workspace },
  )
  await expect(settings.getByText("1 session in Live counts", { exact: true })).toBeVisible()
  await expect(settings.getByText("Live workspace session", { exact: true })).toBeVisible()

  const release = Promise.withResolvers<void>()
  project.sandboxes.push(empty)
  await page.route("**/api/session?*", async (route) => {
    if (new URL(route.request().url()).searchParams.get("directory") === empty) await release.promise
    await route.fallback()
  })
  await settings.getByRole("tab", { name: "Preferences", exact: true }).click()
  const requested = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === "/api/session" &&
      new URL(request.url()).searchParams.get("directory") === empty,
  )
  await settings.getByRole("tab", { name: "Worktrees", exact: true }).click()
  await requested
  await expect(settings.getByText(empty, { exact: true })).toBeVisible()
  await expect(settings.getByText("1 session in Live counts", { exact: true })).toBeVisible()
  await settings.getByRole("button", { name: "More options", exact: true }).click()
  await expect(page.getByRole("menuitem", { name: "Delete worktrees without sessions", exact: true })).toHaveCount(0)

  const refreshed = page.waitForResponse((response) => {
    const url = new URL(response.url())
    return url.pathname === "/api/session" && url.searchParams.get("directory") === empty && response.ok()
  })
  release.resolve()
  await refreshed
  await expect(page.getByRole("menuitem", { name: "Delete worktrees without sessions", exact: true })).toBeVisible()
})
