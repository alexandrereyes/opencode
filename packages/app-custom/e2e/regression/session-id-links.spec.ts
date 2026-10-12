import { expect, test, type Page } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import type { SessionMessageInfo } from "@opencode/client/promise"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const directory = "C:/OpenCode/SessionLinks"
const projectID = "proj_session_links"
const sourceID = "ses_links_source"
const rootID = "ses_links_root"
// A subagent of another root session: opening it must reuse that root's tab.
const target = "ses_0123456789abcdefghijklmnop"
const missing = "ses_abcdefghijklmnopqrstuvwxyz"
const href = (id: string) => `/server/${base64Encode(server)}/session/${id}`

const session = (id: string, title: string, extra?: Record<string, unknown>) => ({
  id,
  slug: id,
  projectID,
  directory,
  title,
  version: "dev",
  time: { created: 1700000000000, updated: 1700000000000 },
  ...extra,
})

const messages: SessionMessageInfo[] = [
  { id: "msg_links_user", type: "user", time: { created: 1700000000000 }, text: "Where did the review happen?" },
  {
    id: "msg_links_assistant",
    type: "assistant",
    time: { created: 1700000001000, completed: 1700000002000 },
    model: { id: "claude-opus-4-6", providerID: "opencode" },
    agent: "build",
    cost: 0,
    tokens: { input: 1, output: 1, reasoning: 0, cache: { read: 0, write: 0 } },
    finish: "stop",
    content: [{ type: "text", text: `Visit ${target} or \`${target}\`, not ${missing}. See \`src/app.ts\`.` }],
  },
]

async function setup(page: Page) {
  const lookups: string[] = []
  page.on("request", (request) => {
    const url = new URL(request.url())
    if (url.pathname === `/api/session/${missing}`) lookups.push(url.pathname)
  })
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "session-links",
      time: { created: 1, updated: 1 },
      sandboxes: [],
    },
    provider: {
      all: [
        {
          id: "opencode",
          name: "OpenCode",
          models: {
            "claude-opus-4-6": { id: "claude-opus-4-6", name: "Claude Opus 4.6", limit: { context: 200_000 } },
          },
        },
      ],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: "claude-opus-4-6" },
    },
    sessions: [
      session(sourceID, "Links source"),
      session(rootID, "Review root"),
      session(target, "Linked review", { parentID: rootID }),
    ],
    pageMessages: (sessionID) => ({ items: sessionID === sourceID ? messages : [] }),
    tabLayout: "horizontal",
  })
  await page.addInitScript(
    ({ server, sourceID }) =>
      localStorage.setItem(
        "opencode.window.browser.dat:tabs",
        JSON.stringify([{ type: "session", server, sessionId: sourceID }]),
      ),
    { server, sourceID },
  )
  await page.goto(href(sourceID))
  await expectSessionTitle(page, "Links source")
  const markdown = page.locator('[data-component="markdown"]').filter({ hasText: `Visit ${target}` })
  await expect(markdown).toHaveAttribute("data-markdown-ready", "")
  const links = markdown.getByRole("button", { name: target, exact: true })
  await expect(links).toHaveCount(2)
  await expect.poll(() => lookups.length).toBeGreaterThan(0)
  await expect(markdown.locator(`[data-session-id="${missing}"]`)).toHaveCount(0)
  await expect(markdown.getByText(missing, { exact: false })).toBeVisible()
  return { markdown, links }
}

test.describe("desktop", () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test("links only existing sessions and opens a nested one in its root tab with the keyboard", async ({ page }) => {
    const { links } = await setup(page)
    await links.filter({ has: page.locator("code") }).press("Enter")
    await expect(page).toHaveURL(href(target))
    await expect(page.locator('[data-slot="session-title-parent"]')).toHaveText("Review root")
    const tabs = page.locator('[data-slot="titlebar-tabs"] [data-titlebar-tab-slot]')
    await expect(tabs).toHaveCount(2)
    await expect(tabs.locator(`a[href="${href(target)}"]`)).toHaveCount(1)
    await expect(
      tabs.filter({ has: page.locator(`a[href="${href(target)}"]`) }).locator('[data-slot="tab-title"]'),
    ).toHaveText("Review root")
  })
})

test.describe("phone", () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

  test("opens a referenced session by touch", async ({ page }) => {
    const { links } = await setup(page)
    await links.first().tap()
    await expect(page).toHaveURL(href(target))
    await expectSessionTitle(page, "Linked review")
  })
})
