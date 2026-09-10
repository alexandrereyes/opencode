import { expect, test } from "@playwright/test"
import type { OpenCodeEvent, SessionMessageInfo, ShellInfo } from "@opencode/client/promise"
import { mockOpenCodeServer } from "../utils/mock-server"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"

test("background shells follow live ownership and do not return from old history after exit or reload", async ({
  page,
}) => {
  const events: OpenCodeEvent[] = []
  const sessions = fixture.sessions.map((session) => ({ ...session }))
  const source = sessions.find((session) => session.id === fixture.sourceID)
  if (!source) throw new Error("Source session required")
  const shells: ShellInfo[] = [fixture.sourceID, fixture.targetID].map((id) => ({
    id: `shell_${id}`,
    command: `build for ${id}`,
    status: "running",
    cwd: fixture.directory,
    shell: "sh",
    file: "output.log",
    metadata: { sessionID: id },
    time: { started: 1700000000000 },
  }))
  const assistant = fixture.messages[fixture.sourceID].at(-1)
  if (assistant?.type !== "assistant") throw new Error("Assistant fixture required")
  const messages: SessionMessageInfo[] = [
    ...fixture.messages[fixture.sourceID].slice(-2, -1),
    {
      ...assistant,
      content: [
        {
          type: "tool",
          id: "tool_background",
          name: "shell",
          time: { created: 1700000000000, ran: 1700000000000, completed: 1700000000010 },
          state: {
            status: "completed",
            input: { command: shells[0].command },
            content: [{ type: "text", text: "Backgrounded" }],
            metadata: { shellID: shells[0].id, status: "running" },
          },
        },
      ],
    },
  ]
  await mockOpenCodeServer(page, {
    sessions,
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages: (id) => ({ items: id === fixture.sourceID ? messages : (fixture.messages[id]?.slice(-2) ?? []) }),
    events: () => events.splice(0),
  })
  await page.route("**/api/shell?*", (route) => {
    const directory = new URL(route.request().url()).searchParams.get("location[directory]") ?? fixture.directory
    return route.fulfill({
      json: {
        location: {
          directory,
          project: { id: fixture.project.id, directory: fixture.directory, canonical: fixture.directory },
        },
        data: directory === fixture.directory ? shells : [],
      },
    })
  })
  await page.route("**/api/session/*/message?*", (route) => {
    const url = new URL(route.request().url())
    if (url.searchParams.get("type") !== "location-switched") return route.fallback()
    const moved =
      source.directory !== fixture.directory &&
      url.pathname.includes(fixture.sourceID) &&
      !url.searchParams.has("cursor")
    return route.fulfill({
      json: {
        data: moved
          ? [
              {
                id: "msg_background_move",
                type: "location-switched",
                time: { created: 1700000000100 },
                location: { directory: source.directory },
                previous: { location: { directory: fixture.directory } },
              },
            ]
          : [],
        cursor: moved ? { next: "moves-page-two" } : {},
      },
    })
  })
  await installStressSessionTabs(page)
  await page.goto(stressSessionHref(fixture.sourceID))
  const overview = page.locator('[data-slot="context-overview"]')
  const tasks = overview.getByRole("list", { name: "Background tasks", exact: true })
  await expect(tasks.getByRole("button", { name: `build for ${fixture.sourceID} Shell`, exact: true })).toBeVisible()
  await expect(tasks.getByRole("button")).toHaveCount(1)
  await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.targetID)}"]`).click()
  await expect(tasks.getByRole("button", { name: `build for ${fixture.targetID} Shell`, exact: true })).toBeVisible()
  await expect(tasks.getByRole("button")).toHaveCount(1)
  await page.locator(`[data-slot="titlebar-tabs"] a[href="${stressSessionHref(fixture.sourceID)}"]`).click()
  await expect(tasks.getByRole("button", { name: `build for ${fixture.sourceID} Shell`, exact: true })).toBeVisible()
  const destination = "C:/OpenCode/MovedBackgroundProject"
  const moved = page.waitForResponse((response) => {
    const url = new URL(response.url())
    return url.pathname === "/api/shell" && url.searchParams.get("location[directory]") === destination
  })
  source.directory = destination
  events.push({
    id: "evt_background_move",
    created: Date.now(),
    type: "session.moved",
    durable: { aggregateID: source.id, seq: 1, version: 1 },
    data: { sessionID: source.id, projectID: source.projectID, location: { directory: destination } },
  })
  await moved
  await expect(tasks.getByRole("button", { name: `build for ${fixture.sourceID} Shell`, exact: true })).toBeVisible()
  await page.reload()
  await expect(tasks.getByRole("button", { name: `build for ${fixture.sourceID} Shell`, exact: true })).toBeVisible()
  const ended = shells.shift()
  if (!ended) throw new Error("Missing active shell")
  events.push({
    id: "evt_shell_cancelled",
    type: "shell.exited",
    created: Date.now(),
    location: { directory: fixture.directory },
    data: { id: ended.id, status: "killed" },
  })
  await expect(overview.getByText("No background tasks running.", { exact: true })).toBeVisible()
  await page.reload()
  await expect(overview.getByText("No background tasks running.", { exact: true })).toBeVisible()
})
