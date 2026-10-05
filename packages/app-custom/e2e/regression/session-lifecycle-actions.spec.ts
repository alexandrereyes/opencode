import { expect, test } from "@playwright/test"
import type { OpenCodeEvent } from "@opencode/client/promise"
import { fixture, pageMessages } from "../performance/timeline/session-timeline-stress.fixture"
import { stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { currentSession, mockOpenCodeServer } from "../utils/mock-server"

for (const layout of ["desktop", "mobile"] as const) {
  test.describe(layout, () => {
    test.use({
      viewport: layout === "mobile" ? { width: 390, height: 844 } : { width: 1280, height: 800 },
      hasTouch: layout === "mobile",
    })

    test("session menu confirms deletion and archives without deleting", async ({ page }, testInfo) => {
      const sessions = structuredClone(fixture.sessions)
      const sessionID = layout === "mobile" ? fixture.sourceID : fixture.targetID
      const mutations: string[] = []
      await mockOpenCodeServer(page, {
        sessions,
        provider: fixture.provider,
        directory: fixture.directory,
        project: fixture.project,
        pageMessages,
      })
      await page.addInitScript(
        ({ server, sessionIDs }) => {
          localStorage.setItem(
            "opencode.window.browser.dat:tabs",
            JSON.stringify(sessionIDs.map((sessionId) => ({ type: "session", server, sessionId }))),
          )
        },
        {
          server: `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`,
          sessionIDs: [fixture.sourceID, fixture.targetID],
        },
      )
      await page.route("**/api/rpc/custom.navigation/list*", (route) =>
        route.fulfill({
          json: {
            output: {
              data: sessions.map((session) => ({ session: currentSession(session), messageAt: session.time.updated })),
            },
          },
        }),
      )
      await page.addInitScript(() => {
        localStorage.setItem(
          "settings.v3",
          JSON.stringify({
            appearance: { tabLayout: "vertical", showProjectName: true },
          }),
        )
      })
      await page.route("**/api/rpc/custom.archive/archive", async (route) => {
        expect(route.request().method()).toBe("POST")
        expect(route.request().postDataJSON()).toEqual({ input: { sessionID } })
        mutations.push("archive")
        await route.fulfill({ json: { output: {} }, headers: { "access-control-allow-origin": "*" } })
      })
      page.on("request", (request) => {
        if (request.method() === "DELETE") mutations.push("delete")
      })
      await page.goto(stressSessionHref(fixture.sourceID))
      if (layout === "mobile") {
        await page.getByRole("button", { name: "Tabs", exact: true }).tap()
        await expect(page.getByRole("dialog", { name: "Tabs", exact: true })).not.toHaveAttribute("data-transitioning")
      }
      if (layout !== "mobile") {
        await page.getByRole("button", { name: "Attention view", exact: true }).click()
        await expect(page.getByRole("navigation", { name: "Sessions", exact: true })).toHaveAttribute(
          "data-mode",
          "projects",
        )
      }
      const scope = page.locator(
        layout === "mobile" ? '[data-slot="mobile-tabs-drawer"]' : '[data-slot="vertical-tabs-sidebar"]',
      )
      const rows =
        layout === "mobile"
          ? scope
          : scope.locator("section").filter({ has: page.getByRole("heading", { name: "Recent", exact: true }) })
      const tab = rows.locator("[data-titlebar-tab]").filter({
        has: page.locator(`[data-titlebar-tab-link][href="${stressSessionHref(sessionID)}"]`),
      })
      await tab.locator("[data-titlebar-tab-link]").click({ button: "right" })
      await expect(page.getByRole("menuitem", { name: "Archive", exact: true })).toBeVisible()
      await page.screenshot({ path: testInfo.outputPath(`${layout}-session-menu.png`), animations: "disabled" })
      await page.getByRole("menuitem", { name: "Delete…", exact: true }).click()
      const dialog = page.getByRole("dialog", { name: "Delete session", exact: true })
      await expect(dialog).toContainText(
        layout === "mobile" ? fixture.expected.sourceTitle : fixture.expected.targetTitle,
      )
      await expect(dialog).toContainText("all its child sessions")
      expect(mutations).toEqual([])
      await dialog.getByRole("button", { name: "Cancel", exact: true }).click()
      await expect(dialog).toBeHidden()
      if (layout === "mobile") {
        const drawer = page.locator('[data-slot="mobile-drawer-content"]')
        await expect(drawer).not.toHaveAttribute("data-transitioning")
        if ((await drawer.getAttribute("data-open")) === null) {
          await page.getByRole("button", { name: "Tabs", exact: true }).tap()
          await expect(drawer).not.toHaveAttribute("data-transitioning")
        }
      }
      await expect(tab).toBeVisible()
      await tab.locator("[data-titlebar-tab-link]").click({ button: "right" })
      const archived = page.waitForResponse((response) => response.url().endsWith("/api/rpc/custom.archive/archive"))
      await page.getByRole("menuitem", { name: "Archive", exact: true }).click()
      expect((await archived).status()).toBe(200)
      await expect(tab).toHaveCount(0)
      expect(mutations).toEqual(["archive"])
      if (layout === "mobile") await expect(page).not.toHaveURL(stressSessionHref(fixture.sourceID))
      if (layout === "desktop") await expect(page).toHaveURL(stressSessionHref(fixture.sourceID))
    })
  })
}

test("sidebar delete confirms inline, cancels and can retry a failure without duplicate requests", async ({ page }) => {
  const sessions = structuredClone(fixture.sessions)
  const events: OpenCodeEvent[] = []
  await mockOpenCodeServer(page, {
    sessions,
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages: () => ({ items: [] }),
    events: () => events.splice(0),
  })
  await page.route("**/api/rpc/custom.navigation/list*", (route) =>
    route.fulfill({
      json: {
        output: {
          data: sessions.map((session) => ({ session: currentSession(session), messageAt: session.time.updated })),
        },
      },
    }),
  )
  await page.addInitScript(() => {
    localStorage.setItem(
      "settings.v3",
      JSON.stringify({ appearance: { tabLayout: "vertical", showProjectName: true } }),
    )
  })
  const release = Promise.withResolvers<void>()
  const mutations: string[] = []
  await page.route(`**/api/session/${fixture.targetID}`, async (route) => {
    if (route.request().method() !== "DELETE") return route.fallback()
    mutations.push(route.request().method())
    if (mutations.length === 1) {
      await release.promise
      await route.fulfill({
        status: 400,
        json: { _tag: "BadRequestError", message: "Delete failed" },
        headers: { "access-control-allow-origin": "*" },
      })
      return
    }
    sessions.splice(
      sessions.findIndex((session) => session.id === fixture.targetID),
      1,
    )
    events.push({
      id: "evt_sidebar_deleted",
      created: Date.now(),
      type: "session.deleted",
      durable: { aggregateID: fixture.targetID, seq: 1, version: 2 },
      location: { directory: fixture.directory },
      data: { sessionID: fixture.targetID },
    })
    await route.fulfill({ status: 204, headers: { "access-control-allow-origin": "*" } })
  })
  await page.goto(stressSessionHref(fixture.sourceID))
  await page.getByRole("button", { name: "Attention view", exact: true }).click()
  const sidebar = page.getByRole("navigation", { name: "Sessions", exact: true })
  await expect(sidebar).toHaveAttribute("data-mode", "projects")
  const tab = sidebar
    .locator("section")
    .filter({ has: page.getByRole("heading", { name: "Recent", exact: true }) })
    .locator("[data-titlebar-tab]")
    .filter({ has: page.locator(`[data-titlebar-tab-link][href="${stressSessionHref(fixture.targetID)}"]`) })
  await tab.hover()
  const remove = tab.getByRole("button", { name: "Delete", exact: true })
  const confirm = tab.getByRole("button", { name: "Confirm deletion", exact: true })
  await remove.click()
  await expect(confirm).toBeFocused()
  await expect(confirm).not.toHaveCSS("background-color", "rgba(0, 0, 0, 0)")
  await expect(page.getByRole("dialog", { name: "Delete session", exact: true })).toHaveCount(0)
  expect(mutations).toEqual([])
  await confirm.press("Escape")
  await expect(remove).toBeFocused()
  await remove.press("Enter")
  await tab.getByRole("button", { name: "Archive", exact: true }).focus()
  await expect(remove).toBeVisible()
  await remove.click()
  await page.getByRole("button", { name: "Attention view", exact: true }).click()
  await page.getByRole("button", { name: "Attention view", exact: true }).click()
  await tab.hover()
  await expect(remove).toBeVisible()
  expect(mutations).toEqual([])
  await remove.click()
  await confirm.click()
  await expect(remove).toBeDisabled()
  await remove.dispatchEvent("click")
  await expect.poll(() => mutations).toEqual(["DELETE"])
  release.resolve()
  await expect(remove).toBeEnabled()
  await expect(page.getByText("Failed to delete session", { exact: true })).toBeVisible()
  await remove.press("Enter")
  await expect(confirm).toBeFocused()
  const deleted = page.waitForResponse((response) => response.request().method() === "DELETE")
  await confirm.press("Space")
  expect((await deleted).status()).toBe(204)
  await expect(tab).toHaveCount(0)
  expect(mutations).toEqual(["DELETE", "DELETE"])
  await expect(page).toHaveURL(stressSessionHref(fixture.sourceID))
})
