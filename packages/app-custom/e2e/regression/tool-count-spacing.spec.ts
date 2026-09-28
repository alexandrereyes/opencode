import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"
import {
  assistantMessage,
  directory,
  project,
  session,
  sessionID,
  shell,
  userMessage,
  validateTimelineMessages,
} from "../performance/timeline-stability/fixture"

const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test.use({ serviceWorkers: "block" })

for (const [width, height] of [
  [1440, 900],
  [390, 844],
]) {
  test(`tool count summary uses tabular numbers and single gaps at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await mockOpenCodeServer(page, {
      directory,
      project: project(),
      provider: { all: [], connected: [], default: {} },
      sessions: [session()],
      pageMessages: () => ({
        items: validateTimelineMessages([
          userMessage(),
          assistantMessage([shell("prt_count_shell", "completed", "done")]),
        ]),
      }),
      subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
    })
    await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)

    const trigger = page.locator('[data-component="context-tool-group-trigger"][aria-label="Used 1 Shell"]')
    const count = trigger.locator('[data-slot="context-tool-group-count"]')
    await expect(count).toHaveText("1")
    await expect(count).toHaveCSS("font-variant-numeric", "tabular-nums")
    const gaps = await trigger.evaluate((element) => {
      const box = (selector: string) => element.querySelector(selector)!.getBoundingClientRect()
      const prefix = box('[data-slot="context-tool-group-prefix"]')
      const count = box('[data-slot="context-tool-group-count"]')
      const title = box('[data-slot="basic-tool-tool-title"]')
      return [Math.round(count.left - prefix.right), Math.round(title.left - count.right)]
    })
    expect(gaps).toEqual([4, 4])
  })
}
