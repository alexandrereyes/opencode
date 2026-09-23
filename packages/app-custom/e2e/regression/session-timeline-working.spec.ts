import { expect, test, type Page } from "@playwright/test"
import { timelinePresets } from "@opencode/session-ui-custom/timeline/detail"
import {
  assistantID,
  assistantMessage,
  directory,
  partUpdated,
  reasoningPart,
  sessionID,
  setupTimeline,
  status,
  stepStarted,
  toolPart,
  userMessage,
} from "../performance/timeline-stability/fixture"

// The model name comes from the fixture catalog, so assertions match the activity phrase.
const activityLabel = (page: Page) => page.locator('[data-component="session-working"] [data-component="text-shimmer"]')

for (const width of [1400, 390]) {
  test(`shows the assistant status through busy, reasoning, and idle states at ${width}px`, async ({
    page,
  }, testInfo) => {
    const timeline = await setupTimeline(page, {
      messages: [userMessage()],
      sessionStatus: { [sessionID]: { type: "busy" } },
      viewport: { width, height: 900 },
      settings: {
        timelineDetail: { ...timelinePresets[2].value, thinking: { placement: "separate", details: "collapsed" } },
      },
    })
    const working = page.locator('[data-component="session-working"]')
    await expect(working).toHaveCount(1)
    await expect(working).toHaveRole("status")
    await expect(activityLabel(page)).toHaveAttribute("aria-label", /^\S.* is \S/)
    await expect(working.locator('[data-component="provider-icon"]')).toBeVisible()
    await expect(working).toBeInViewport()
    await expect(activityLabel(page)).toHaveAttribute("data-active", "true")
    await expect(activityLabel(page)).toHaveCSS("line-height", "16px")
    await expect(page.locator('[data-timeline-row="Thinking"]')).toHaveCount(0)
    await page.screenshot({ path: testInfo.outputPath(`working-${width}.png`) })

    await timeline.send(stepStarted(assistantMessage([], { completed: false })))
    await expect(working).toBeVisible()
    const id = `prt_working_reasoning_${width}`
    await timeline.send(partUpdated(reasoningPart(id, "")))
    await expect(page.locator('[data-timeline-row="Thinking"]')).toBeVisible()
    await expect(activityLabel(page)).toHaveAttribute("aria-label", / is thinking$/)
    await expect(working).toBeInViewport()

    // A generic phrase does not replace the last specific status.
    await timeline.send(partUpdated(reasoningPart(id, "The inspection is complete.")))
    await expect(page.locator('[data-timeline-row="Thinking"]')).toHaveCount(0)
    await expect(activityLabel(page)).toHaveAttribute("aria-label", / is thinking$/)
    await expect(working).toBeInViewport()

    await timeline.send(status("idle"))
    await expect(working).toHaveCount(0)
  })
}

const toolPhrases = { shell: "running command", patch: "applying patch", subagent: "delegating task" } as const

for (const name of ["shell", "patch", "subagent"] as const) {
  test(`names ${name} in the assistant status during input and execution`, async ({ page }) => {
    const timeline = await setupTimeline(page, {
      messages: [userMessage(), assistantMessage([], { completed: false })],
      settings: {
        timelineDetail: { ...timelinePresets[0].value, shell: { placement: "separate", details: "collapsed" } },
      },
    })
    const working = page.locator('[data-component="session-working"]')
    const phrase = new RegExp(` is ${toolPhrases[name]}$`)
    await expect(working).toBeVisible()

    const id = `prt_working_${name}`
    const input =
      name === "shell"
        ? { command: "printf ready" }
        : name === "patch"
          ? { patchText: "*** Begin Patch\n*** Add File: src/working.ts\n+export const ready = true\n*** End Patch" }
          : { agent: "general", description: "Inspect working indicator", prompt: "Inspect the timeline." }
    await timeline.send(partUpdated(toolPart(id, name, "streaming", input)))
    const tool = page.locator(`[data-timeline-part-id="${id}"]`)
    await expect(tool).toBeVisible()
    await expect(activityLabel(page)).toHaveAttribute("aria-label", phrase)

    const metadata =
      name === "patch"
        ? {
            files: [
              {
                file: "src/working.ts",
                status: "added",
                additions: 1,
                deletions: 0,
                patch: "@@ -0,0 +1 @@\n+export const ready = true",
              },
            ],
          }
        : {}
    await timeline.send(partUpdated(toolPart(id, name, "running", input, { metadata })))
    await expect(tool).toContainText(
      name === "shell" ? "printf ready" : name === "patch" ? "working.ts" : "Inspect working indicator",
    )
    await expect(activityLabel(page)).toHaveAttribute("aria-label", phrase)

    await timeline.send(partUpdated(toolPart(id, name, "completed", input, { metadata })))
    await expect(tool).toBeVisible()
    await expect(page.locator('[data-component="collapsed-tool-group"]')).toHaveCount(0)
    await expect(working).toBeVisible()
    await expect(activityLabel(page)).toHaveAttribute("aria-label", phrase)
    await expect(activityLabel(page)).toHaveAttribute("data-active", "true")
  })
}

