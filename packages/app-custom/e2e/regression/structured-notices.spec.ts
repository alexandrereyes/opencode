import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { timelinePresets } from "@opencode/session-ui-custom/timeline/detail"
import { mockOpenCodeServer } from "../utils/mock-server"
import { directory, project, session, sessionID, userMessage } from "../performance/timeline-stability/fixture"

const server = `http://127.0.0.1:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4999"}`

for (const viewport of [
  { width: 1440, height: 900 },
  { width: 390, height: 844 },
]) {
  test(`structured notices retain legacy fallback at ${viewport.width}`, async ({ page }) => {
    await page.setViewportSize(viewport)
    await page.addInitScript(
      (detail) => {
        localStorage.setItem("settings.v3", JSON.stringify({ general: { timelineDetail: detail } }))
      },
      { ...timelinePresets[2].value, notices: { placement: "separate" } },
    )
    await mockOpenCodeServer(page, {
      directory,
      project: project(),
      provider: { all: [], connected: [], default: {} },
      sessions: [session()],
      subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
      pageMessages: () => ({
        items: [
          userMessage(undefined, { created: 1 }),
          {
            id: "msg_structured_instructions",
            type: "system",
            text: "Updated content",
            description: "Changed guidance",
            metadata: { notice: "instructions", instructionSources: ["AGENTS.md", "skills/review"] },
            time: { created: 2 },
          },
          {
            id: "msg_structured_restart",
            type: "synthetic",
            text: "Resume",
            description: "Restart marker",
            metadata: { notice: "restart" },
            time: { created: 3 },
          },
          {
            id: "msg_legacy_instructions",
            type: "system",
            text: "Old content",
            description: "Instructions updated: LEGACY.md",
            time: { created: 4 },
          },
          {
            id: "msg_legacy_restart",
            type: "synthetic",
            text: "Resume",
            description: "Continuing after restart",
            time: { created: 5 },
          },
        ],
      }),
    })
    await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
    const notices = page.locator('[data-slot="session-timeline-notice"]')
    await expect(notices).toHaveCount(4)
    await expect(notices.filter({ hasText: "AGENTS.md" })).toContainText("Instructions updated")
    await expect(notices.filter({ hasText: "AGENTS.md" })).toContainText("skills/review")
    await expect(notices.filter({ hasText: "LEGACY.md" })).toContainText("Instructions updated")
    await expect(notices.filter({ hasText: "Continuing after restart" })).toHaveCount(2)
    await expect(notices.filter({ hasText: "Changed guidance" })).toHaveCount(0)
    await expect(notices.filter({ hasText: "Restart marker" })).toHaveCount(0)
  })
}
