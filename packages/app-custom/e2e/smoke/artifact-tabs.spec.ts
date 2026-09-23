import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import type { SessionMessageInfo } from "@opencode/client/promise"
import { fixture } from "./session-timeline.fixture"
import { mockOpenCodeServer } from "../utils/mock-server"

test.use({
  httpCredentials: process.env.ARTIFACT_TEST_PASSWORD
    ? { username: "opencode", password: process.env.ARTIFACT_TEST_PASSWORD }
    : undefined,
})

const svg =
  '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="royalblue"/></svg>'
const message: SessionMessageInfo = {
  id: "msg_artifacts",
  type: "assistant",
  agent: "build",
  model: { id: "claude-opus-4-6", providerID: "opencode" },
  time: { created: 1700000001000, completed: 1700000002000 },
  cost: 0,
  tokens: { input: 10, output: 10, reasoning: 0, cache: { read: 0, write: 0 } },
  finish: "stop",
  content: [
    {
      type: "text",
      text: "[Report](docs/report.md) and [HTML demo](demo.html). Inline `data.csv`.\n\n![Timeline chart](chart.svg)",
    },
    {
      type: "tool",
      id: "call_read_chart",
      name: "read",
      time: { created: 1700000001000, ran: 1700000001000, completed: 1700000002000 },
      state: {
        status: "completed",
        input: { path: "read-chart.svg" },
        content: [{ type: "text", text: "Image read" }],
        metadata: {},
      },
    },
  ],
}

for (const viewport of [
  { width: 1440, height: 900 },
  { width: 390, height: 844 },
]) {
  test.describe(`artifact tabs at ${viewport.width}px`, () => {
    test.use({ viewport, hasTouch: viewport.width === 390 })
    test("opens rich references and previews timeline images", async ({ page }, testInfo) => {
      await mockOpenCodeServer(page, {
        ...fixture,
        sessions: fixture.sessions,
        pageMessages: () => ({ items: [message] }),
        fileList: () => [],
        fileContent: (path) =>
          path.endsWith(".svg")
            ? svg
            : path === "docs/report.md"
              ? "# Artifact report\n\n[Data](../data.csv)"
              : path === "data.csv"
                ? "Name,Count\nApples,3"
                : "<h1>Browser HTML preview</h1>",
      })
      await page.goto(`/server/${base64Encode(fixture.serverKey)}/session/${fixture.targetID}`)
      const chart = page.getByRole("button", { name: "Timeline chart", exact: true })
      await expect(chart).toHaveJSProperty("naturalWidth", 120)
      await chart.click()
      const preview = page.locator('[data-component="image-preview"]')
      await expect(preview.getByRole("img", { name: "Timeline chart" })).toBeVisible()
      await preview.getByRole("button", { name: "Close", exact: true }).click()
      await expect(preview).toHaveCount(0)
      await chart.focus()
      await page.keyboard.press("Enter")
      await expect(preview).toBeVisible()
      await page.keyboard.press("Escape")
      await expect(preview).toHaveCount(0)

      await page.getByRole("button", { name: "Used 1 Read", exact: true }).click()
      await page.getByRole("button", { name: "Read read-chart.svg", exact: true }).click()
      const readImage = page.getByRole("button", { name: "read-chart.svg", exact: true })
      await expect(readImage).toHaveJSProperty("naturalWidth", 120)
      await readImage.click()
      await expect(preview.getByRole("img", { name: "read-chart.svg" })).toBeVisible()
      await preview.getByRole("button", { name: "Close", exact: true }).click()
      await expect(preview).toHaveCount(0)

      const inline = page.getByRole("link", { name: "data.csv", exact: true })
      await inline.focus()
      await page.keyboard.press("Enter")
      await expect(page.getByRole("cell", { name: "Apples" })).toBeVisible()
      if (viewport.width === 390) await page.getByRole("tab", { name: "Session", exact: true }).click()

      await page.getByRole("link", { name: "Report", exact: true }).click()
      const artifact = page.locator('[data-component="artifact-view"]')
      await expect(artifact.getByRole("heading", { name: "Artifact report" })).toBeVisible()
      await artifact.getByRole("button", { name: "Source", exact: true }).click()
      await expect(artifact.getByRole("button", { name: "Source", exact: true })).toHaveAttribute(
        "aria-pressed",
        "true",
      )
      await artifact.getByRole("button", { name: "Preview", exact: true }).click()
      await artifact.getByRole("link", { name: "Data", exact: true }).click()
      await expect(artifact.getByRole("cell", { name: "Apples" })).toBeVisible()
      await expect(artifact.getByRole("cell", { name: "3", exact: true })).toBeVisible()
      await expect(page.getByRole("tab", { name: /data.csv/ })).toBeVisible()
      await page.screenshot({ path: testInfo.outputPath(`artifact-table-${viewport.width}.png`) })
      if (viewport.width === 390) {
        const files = page.locator('[data-slot="session-mobile-files"]')
        await files
          .locator('[data-slot$="trigger-wrapper"]')
          .filter({ has: page.getByRole("tab", { name: /data.csv/ }) })
          .getByRole("button", { name: "Close tab" })
          .tap()
        await expect(artifact.getByRole("heading", { name: "Artifact report" })).toBeVisible()
        await page.getByRole("tab", { name: "Session", exact: true }).click()
      }
      await page.getByRole("link", { name: "HTML demo", exact: true }).click()
      await expect(
        page.frameLocator('iframe[title="demo.html"]').getByRole("heading", { name: "Browser HTML preview" }),
      ).toBeVisible()
      await expect(page.locator('iframe[title="demo.html"]')).toHaveAttribute(
        "sandbox",
        "allow-scripts allow-popups allow-forms allow-modals",
      )
      await page.screenshot({ path: testInfo.outputPath(`artifact-html-${viewport.width}.png`) })
      await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    })
  })
}
