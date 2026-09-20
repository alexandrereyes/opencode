import { expect, test } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"

const projects = Array.from({ length: 9 }, (_, index) => ({
  id: `project-settings-${index + 1}`,
  name: `Project ${index + 1}`,
  canonical: `/projects/project-${index + 1}`,
  vcs: "git",
  time: { created: 1, updated: 1 },
  sandboxes: [],
}))

test("searches tracked projects and exposes keyboard project actions", async ({ page }) => {
  await mockOpenCodeServer(page, {
    directory: projects[0].canonical,
    project: projects[0],
    sessions: [],
    pageMessages: () => ({ items: [] }),
    provider: { all: [], connected: [], default: {} },
  })
  await page.route("**/api/project", (route) =>
    route.fulfill({ json: projects, headers: { "access-control-allow-origin": "*" } }),
  )
  await page.addInitScript(
    (tracked) => {
      localStorage.setItem(
        "opencode.global.dat:server",
        JSON.stringify({
          projects: { local: tracked.map((project) => ({ worktree: project.canonical, expanded: true })) },
        }),
      )
    },
    projects.slice(0, 8),
  )

  await page.goto("/")
  await page.getByRole("button", { name: "Settings", exact: true }).click()
  const settings = page.getByTestId("settings-screen")
  await settings.getByRole("tab", { name: "Projects", exact: true }).click()
  const panel = settings.getByRole("tabpanel")
  const search = panel.getByRole("searchbox", { name: "Search projects", exact: true })
  await expect(search).toBeVisible()
  await expect(panel.getByText(projects[1].canonical, { exact: true })).toBeVisible()
  await expect(panel.getByText(projects[8].name, { exact: true })).toBeHidden()

  await search.fill("Missing project")
  await expect(panel.getByText("No results found", { exact: true })).toBeVisible()
  await search.fill("Project 8")
  await expect(panel.getByRole("button", { name: "Project 8", exact: true })).toBeVisible()
  await expect(panel.getByRole("button", { name: "Project 1", exact: true })).toBeHidden()
  await panel.getByRole("button", { name: "Clear", exact: true }).click()
  await expect(search).toBeFocused()
  await expect(panel.getByRole("button", { name: "Project 1", exact: true })).toBeVisible()

  const project = panel.getByRole("button", { name: "Project 2", exact: true })
  await project.focus()
  await project.press("Shift+F10")
  await page.getByRole("menuitem", { name: "Rename", exact: true }).click()
  const editor = page.getByRole("dialog")
  await expect(editor.getByRole("textbox")).toHaveValue("Project 2")
  await editor.getByRole("button", { name: "Cancel", exact: true }).click()
  await expect(editor).toBeHidden()

  await project.focus()
  await project.press("Shift+F10")
  await page.getByRole("menuitem", { name: "Close", exact: true }).click()
  const confirmation = page.getByRole("dialog")
  await expect(
    confirmation.getByRole("heading", { name: "Remove Project 2 from the sidebar?", exact: true }),
  ).toBeVisible()
  await confirmation.getByRole("button", { name: "Cancel", exact: true }).click()
  await expect(confirmation).toBeHidden()
  await expect(project).toBeFocused()

  await project.press("Shift+F10")
  await page.getByRole("menuitem", { name: "Close", exact: true }).click()
  await page.keyboard.press("Escape")
  await expect(confirmation).toBeHidden()
  await expect(project).toBeFocused()

  await project.press("Shift+F10")
  await page.getByRole("menuitem", { name: "Close", exact: true }).click()
  await confirmation.getByRole("button", { name: "Remove from sidebar", exact: true }).click()
  await expect(project).toBeHidden()
  await expect(panel.getByRole("button", { name: "Project 3", exact: true })).toBeFocused()
  await expect(search).toBeHidden()
})
