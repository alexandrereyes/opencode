import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"

const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const directory = "/repo/github-mark"
const sessionID = "ses_github_mark_123456789"

test.use({ serviceWorkers: "block" })

for (const [width, height] of [
  [1440, 900],
  [390, 844],
]) {
  test(`shows a local GitHub mark only on GitHub links at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    const external: string[] = []
    page.on("request", (request) => {
      if (!["127.0.0.1", "localhost"].includes(new URL(request.url()).hostname)) external.push(request.url())
    })
    await mockOpenCodeServer(page, {
      directory,
      project: {
        id: "proj_github_mark",
        worktree: directory,
        vcs: "git",
        name: "github-mark",
        time: { created: 1, updated: 1 },
        sandboxes: [],
      },
      provider: { all: [], connected: [], default: {} },
      sessions: [
        { id: sessionID, projectID: "proj_github_mark", directory, title: "Links", time: { created: 1, updated: 1 } },
      ],
      pageMessages: () => ({
        items: [
          { id: "msg_user_1", type: "user", time: { created: 1 }, text: "links please" },
          {
            id: "msg_assistant_1",
            type: "assistant",
            time: { created: 2, completed: 3 },
            model: { id: "model", providerID: "provider" },
            agent: "build",
            cost: 0,
            tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
            finish: "stop",
            content: [
              {
                type: "text",
                text: [
                  "[#540](https://github.com/anomalyco/opencode/pull/540)",
                  "[other site](https://example.com/docs)",
                  "[lookalike](https://github.com.evil.example/pull/540)",
                  "`src/app.ts`",
                ].join(" · "),
              },
            ],
          },
        ],
      }),
      subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
    })
    await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)

    const markdown = page.locator('[data-component="markdown"][data-markdown-ready]').filter({ hasText: "#540" })
    const github = markdown.getByRole("link", { name: "#540", exact: true })
    await expect(github).toHaveText("#540")
    expect(await github.evaluate((link) => getComputedStyle(link, "::before").width)).toBe("14px")
    for (const name of ["other site", "lookalike"])
      expect(
        await markdown
          .getByRole("link", { name, exact: true })
          .evaluate((link) => getComputedStyle(link, "::before").content),
      ).toBe("none")
    await expect(markdown.locator("img")).toHaveCount(0)
    await expect(markdown.locator('[role="button"]')).toHaveCount(0)
    expect(external).toEqual([])
  })
}