test("names the tool a running Code Mode script is calling", async ({ page }) => {
  const timeline = await setupTimeline(page, {
    messages: [userMessage(), assistantMessage([], { completed: false })],
  })
  await expect(page.locator('[data-component="session-working"]')).toBeVisible()
  const input = { code: "await tools.browser.tabs.open({})" }
  const toolCalls = [
    { tool: "read", status: "completed" },
    { tool: "browser.tabs.open", status: "running" },
  ]
  await timeline.send(partUpdated(toolPart("prt_working_execute", "execute", "running", input)))
  await expect(activityLabel(page)).toHaveAttribute("aria-label", / is running a script$/)

  await timeline.send(
    partUpdated(toolPart("prt_working_execute", "execute", "running", input, { metadata: { toolCalls } })),
  )
  await expect(activityLabel(page)).toHaveAttribute("aria-label", / is calling browser\.tabs\.open$/)
})

for (const name of ["read", "shell", "subagent"] as const) {
  test(`keeps Working for grouped ${name} regardless of disclosure`, async ({ page }, testInfo) => {
    await setupTimeline(page, {
      viewport: { width: name === "shell" ? 390 : 1400, height: 900 },
      messages: [
        userMessage(),
        assistantMessage(
          [
            toolPart("prt_grouped_previous", "read", "completed", { filePath: "package.json" }),
            toolPart(
              "prt_grouped_active",
              name,
              "running",
              name === "shell"
                ? { command: "sleep 10" }
                : name === "subagent"
                  ? { agent: "general", description: "Inspect the timeline", prompt: "Inspect it." }
                  : { filePath: "src/working.ts" },
            ),
          ],
          { completed: false },
        ),
      ],
    })
    const working = page.locator('[data-component="session-working"]')
    const group = page.locator('[data-component="collapsed-tool-group"]')
    const trigger = group.locator(':scope > [data-component="collapsible"] > [data-slot="collapsible-trigger"]')
    await expect(group).toHaveAttribute("data-timeline-part-ids", "prt_grouped_previous,prt_grouped_active")
    await expect(trigger).toHaveAttribute("aria-expanded", "false")
    await expect(working).toBeInViewport()
    if (name !== "read") {
      const hint = page.getByRole("button", { name: /move running work to the background/i })
      await expect(hint).toBeInViewport()
      await expect(page.locator('[data-component="session-background-hint-row"]')).toHaveCSS("height", "24px")
      await page.screenshot({ path: testInfo.outputPath(`working-grouped-${name}.png`) })
    }
    await trigger.click()
    await expect(trigger).toHaveAttribute("aria-expanded", "true")
    if (name === "subagent") await expect(group.getByText("Inspect the timeline", { exact: true })).toBeVisible()
    if (name !== "subagent")
      await expect(group.locator('[data-component="text-shimmer"][data-active="true"]')).toBeVisible()
    await expect(working).toBeVisible()
    await trigger.click()
    await expect(trigger).toHaveAttribute("aria-expanded", "false")
    await expect(working).toBeVisible()
  })
}

