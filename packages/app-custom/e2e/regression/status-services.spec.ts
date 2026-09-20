import { expect, test } from "@playwright/test"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { mockStressTimeline, stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { expectSessionTitle } from "../utils/waits"

test.use({ permissions: ["clipboard-read", "clipboard-write"] })

test("status services load, recover, refresh from events, and copy the remote config path", async ({ page }) => {
  const firstMcp = Promise.withResolvers<void>()
  const state = { controlMcp: false, mcpFails: true, pluginFails: false, updated: false }
  const configPath = "C:/OpenCode/SmokeProject/opencode.json"
  await page.addInitScript(() => {
    localStorage.setItem("settings.v3", JSON.stringify({ general: { showStatus: true } }))
  })
  await mockStressTimeline(page)
  await page.route("**/api/mcp**", async (route) => {
    if (new URL(route.request().url()).pathname !== "/api/mcp") return route.fallback()
    if (!state.controlMcp) return route.fallback()
    await firstMcp.promise
    if (state.mcpFails) return route.fulfill({ status: 500, json: { message: "Unavailable" } })
    return route.fulfill({
      json: {
        location: { directory: fixture.directory },
        data: [{ name: "figma", status: { status: "connected" } }],
      },
    })
  })
  await page.route("**/api/plugin**", (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback()
    if (state.pluginFails) return route.fulfill({ status: 500, json: { message: "Unavailable" } })
    return route.fulfill({
      json: {
        location: { directory: fixture.directory },
        data: [
          { id: "builtin", source: { type: "builtin" }, features: {}, state: { status: "active" } },
          {
            id: "broken-plugin",
            source: { type: "local", path: "C:/OpenCode/SmokeProject/.opencode/plugin.ts" },
            features: { server: true },
            state: { status: "failed", error: "Plugin failed to activate" },
          },
          ...(state.updated
            ? [
                {
                  id: "updated-plugin",
                  source: { type: "package", target: "updated-plugin" },
                  features: {},
                  state: { status: "active" },
                },
              ]
            : []),
        ],
      },
    })
  })
  await page.route("**/api/skill**", (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback()
    return route.fulfill({
      json: {
        location: { directory: fixture.directory },
        data: [
          { id: "review", name: "review", path: "C:/skills/review/SKILL.md", content: "Review" },
          ...(state.updated
            ? [{ id: "updated-skill", name: "updated-skill", path: "C:/skills/updated/SKILL.md", content: "Updated" }]
            : []),
        ],
      },
    })
  })
  await page.route("**/api/config**", (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback()
    return route.fulfill({
      json: [
        {
          type: "document",
          path: configPath,
          info: {
            plugins: ["broken-plugin"],
            skills: { paths: ["C:/skills"] },
            lsp: state.updated
              ? { rust: { command: ["rust-analyzer"], extensions: [".rs"] } }
              : {
                  typescript: { command: ["typescript-language-server", "--stdio"], extensions: [".ts"] },
                  eslint: { disabled: true },
                },
          },
        },
      ],
    })
  })

  await page.goto(stressSessionHref(fixture.targetID))
  await expectSessionTitle(page, fixture.sessions.find((session) => session.id === fixture.targetID)!.title)
  state.controlMcp = true
  state.pluginFails = true
  const trigger = page.getByRole("button", { name: "Status", exact: true })
  await trigger.click()
  const status = page.getByLabel("Server configurations", { exact: true })
  await expect(status.getByRole("status")).toHaveText("Loading")
  await expect(status.getByText("No MCP servers configured", { exact: true })).toHaveCount(0)
  firstMcp.resolve()
  await expect(status.getByRole("alert")).toContainText("Request failed")
  state.mcpFails = false
  await status.getByRole("button", { name: "Retry", exact: true }).click()
  await expect(status.getByText("figma", { exact: true })).toBeVisible()

  await status.getByRole("tab", { name: /Plugins$/ }).click()
  await expect(status.getByRole("alert")).toContainText("Request failed")

  state.pluginFails = false
  await status.getByRole("button", { name: "Retry", exact: true }).click()
  await expect(status.getByTitle("Plugin failed to activate")).toContainText("broken-plugin")
  await expect(status.getByText("Failed", { exact: true })).toBeVisible()

  await status.getByRole("tab", { name: "1 Skills", exact: true }).click()
  await expect(status.getByText("review", { exact: true })).toBeVisible()
  await status.getByRole("tab", { name: "2 LSP", exact: true }).click()
  await expect(status.getByText("typescript", { exact: true })).toBeVisible()
  await expect(status.getByText("Enabled in config", { exact: true })).toBeVisible()
  await expect(status.getByText("eslint", { exact: true })).toBeVisible()
  await expect(status.getByText("Disabled in config", { exact: true })).toBeVisible()
  await status.getByRole("button", { name: "Copy configuration path", exact: true }).click()
  await expect(status.getByRole("button", { name: "Copied", exact: true })).toBeVisible()
  await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(configPath)

  state.updated = true
  await page.evaluate((directory) => {
    const host = window as Window & { __mockServerStream?: { push: (events: unknown[]) => void } }
    host.__mockServerStream?.push([
      { id: "evt_plugin_updated", type: "plugin.updated", location: { directory }, data: {} },
      { id: "evt_skill_updated", type: "skill.updated", location: { directory }, data: {} },
      { id: "evt_config_updated", type: "config.updated", location: { directory }, data: {} },
    ])
  }, fixture.directory)

  await status.getByRole("tab", { name: /Plugins$/ }).click()
  await expect(status.getByText("updated-plugin", { exact: true })).toBeVisible()
  await status.getByRole("tab", { name: /Skills$/ }).click()
  await expect(status.getByText("updated-skill", { exact: true })).toBeVisible()
  await status.getByRole("tab", { name: /LSP$/ }).click()
  await expect(status.getByText("rust", { exact: true })).toBeVisible()
  await expect(page.getByText("typescript", { exact: true })).toHaveCount(0)
})
