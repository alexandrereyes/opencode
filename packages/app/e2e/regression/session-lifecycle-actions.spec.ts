import { expect, test } from "@playwright/test"
import { fixture, pageMessages } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { currentSession, mockOpenCodeServer } from "../utils/mock-server"

for (const layout of ["horizontal", "vertical", "mobile"] as const) {
  test.describe(layout, () => {
    test.use({
      viewport: layout === "mobile" ? { width: 390, height: 844 } : { width: 1280, height: 800 },
      hasTouch: layout === "mobile",
    })

    test("session menu confirms deletion and archives without deleting", async ({ page }, testInfo) => {
      const sessions = structuredClone(fixture.sessions)
      const mutations: string[] = []
      await mockOpenCodeServer(page, {
        sessions,
        provider: fixture.provider,
        directory: fixture.directory,
        project: fixture.project,
        pageMessages,
      })
      await installStressSessionTabs(page)
      await page.route("**/api/rpc/custom.navigation/list*", (route) =>
        route.fulfill({
          json: {
            output: {
              data: sessions.map((session) => ({ session: currentSession(session), messageAt: session.time.updated })),
            },
          },
        }),
      )
      await page.addInitScript((layout) => {
        localStorage.setItem(
          "settings.v3",
          JSON.stringify({
            appearance: { tabLayout: layout === "vertical" ? "vertical" : "horizontal", showProjectName: true },
          }),
        )
      }, layout)
      await page.route("**/api/rpc/custom.archive/archive", async (route) => {
        expect(route.request().method()).toBe("POST")
        expect(route.request().postDataJSON()).toEqual({ input: { sessionID: fixture.targetID } })
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
      if (layout === "vertical") {
        await page.getByRole("button", { name: "Attention view", exact: true }).click()
        await expect(page.getByRole("navigation", { name: "Sessions", exact: true })).toHaveAttribute(
          "data-mode",
          "projects",
        )
      }
      const scope = page.locator(
        layout === "mobile"
          ? '[data-slot="mobile-tabs-drawer"]'
          : layout === "vertical"
            ? '[data-slot="vertical-tabs-sidebar"]'
            : '[data-slot="titlebar-tabs"]',
      )
      const matchingTabs = scope.locator("[data-titlebar-tab]").filter({
        has: page.locator(`[data-titlebar-tab-link][href="${stressSessionHref(fixture.targetID)}"]`),
      })
      const tab =
        layout === "vertical" ? matchingTabs.filter({ has: page.locator('[data-slot="tab-project"]') }) : matchingTabs
      const more = tab.getByRole("button", { name: "More options", exact: true })
      if (layout === "vertical") {
        await tab.hover()
        await expect(tab.getByRole("button", { name: "Archive", exact: true })).toBeEnabled()
      } else {
        await expect(more).toBeEnabled()
        await more.click()
        await expect(page.getByRole("menuitem", { name: "Archive", exact: true })).toBeVisible()
      }
      await page.screenshot({ path: testInfo.outputPath(`${layout}-session-menu.png`), animations: "disabled" })
      if (layout === "vertical") await tab.getByRole("button", { name: "Delete", exact: true }).click()
      else await page.getByRole("menuitem", { name: "Delete…", exact: true }).click()
      const dialog = page.getByRole("dialog", { name: "Delete session", exact: true })
      await expect(dialog).toContainText(fixture.expected.targetTitle)
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
      if (layout === "vertical") await tab.hover()
      else await more.click()
      const archived = page.waitForResponse((response) => response.url().endsWith("/api/rpc/custom.archive/archive"))
      if (layout === "vertical") await tab.getByRole("button", { name: "Archive", exact: true }).click()
      else await page.getByRole("menuitem", { name: "Archive", exact: true }).click()
      expect((await archived).status()).toBe(200)
      await expect(tab).toHaveCount(0)
      expect(mutations).toEqual(["archive"])
      await expect(page).toHaveURL(stressSessionHref(fixture.sourceID))
    })
  })
}
