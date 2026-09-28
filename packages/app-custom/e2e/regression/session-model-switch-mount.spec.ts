import { expect, test } from "@playwright/test"
import { mockOpenCodeServer } from "../utils/mock-server"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { installStressSessionTabs, stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { waitForStableTimeline } from "../performance/timeline/session-tab-switch-probe"

test.use({ serviceWorkers: "block" })

for (const [width, height] of [
  [1440, 900],
  [390, 844],
]) {
  test(`switching models keeps the session mounted and the timeline scroll position at ${width}px`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height })
    // Paid models open the regular picker instead of the free-models dialog.
    const model = { ...fixture.provider.all[0]!.models["claude-opus-4-6"], cost: { input: 1, output: 1 } }
    await mockOpenCodeServer(page, {
      ...fixture,
      provider: {
        ...fixture.provider,
        all: [
          {
            ...fixture.provider.all[0]!,
            models: {
              "claude-opus-4-6": model,
              "other-model": { ...model, id: "other-model", name: "Other Model" },
            },
          },
        ],
      },
      pageMessages: (id) => ({ items: fixture.messages[id] ?? [] }),
      subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
    })
    // Both models must be visible in the picker; the shared mock profile shows none.
    await page.route("**/api/rpc/custom.preferences/*", (route) =>
      route.request().method() === "OPTIONS"
        ? route.fallback()
        : route.fulfill({
            headers: { "access-control-allow-origin": "*" },
            json: {
              output: {
                version: 1,
                revision: 0,
                imported: true,
                data: {
                  projects: {},
                  sidebarOrder: [],
                  pinnedSessions: [],
                  models: {
                    user: ["claude-opus-4-6", "other-model"].map((modelID) => ({
                      providerID: "opencode",
                      modelID,
                      visibility: "show",
                    })),
                    variant: {},
                  },
                  settings: {
                    followUpBehavior: "steer",
                    autoApprove: false,
                    autoSave: true,
                    tabLayout: "vertical",
                    notifications: { agent: true, permissions: true, errors: false },
                  },
                },
              },
            },
          }),
    )
    await installStressSessionTabs(page)
    await page.goto(stressSessionHref(fixture.sourceID))
    await waitForStableTimeline(page, fixture.expected.sourceMessageIDs.at(-1)!)
    await expect(page.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(0)
    const viewport = page.locator('[data-slot="session-timeline-scroll"] .scroll-view__viewport')
    await viewport.hover()
    await page.mouse.wheel(0, -1900)
    await expect
      .poll(() => viewport.evaluate((el) => el.scrollHeight - el.clientHeight - el.scrollTop))
      .toBeGreaterThan(1500)
    const probe = await viewport.evaluateHandle((element) => {
      const state = { removed: 0 }
      const observer = new MutationObserver((records) =>
        records.forEach((record) =>
          record.removedNodes.forEach((node) => {
            if (node === element || node.contains(element)) state.removed++
          }),
        ),
      )
      observer.observe(document.body, { childList: true, subtree: true })
      return { element, state, observer, scrollTop: element.scrollTop }
    })

    const control = page.locator('[data-action="composer-model"]')
    await expect(control).toHaveText("Claude Opus 4.6")
    await control.click()
    const search = page.getByPlaceholder("Search models", { exact: true })
    await expect(search).toBeFocused()
    await search.fill("Other Model")
    await search.press("Enter")
    await expect(control).toHaveText("Other Model")

    expect(
      await probe.evaluate(({ element, state, observer, scrollTop }) => {
        observer.disconnect()
        return {
          removed: state.removed,
          connected: element.isConnected,
          scrolled: Math.abs(element.scrollTop - scrollTop) < 3,
        }
      }),
    ).toEqual({ removed: 0, connected: true, scrolled: true })
    await probe.dispose()
  })
}
