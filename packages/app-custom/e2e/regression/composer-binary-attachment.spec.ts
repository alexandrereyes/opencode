import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"

const directory = "/repo/binary-attachment"
const sessionID = "ses_binary_attachment_123456789"
const bytes = Buffer.from([0, 1, 2, 3, 255])
const remotePath = "/tmp/opencode/uploads/test/archive.zip"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test.use({ serviceWorkers: "block" })

test("uploads a generic binary and renders its sent path reference", async ({ page }) => {
  const prompts: Record<string, unknown>[] = []
  const uploads: { bytes: Buffer; path: string | null }[] = []
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: "proj_binary_attachment",
      worktree: directory,
      vcs: "git",
      name: "binary-attachment",
      time: { created: 1, updated: 1 },
      sandboxes: [],
    },
    provider: {
      all: [{ id: "opencode", name: "OpenCode", models: { test: { id: "test", name: "Test" } } }],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: "test" },
    },
    sessions: [
      {
        id: sessionID,
        projectID: "proj_binary_attachment",
        directory,
        title: "Binary attachment",
        time: { created: 1, updated: 1 },
      },
    ],
    pageMessages: () => ({ items: [] }),
    findFiles: () => [],
    onPrompt: ({ body }) => prompts.push(body),
  })
  await page.route("**/api/info", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ version: "test", pid: 1, urls: [server], paths: { tmp: "/tmp/opencode" } }),
    }),
  )
  await page.route("**/api/experimental/fs/write?*", async (route) => {
    uploads.push({
      bytes: route.request().postDataBuffer() ?? Buffer.alloc(0),
      path: new URL(route.request().url()).searchParams.get("path"),
    })
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        location: { directory, project: { id: "proj_binary_attachment", directory, canonical: directory } },
        data: { path: remotePath },
      }),
    })
  })

  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
  await expect(editor).toBeEditable()
  await page.locator('.composer-main input[type="file"]').setInputFiles({
    name: "archive.zip",
    mimeType: "application/zip",
    buffer: bytes,
  })
  await expect(page.getByText("archive.zip", { exact: true })).toBeVisible()

  await editor.press("Enter")

  await expect.poll(() => uploads.map((value) => [...value.bytes])).toEqual([[...bytes]])
  expect(uploads[0]?.path).toMatch(/^\/tmp\/opencode\/uploads\/[0-9a-f-]+\/archive\.zip$/)
  await expect.poll(() => prompts).toHaveLength(1)
  expect(prompts[0]).toMatchObject({
    text: `Attached file: \`${remotePath}\``,
    files: [],
    metadata: {
      displayText: "",
      attachments: [{ name: "archive.zip", mime: "application/zip", path: remotePath }],
    },
  })
  const sent = page.locator('[data-timeline-row="UserMessage"]').filter({ hasText: "archive.zip" })
  await expect(sent).toHaveCount(1)
  await expect(sent.getByText("archive.zip", { exact: true })).toBeVisible()
  await expect(sent.getByTitle(remotePath)).toBeVisible()
})
