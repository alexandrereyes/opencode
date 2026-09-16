import { expect, test } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"
import { mockOpenCodeServer } from "../utils/mock-server"

const directory = "/repo/current"
const projectID = "proj_session_mentions"
const currentID = "ses_current_12345678901234567890"
const firstID = "ses_reference_one_1234567890123"
const secondID = "ses_reference_two_1234567890123"
const unbrokenID = "ses_long_unbroken_123456789012345"
const multiwordID = "ses_long_multiword_123456789012345"
const childID = "ses_child_12345678901234567890123"
const unbrokenTitle = "A".repeat(180)
const multiwordTitle = "Long session title that must wrap inside the composer without widening the mobile viewport"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

test.use({ permissions: ["clipboard-read", "clipboard-write"] })

test("selects, copies, pastes, and submits a globally searched session reference", async ({ page }) => {
  const prompts: Record<string, unknown>[] = []
  const referencedMessageRequests: string[] = []
  const appMentionRequests: Array<{ url: string; body: unknown }> = []
  let rejectAppMentions = false
  const sessionListParents: Array<string | null> = []
  const sessionListGates = new Map<
    string,
    { started: ReturnType<typeof Promise.withResolvers<void>>; release: ReturnType<typeof Promise.withResolvers<void>> }
  >()
  page.on("request", (request) => {
    if (request.url().includes("/api/rpc/custom.app-mentions/list")) {
      appMentionRequests.push({ url: request.url(), body: request.postDataJSON() })
    }
    if (
      request.url().includes(`/api/session/${firstID}/message`) ||
      request.url().includes(`/api/session/${secondID}/message`)
    )
      referencedMessageRequests.push(request.url())
  })
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "session-mentions",
      time: { created: 1700000000000, updated: 1700000000000 },
      sandboxes: [],
    },
    provider: {
      all: [{ id: "opencode", name: "OpenCode", models: { test: { id: "test", name: "Test" } } }],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: "test" },
    },
    sessions: [
      { id: currentID, projectID, directory, title: "Current", time: { created: 4, updated: 4 } },
      { id: firstID, projectID, directory: "/repo/one", title: "Shared work", time: { created: 1, updated: 1 } },
      { id: secondID, projectID, directory: "/repo/two", title: "Shared work", time: { created: 2, updated: 2 } },
      { id: unbrokenID, projectID, directory: "/repo/long", title: unbrokenTitle, time: { created: 5, updated: 5 } },
      { id: multiwordID, projectID, directory: "/repo/long", title: multiwordTitle, time: { created: 6, updated: 6 } },
      {
        id: childID,
        parentID: firstID,
        projectID,
        directory: "/repo/child",
        title: "Shared child",
        time: { created: 7, updated: 7 },
      },
      {
        id: "ses_archived_12345678901234567890",
        projectID,
        directory: "/repo/archived",
        title: "Archived work",
        time: { created: 3, updated: 3, archived: 4 },
      },
    ],
    appMentions: [
      {
        server: "open-computer-use",
        name: "Shared work",
        bundleID: "com.example.shared-work",
        running: true,
      },
      {
        server: "safari-devtools",
        name: "Safari DevTools",
        bundleID: "mcp.safari-devtools",
        running: false,
      },
    ],
    pageMessages: () => ({ items: [] }),
    findFiles: () => [],
    onPrompt: ({ body }) => prompts.push(body),
  })
  await page.route("**/api/rpc/custom.app-mentions/list?*", (route) => {
    if (!rejectAppMentions) return route.fallback()
    return route.fulfill({ status: 404, contentType: "application/json", body: JSON.stringify({ message: "missing" }) })
  })
  await page.route("**/api/session?*", async (route) => {
    const url = new URL(route.request().url())
    if (url.searchParams.has("directory") || url.searchParams.has("project")) return route.fallback()
    const parentID = url.searchParams.get("parentID")
    if (parentID && parentID !== "null") return route.fallback()
    sessionListParents.push(parentID)
    const gate = sessionListGates.get(url.searchParams.get("search") ?? "")
    if (!gate) return route.fallback()
    gate.started.resolve()
    await gate.release.promise
    await route.fallback()
  })
  await page.goto(`/server/${base64Encode(server)}/session/${currentID}`)
  const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
  await expect(editor).toBeEditable()
  const originalEditor = await editor.elementHandle()

  const expectComposerStable = async () => {
    await expect(editor).toBeVisible()
    await expect(editor).toBeFocused()
    expect(await editor.evaluate((element, original) => element === original, originalEditor)).toBe(true)
    expect(
      await editor.evaluate((element) => {
        for (let current: Element | null = element; current; current = current.parentElement) {
          const style = getComputedStyle(current)
          if (style.display === "none" || style.visibility === "hidden") return false
        }
        return true
      }),
    ).toBe(true)
  }

  const recent = { started: Promise.withResolvers<void>(), release: Promise.withResolvers<void>() }
  sessionListGates.set("", recent)
  await editor.fill("@")
  await recent.started.promise
  await expectComposerStable()
  recent.release.resolve()
  await expect(page.getByRole("button", { name: `Session, Shared work, /repo/two, ${secondID}` })).toBeVisible()
  await expect(page.getByRole("button", { name: `Session, Shared work, /repo/one, ${firstID}` })).toBeVisible()
  await expect(page.locator('[data-suggestion-id="app:open-computer-use:com.example.shared-work"]')).toContainText(
    "Shared work",
  )
  const safariDevTools = page.locator('[data-suggestion-id="app:safari-devtools:mcp.safari-devtools"]')
  await expect(safariDevTools).toContainText("Safari DevTools")
  await expect(safariDevTools).toContainText("Safari MCP")
  expect(appMentionRequests).toHaveLength(1)
  expect(new URL(appMentionRequests[0].url).searchParams.get("location[directory]")).toBe(directory)
  expect(appMentionRequests[0].body).toEqual({ input: {} })
  await expect(page.getByText("Archived work", { exact: true })).toHaveCount(0)
  await expect(page.locator(`[data-suggestion-id="session:${server}:${childID}"]`)).toHaveCount(0)
  expect(sessionListParents).toEqual(["null"])

  const filtered = { started: Promise.withResolvers<void>(), release: Promise.withResolvers<void>() }
  sessionListGates.set("Shared", filtered)
  await editor.fill("@Shared")
  await filtered.started.promise
  await expectComposerStable()
  expect(appMentionRequests).toHaveLength(1)
  filtered.release.resolve()
  await page.getByRole("button", { name: `Session, Shared work, /repo/two, ${secondID}` }).click()
  expect(sessionListParents).toEqual(["null", "null"])
  const chip = editor.locator(`[data-mention="session"][data-id="${secondID}"]`)
  await expect(chip).toHaveText("@Shared work")
  await expect(chip).toHaveAttribute("data-label", "Session")

  await editor.press("ControlOrMeta+A")
  await editor.press("ControlOrMeta+C")
  await editor.fill("replace")
  await editor.press("ControlOrMeta+A")
  await editor.press("ControlOrMeta+V")
  await expect(editor.locator(`[data-mention="session"][data-id="${secondID}"]`)).toHaveCount(1)

  await editor.press("End")
  await editor.pressSequentially("@Shared")
  const appSuggestion = page.locator('[data-suggestion-id="app:open-computer-use:com.example.shared-work"]')
  await expect(appSuggestion).toBeVisible()
  expect(appMentionRequests).toHaveLength(2)
  await appSuggestion.click()
  await expect(editor.locator(`[data-mention="session"][data-id="${secondID}"]`)).toHaveCount(1)
  await expect(editor.locator('[data-mention="app"]')).toHaveText("@Shared work")

  await editor.press("Enter")
  await expect.poll(() => prompts.length).toBe(1)
  expect(prompts[0]).toMatchObject({
    metadata: {
      displayText: "@Shared work @Shared work ",
      sessions: [{ session: { id: secondID, server, title: "Shared work", directory: "/repo/two" } }],
      apps: [{ app: { server: "open-computer-use", bundleID: "com.example.shared-work" } }],
    },
  })
  expect(String(prompts[0]?.text)).toContain(`"sessionID":"${secondID}"`)
  expect(String(prompts[0]?.text)).toContain("tools.opencode.session_read")
  expect(String(prompts[0]?.text)).toContain("Computer use app selected by the user")
  expect(referencedMessageRequests).toEqual([])
  const sent = page.locator('[data-slot="user-message-text"]')
  await expect(sent).toContainText("@Shared work")
  await expect(sent.locator('[data-highlight="session"]')).toHaveText("@Shared work")

  rejectAppMentions = true
  await editor.fill("@")
  await expect(page.getByRole("button", { name: `Session, Shared work, /repo/two, ${secondID}` })).toBeVisible()
  await expect(page.locator('[data-suggestion-id="app:open-computer-use:com.example.shared-work"]')).toHaveCount(0)
  expect(appMentionRequests).toHaveLength(3)

  // Keep suggestions open across both layout breakpoints: their positioning
  // lifecycle must follow the rendered popup when it enters or leaves a Portal.
  for (const width of [390, 1280]) {
    await page.setViewportSize({ width, height: 844 })
    await expect(editor).toHaveText("@")
    await expect
      .poll(() =>
        editor.evaluate((element) => {
          const anchor = element.closest('[data-component="composer"]')!.getBoundingClientRect()
          const popup = document.querySelector('[data-component="composer-suggestions"]')!.getBoundingClientRect()
          return {
            fits: popup.height > 0 && popup.top >= 0 && popup.left >= 0 && popup.right <= innerWidth,
            gap: Math.round(anchor.top - popup.bottom),
          }
        }),
      )
      .toEqual({ fits: true, gap: 8 })
  }
  await page.getByRole("button", { name: `Session, Shared work, /repo/two, ${secondID}` }).click()
  await expect(editor.locator(`[data-mention="session"][data-id="${secondID}"]`)).toHaveText("@Shared work")

  await page.setViewportSize({ width: 390, height: 844 })
  await editor.fill("")
  await expect(page.locator('[data-component="composer-suggestions"]')).toHaveCount(0)
  await expect
    .poll(() => editor.evaluate((element) => element.getBoundingClientRect().top > innerHeight - 200))
    .toBe(true)
  // Model WebKit's panned client rects with the keyboard open, retaining the
  // layout origin for fixed CSS coordinates (the same boundary as quote comments).
  await editor.evaluate((element) => {
    const original = Element.prototype.getBoundingClientRect
    const anchor = element.closest('[data-component="composer"]')!.getBoundingClientRect()
    const offset = Math.max(1, anchor.top - 180)
    Object.defineProperties(window.visualViewport, {
      offsetTop: { configurable: true, value: offset },
      height: { configurable: true, value: innerHeight - offset },
    })
    Element.prototype.getBoundingClientRect = function () {
      const rect = original.call(this)
      return new DOMRect(rect.x, rect.y - offset, rect.width, rect.height)
    }
    window.addEventListener(
      "restore-client-rects",
      () => {
        Element.prototype.getBoundingClientRect = original
      },
      { once: true },
    )
  })
  await editor.fill("@")
  const suggestions = page.locator('[data-component="composer-suggestions"]')
  await expect(suggestions).toBeVisible()
  await page.evaluate(() => window.visualViewport?.dispatchEvent(new Event("resize")))
  await expect
    .poll(() =>
      suggestions.evaluate((element) => {
        const bounds = element.getBoundingClientRect()
        return bounds.top >= 8 && bounds.bottom <= window.visualViewport!.height
      }),
    )
    .toBe(true)
  await expect
    .poll(() =>
      suggestions.evaluate((element) => {
        const viewport = window.visualViewport!
        const popup = element.getBoundingClientRect()
        return Array.from(element.querySelectorAll("[data-suggestion-id]")).filter((item) => {
          const bounds = item.getBoundingClientRect()
          return (
            bounds.top >= Math.max(0, popup.top) &&
            bounds.bottom <= Math.min(viewport.height, popup.bottom) &&
            bounds.left >= popup.left &&
            bounds.right <= popup.right
          )
        }).length
      }),
    )
    .toBeGreaterThanOrEqual(3)
  await expect
    .poll(() =>
      editor.evaluate((element) => {
        const anchor = element.closest('[data-component="composer"]')!.getBoundingClientRect()
        const popup = document.querySelector('[data-component="composer-suggestions"]')!.getBoundingClientRect()
        return anchor.top - popup.bottom
      }),
    )
    .toBeCloseTo(8, 0)
  await expect(suggestions).toHaveCSS("overflow-y", "auto")
  await expect.poll(() => suggestions.evaluate((element) => element.scrollHeight > element.clientHeight)).toBe(true)
  const olderSession = suggestions.getByRole("button", { name: `Session, Shared work, /repo/one, ${firstID}` })
  await olderSession.scrollIntoViewIfNeeded()
  await olderSession.click()
  await expect(editor.locator(`[data-mention="session"][data-id="${firstID}"]`)).toHaveText("@Shared work")
  await page.evaluate(() => {
    window.dispatchEvent(new Event("restore-client-rects"))
    Reflect.deleteProperty(window.visualViewport!, "offsetTop")
    Reflect.deleteProperty(window.visualViewport!, "height")
    window.visualViewport?.dispatchEvent(new Event("resize"))
  })
  for (const value of [
    { query: "@AAAA", id: unbrokenID },
    { query: "@Long", id: multiwordID },
  ]) {
    await editor.fill(value.query)
    await page.locator(`[data-suggestion-id="session:${server}:${value.id}"]`).click()
    const longChip = editor.locator(`[data-mention="session"][data-id="${value.id}"]`)
    await expect(longChip).toBeVisible()
    await expect
      .poll(() =>
        editor.evaluate((element) => {
          const chip = element.querySelector<HTMLElement>('[data-mention="session"]')
          const editorBounds = element.getBoundingClientRect()
          const chipBounds = chip?.getBoundingClientRect()
          return {
            editorFits: element.scrollWidth <= element.clientWidth + 1,
            chipFits:
              !!chipBounds && chipBounds.left >= editorBounds.left - 1 && chipBounds.right <= editorBounds.right + 1,
          }
        }),
      )
      .toEqual({ editorFits: true, chipFits: true })
  }
})