for (const grouped of [false, true]) {
  test(`uses ${grouped ? "grouped" : "standalone"} background shell presentation for Working`, async ({ page }) => {
    const timeline = await setupTimeline(page, {
      settings: {
        timelineDetail: {
          ...timelinePresets[2].value,
          shell: { placement: grouped ? "grouped" : "separate", details: grouped ? "collapsed" : "expanded" },
        },
      },
      messages: [
        userMessage(),
        assistantMessage(
          [
            toolPart("prt_background_previous", "shell", "completed", { command: "echo ready" }),
            toolPart(
              "prt_background_active",
              "shell",
              "completed",
              { command: "sleep 10" },
              {
                metadata: { shellID: "sh_working_background", status: "running" },
              },
            ),
          ],
          { completed: false },
        ),
      ],
    })
    await timeline.transport.send({
      id: `evt_working_background_${grouped}`,
      created: 3,
      type: "shell.created",
      location: { directory },
      data: {
        info: {
          id: "sh_working_background",
          status: "running",
          command: "sleep 10",
          cwd: directory,
          shell: "bash",
          file: "/tmp/working-background.out",
          metadata: { sessionID },
          time: { started: 2 },
        },
      },
    })
    const working = page.locator('[data-component="session-working"]')
    const group = page.locator('[data-component="collapsed-tool-group"]')
    if (!grouped) {
      await expect(page.locator('[data-timeline-part-id="prt_background_active"]')).toBeVisible()
      await expect(working).toBeVisible()
      return
    }
    const trigger = group.getByRole("button", { name: "Used 2 Shell", exact: true, includeHidden: true })
    await expect(trigger).toHaveAttribute("aria-expanded", "false")
    await expect(working).toBeVisible()
    await trigger.click()
    await expect(trigger).toHaveAttribute("aria-expanded", "true")
    await expect(working).toBeVisible()
  })
}

test("replaces Working with Retry and restores it on recovery", async ({ page }) => {
  const assistant = assistantMessage([], { completed: false })
  const timeline = await setupTimeline(page, { messages: [userMessage(), assistant] })
  const working = page.locator('[data-component="session-working"]')
  await expect(working).toBeVisible()

  await timeline.send(status("retry"))
  const retry = page.locator('[data-timeline-row="Retry"]')
  await expect(retry).toContainText("Rate limited")
  await expect(working).toHaveCount(0)

  await timeline.send(stepStarted(assistant))
  await expect(retry).toHaveCount(0)
  await expect(page.locator('[data-timeline-row="Thinking"]')).toHaveCount(0)
  await expect(activityLabel(page)).toHaveAttribute("aria-label", /^\S.* is \S/)
  await expect(working).toBeVisible()
})

test("reports composing while assistant text streams", async ({ page }) => {
  const timeline = await setupTimeline(page, {
    messages: [userMessage(), assistantMessage([], { completed: false })],
  })
  const working = page.locator('[data-component="session-working"]')
  await expect(working).toBeVisible()

  await timeline.send({
    id: "evt_working_text_started",
    type: "session.text.started",
    created: 1700000002000,
    location: { directory },
    durable: { aggregateID: sessionID, seq: 0, version: 1 },
    data: { sessionID, assistantMessageID: assistantID, ordinal: 0 },
  })
  await timeline.send({
    id: "evt_working_text_delta",
    type: "session.text.delta",
    created: 1700000002001,
    location: { directory },
    data: { sessionID, assistantMessageID: assistantID, ordinal: 0, delta: "The response is streaming." },
  })
  await expect(page.locator(`[data-timeline-part-id="${assistantID}:text:0"]`)).toContainText(
    "The response is streaming.",
  )
  await expect(working).toBeVisible()
  await expect(activityLabel(page)).toHaveAttribute("aria-label", / is composing$/)
})

for (const failed of [false, true]) {
  test(`shows Working before prompt admission or execution events${failed ? " after an error" : ""}`, async ({
    page,
  }) => {
    await setupTimeline(page, {
      messages: [
        userMessage(),
        ...(failed
          ? [{ ...assistantMessage([]), error: { type: "provider.error", message: "Previous request failed" } }]
          : []),
      ],
    })
    const working = page.locator('[data-component="session-working"]')
    await expect(working).toHaveCount(0)

    const release = Promise.withResolvers<void>()
    await page.route(`**/api/session/${sessionID}/prompt`, async (route) => {
      if (route.request().method() !== "POST") return route.fallback()
      await release.promise
      return route.fallback()
    })
    const editor = page.locator('[data-component="composer"]').getByRole("textbox")
    await expect(editor).toBeEditable()
    await editor.fill("Check the working indicator immediately.")
    await expect(page.locator('[data-action="composer-submit"]')).toBeEnabled()
    const requested = page.waitForRequest(
      (request) =>
        request.method() === "POST" && new URL(request.url()).pathname === `/api/session/${sessionID}/prompt`,
    )
    try {
      await editor.press("Enter")
      const request = await requested
      expect(request.postDataJSON()).toMatchObject({ text: "Check the working indicator immediately." })
      await expect(working).toHaveRole("status")
      await expect(activityLabel(page)).toHaveAttribute("aria-label", /^\S.* is \S/)
      await expect(working).toBeInViewport()
      await expect(page.locator('[data-timeline-row="Thinking"]')).toHaveCount(0)
    } finally {
      release.resolve()
    }
  })
}
