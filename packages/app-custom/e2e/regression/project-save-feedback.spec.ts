import { expect, test } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"

test("keeps project edits available for retry after a failed save", async ({ page }) => {
  const directory = "/projects/save-feedback"
  const project = {
    id: "project-save-feedback",
    canonical: directory,
    name: "Save feedback",
    vcs: "git",
    time: { created: 1, updated: 1 },
    sandboxes: [],
  }
  const requests: unknown[] = []
  await mockOpenCodeServer(page, {
    directory,
    project,
    sessions: [],
    pageMessages: () => ({ items: [] }),
    provider: { all: [], connected: [], default: {} },
  })
  await page.addInitScript((directory) => {
    localStorage.setItem(
      "opencode.global.dat:server",
      JSON.stringify({ projects: { local: [{ worktree: directory, expanded: true }] } }),
    )
  }, directory)
  await page.route("**/api/project/project-save-feedback", async (route) => {
    requests.push(route.request().postDataJSON())
    if (requests.length === 1) {
      await route.fulfill({ status: 400, json: { message: "Project save failed in the fixture" } })
      return
    }
    await route.fulfill({ json: { ...project, name: "Retried project", commands: { start: "bun install" } } })
  })

  await page.goto("/")
  await page.getByRole("button", { name: "Settings", exact: true }).click()
  const settings = page.getByTestId("settings-screen")
  await settings.getByRole("tab", { name: "Projects", exact: true }).click()
  await settings.getByText("Save feedback", { exact: true }).click()
  const dialog = page.getByRole("dialog")
  await dialog.getByRole("textbox").fill("Retried project")
  await dialog.getByRole("tab", { name: "Scripts", exact: true }).click()
  await expect(dialog.getByText("Use $OPENCODE_WORKTREE_BASE for the base worktree.", { exact: true })).toBeVisible()
  await expect(dialog.getByText("Use $OPENCODE_WORKTREE_PATH for the new worktree.", { exact: true })).toBeVisible()
  await dialog.getByRole("textbox", { name: "Worktree startup script" }).fill("bun install")

  await dialog.getByRole("button", { name: "Save", exact: true }).click()
  const toast = page
    .getByRole("listitem", { includeHidden: true })
    .filter({ has: page.getByText("Request failed", { exact: true }) })
  await expect(toast).toBeVisible()
  await expect(dialog).toBeVisible()
  await expect(dialog.getByRole("textbox", { name: "Worktree startup script" })).toHaveValue("bun install")
  await dialog.getByRole("tab", { name: "S Save feedback", exact: true }).click()
  await expect(dialog.getByRole("textbox")).toHaveValue("Retried project")

  await dialog.getByRole("button", { name: "Save", exact: true }).click()
  await expect(dialog).toBeHidden()
  expect(requests).toEqual([
    {
      name: "Retried project",
      icon: { color: "", override: "" },
      commands: { start: "bun install" },
    },
    {
      name: "Retried project",
      icon: { color: "", override: "" },
      commands: { start: "bun install" },
    },
  ])
})
