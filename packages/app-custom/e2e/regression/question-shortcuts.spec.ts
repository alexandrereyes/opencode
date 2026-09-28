import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"

const server = `http://127.0.0.1:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4999"}`
const sessionID = "ses_question_shortcuts"
const session = {
  id: sessionID,
  projectID: "project-questions",
  directory: "/projects/questions",
  title: "Question shortcuts",
  version: "dev",
  time: { created: 1, updated: 1 },
}

for (const viewport of [
  { width: 1440, height: 900 },
  { width: 390, height: 844 },
]) {
  test(`question back and submit shortcuts at ${viewport.width}`, async ({ page }) => {
    await page.setViewportSize(viewport)
    const form = {
      id: "frm_shortcuts",
      sessionID,
      title: "Questions",
      metadata: { kind: "question" },
      fields: [
        {
          key: "first",
          type: "string",
          title: "First",
          description: "First choice?",
          options: [{ value: "yes", label: "Yes" }],
        },
        {
          key: "second",
          type: "string",
          title: "Second",
          description: "Second choice?",
          options: [{ value: "done", label: "Done" }],
        },
      ],
    }
    await mockOpenCodeServer(page, {
      directory: "/projects/questions",
      project: {
        id: "project-questions",
        canonical: "/projects/questions",
        name: "Questions",
        vcs: "git",
        time: { created: 1, updated: 1 },
        sandboxes: [],
      },
      sessions: [session],
      pageMessages: () => ({ items: [] }),
      provider: { all: [], connected: [], default: {} },
      subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
      forms: [form],
    })
    await page.route("**/api/rpc/custom.session-family/snapshot*", async (route) => {
      await route.fulfill({ json: { output: { count: 1, cost: 0, active: [], forms: [form], permissions: [] } } })
    })
    await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
    const dock = page.locator('[data-component="session-question-dock"]')
    await dock.getByRole("radio", { name: "Yes", exact: true }).click()
    await page.keyboard.press("ControlOrMeta+Enter")
    await expect(dock.getByText("Second choice?", { exact: true })).toBeVisible()
    await expect(dock.getByRole("radio", { name: "Done", exact: true })).toBeFocused()
    const mac = await page.evaluate(() => /Mac|iPod|iPhone|iPad/.test(navigator.platform))
    await page.keyboard.press(mac ? "Meta+[" : "Alt+ArrowLeft")
    await expect(dock.getByText("First choice?", { exact: true })).toBeVisible()
    await expect(dock.getByRole("radio", { name: "Yes", exact: true })).toBeChecked()
    await expect(dock.getByRole("radio", { name: "Yes", exact: true })).toBeFocused()
    await page.keyboard.press("ControlOrMeta+Enter")
    await dock.getByRole("radio", { name: "Done", exact: true }).click()
    const reply = page.waitForRequest(
      (request) => request.method() === "POST" && request.url().endsWith(`/form/frm_shortcuts/reply`),
    )
    await page.keyboard.press("ControlOrMeta+Enter")
    expect((await reply).postDataJSON()).toEqual({ answer: { first: "yes", second: "done" } })
  })
}
