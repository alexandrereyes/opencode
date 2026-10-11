import { expect, test, type Page } from "@playwright/test"
import type { JsonValue, OpenCodeEvent, SessionInboxInfo, SessionMessageInfo } from "@opencode/client/promise"
import { base64Encode } from "@opencode/util/encode"
import { Schema } from "effect"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectAppVisible } from "../utils/waits"

const directory = "C:/OpenCode/SessionQueueRegression"
const projectID = "proj_session_queue_regression"
const sessionID = "ses_session_queue_regression"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`

type InboxRow = Extract<SessionInboxInfo, { type: "user" }>
const InboxMetadata = Schema.Record(Schema.String, Schema.Json)

function createQueueMock(seed: (string | InboxRow["payload"])[], messages: SessionMessageInfo[] = []) {
  const rows: InboxRow[] = seed.map((value, index) => ({
    id: `inb_seed_${index + 1}`,
    sessionID,
    time: { created: 1700000000000 + index },
    type: "user",
    payload: typeof value === "string" ? { text: value } : value,
    delivery: "queue",
  }))
  const events: OpenCodeEvent[] = []
  const prompts: Record<string, unknown>[] = []
  const changes: { inboxID: string; action: "cancel" | "steer" | "queue" }[] = []
  const compactions: SessionInboxInfo[] = []
  const log: string[] = []
  let sequence = 0
  const emit = <Type extends OpenCodeEvent["type"]>(
    type: Type,
    data: Extract<OpenCodeEvent, { type: Type }>["data"],
  ) => {
    sequence += 1
    events.push({
      id: `evt_queue_${sequence}`,
      type,
      created: Date.now(),
      durable: { aggregateID: sessionID, seq: sequence, version: type === "session.tool.success" ? 2 : 1 },
      data,
    } as OpenCodeEvent)
  }
  return {
    rows,
    compactions,
    prompts,
    changes,
    log,
    messages,
    emit,
    events: () => events.splice(0),
    onPrompt: (input: { sessionID: string; body: Record<string, unknown> }) => {
      prompts.push(input.body)
      log.push(`prompt:${String(input.body.delivery ?? "steer")}`)
      const metadata = Schema.decodeUnknownOption(InboxMetadata)(input.body.metadata)
      const row: InboxRow = {
        id: typeof input.body.id === "string" ? input.body.id : `inb_mock_${sequence}`,
        sessionID: input.sessionID,
        time: { created: Date.now() },
        type: "user",
        payload: {
          text: typeof input.body.text === "string" ? input.body.text : "",
          ...(metadata._tag === "Some" ? { metadata: metadata.value as Record<string, JsonValue> } : {}),
        },
        delivery: input.body.delivery === "queue" ? "queue" : "steer",
      }
      rows.push(row)
      emit("session.inbox.enqueued", {
        sessionID: input.sessionID,
        inboxID: row.id,
        item: { type: "user", payload: row.payload, delivery: row.delivery },
      })
    },
    onInboxChange: (input: { sessionID: string; inboxID: string; action: "cancel" | "steer" | "queue" }) => {
      changes.push({ inboxID: input.inboxID, action: input.action })
      log.push(`${input.action}:${input.inboxID}`)
      const index = rows.findIndex((row) => row.id === input.inboxID)
      const row = rows[index]
      if (!row) return
      if (input.action === "cancel") {
        rows.splice(index, 1)
        emit("session.inbox.cancelled", { sessionID: input.sessionID, inboxID: input.inboxID })
        return
      }
      rows[index] = { ...row, delivery: input.action }
      emit("session.inbox.delivery.changed", {
        sessionID: input.sessionID,
        inboxID: input.inboxID,
        delivery: input.action,
      })
    },
  }
}

async function openSession(
  page: Page,
  mock: ReturnType<typeof createQueueMock>,
  followUpBehavior?: "queue" | "steer",
  revert?: string,
) {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "session-queue-regression",
      time: { created: 1700000000000, updated: 1700000000000 },
      sandboxes: [],
    },
    provider: {
      all: [
        {
          id: "opencode",
          name: "OpenCode",
          models: { "queue-model": { id: "queue-model", name: "Queue Model", limit: { context: 200_000 } } },
        },
      ],
      connected: ["opencode"],
      default: { providerID: "opencode", modelID: "queue-model" },
    },
    sessions: [
      {
        id: sessionID,
        slug: "session-queue-regression",
        projectID,
        directory,
        title: "Session queue regression",
        version: "dev",
        model: { id: "queue-model", providerID: "opencode" },
        time: { created: 1700000000000, updated: 1700000000000 },
        ...(revert ? { revert: { messageID: revert } } : {}),
      },
    ],
    pageMessages: () => ({ items: mock.messages }),
    sessionStatus: () => ({ [sessionID]: { type: "running" } }),
    inbox: () => [...mock.rows.map((row) => ({ ...row, payload: { ...row.payload } })), ...mock.compactions],
    onPrompt: mock.onPrompt,
    onInboxChange: mock.onInboxChange,
    events: mock.events,
    subscriptions: { status: "unavailable", accounts: [], anthropic: { status: "unavailable", accounts: [] } },
  })
  await page.route("**/api/session/*/inbox/*", async (route) => {
    if (route.request().method() !== "PATCH") return route.fallback()
    const payload = route.request().postDataJSON()
    if (payload?.delivery !== "steer" && payload?.delivery !== "queue") return route.fallback()
    mock.onInboxChange({
      sessionID,
      inboxID: new URL(route.request().url()).pathname.split("/").at(-1) ?? "",
      action: payload.delivery,
    })
    await route.fulfill({ status: 204, headers: { "access-control-allow-origin": "*" } })
  })
  if (followUpBehavior)
    await page.route("**/api/rpc/custom.preferences/get*", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          output: {
            version: 1,
            revision: 0,
            imported: true,
            data: {
              projects: {},
              sidebarOrder: [],
              pinnedSessions: [],
              models: { user: [], variant: {} },
              settings: {
                followUpBehavior,
                autoApprove: false,
                autoSave: true,
                tabLayout: "vertical",
                notifications: { agent: true, permissions: true, errors: false },
              },
            },
          },
        }),
      }),
    )
  await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
  const composer = page.locator('[data-component="composer"]')
  await expectAppVisible(composer)
  return {
    composer,
    input: composer.locator('[data-component="composer-editor"]'),
    rows: page.locator('[data-component="session-queue-row"]'),
  }
}

test("follow-up preference controls Enter while Mod+Enter uses the alternate delivery", async ({ page }) => {
  const mock = createQueueMock([])
  const view = await openSession(page, mock, "queue")

  await view.input.fill("queue this follow-up")
  await expect(view.composer.locator('[data-action="composer-alternate-delivery"]')).toContainText("Steer")
  await view.input.press("Enter")
  await expect(view.rows.getByText("queue this follow-up", { exact: true })).toBeVisible()

  await view.input.fill("steer this correction")
  await view.input.press("ControlOrMeta+Enter")
  await expect.poll(() => mock.prompts.map((prompt) => prompt.delivery)).toEqual(["queue", "steer"])
  await expect(view.input).toHaveText("")
})

test("dragging reorders queued prompts", async ({ page }) => {
  const mock = createQueueMock(["first queued prompt", "second queued prompt", "third queued prompt"])
  const view = await openSession(page, mock)
  await expect(view.rows).toHaveCount(3)

  const first = view.rows.filter({ hasText: "first queued prompt" })
  const third = view.rows.filter({ hasText: "third queued prompt" })
  await first.getByRole("button", { name: "Reorder queued prompt" }).hover()
  await page.mouse.down()
  const target = await third.boundingBox()
  if (!target) throw new Error("The target queue row is not visible")
  await page.mouse.move(target.x + target.width / 2, target.y + target.height / 2, { steps: 10 })
  await page.mouse.up()

  await expect(view.rows.locator('[data-action="session-queue-edit"]')).toHaveText([
    "second queued prompt",
    "third queued prompt",
    "first queued prompt",
  ])
  expect(mock.prompts.map((prompt) => prompt.text)).toEqual([
    "second queued prompt",
    "third queued prompt",
    "first queued prompt",
  ])
  expect(mock.changes).toEqual([
    { inboxID: "inb_seed_1", action: "cancel" },
    { inboxID: "inb_seed_2", action: "cancel" },
    { inboxID: "inb_seed_3", action: "cancel" },
  ])
})

test("editing restores the existing draft and replaces only the original queue position", async ({ page }) => {
  const mock = createQueueMock([
    "first queued prompt",
    {
      text: "tighten the error copy",
      files: [
        {
          data: "cGRm",
          mime: "application/pdf",
          name: "document.pdf",
          source: { type: "inline" },
        },
      ],
    },
    "third queued prompt",
  ])
  const view = await openSession(page, mock)
  const original = view.rows.getByText("tighten the error copy", { exact: true })
  await expect(original).toBeVisible()

  await view.input.fill("my in-progress draft")
  await original.click()
  await expect(view.input).toHaveText("tighten the error copy")
  await expect(view.input).toBeFocused()
  await view.input.press("Escape")
  await expect(view.input).toHaveText("my in-progress draft")

  await original.click()
  await expect(view.input).toHaveText("tighten the error copy")
  await expect(view.input).toBeFocused()
  const attachment = view.composer.locator('div[data-attachment-id="inb_seed_2:file:0"]')
  await expect(attachment).toContainText("document.pdf")
  await attachment.hover()
  await attachment.getByRole("button", { name: "Remove attachment" }).click()
  await expect(attachment).toHaveCount(0)
  await view.input.fill("tighten the error copy and add a retry hint")
  await expect(view.input).toHaveText("tighten the error copy and add a retry hint")
  await view.input.press("Enter")

  await expect(view.rows.locator('[data-action="session-queue-edit"]')).toHaveText([
    "first queued prompt",
    "tighten the error copy and add a retry hint",
    "third queued prompt",
  ])
  await expect(view.input).toHaveText("my in-progress draft")
  // One rewrite from the edited position: the replacement, then the prompts after it.
  expect(mock.prompts.map((prompt) => prompt.text)).toEqual([
    "tighten the error copy and add a retry hint",
    "third queued prompt",
  ])
  expect(mock.prompts[0]?.files).toEqual([])
  expect(mock.prompts.every((prompt) => prompt.delivery === "queue" && prompt.resume === false)).toBe(true)
  expect(mock.changes).toEqual([
    { inboxID: "inb_seed_2", action: "cancel" },
    { inboxID: "inb_seed_3", action: "cancel" },
  ])
  expect(mock.log[0]).toBe("prompt:queue")
})

for (const change of ["reorder", "edit"] as const) {
  test(`a ${change} that cannot re-admit a prompt leaves the queue unchanged`, async ({ page }) => {
    const order = ["first queued prompt", "second queued prompt", "third queued prompt"]
    const mock = createQueueMock(order)
    const admit = mock.onPrompt
    // The last prompt's re-admission fails after the server admitted it, so its response is lost.
    mock.onPrompt = (input) => {
      admit(input)
      if (input.body.text === order[2]) throw new Error("Connection lost after admission")
    }
    const view = await openSession(page, mock)
    await expect(view.rows).toHaveCount(3)

    if (change === "reorder") {
      const first = view.rows.filter({ hasText: order[0] })
      const second = view.rows.filter({ hasText: order[1] })
      await first.getByRole("button", { name: "Reorder queued prompt" }).hover()
      await page.mouse.down()
      const target = await second.boundingBox()
      if (!target) throw new Error("The target queue row is not visible")
      await page.mouse.move(target.x + target.width / 2, target.y + target.height / 2, { steps: 10 })
      await page.mouse.up()
    }
    if (change === "edit") {
      await view.rows.getByText(order[1], { exact: true }).click()
      await expect(view.input).toHaveText(order[1])
      await expect(view.input).toBeFocused()
      await view.input.press("End")
      await view.input.pressSequentially(", edited")
      await view.input.press("Enter")
    }

    // The replacements admitted before the failure are withdrawn; the originals stay in place.
    await expect.poll(() => mock.log.includes(`cancel:${String(mock.prompts.at(-1)?.id)}`)).toBe(true)
    await expect.poll(() => mock.changes.length).toBe(mock.prompts.length)
    expect(mock.changes.every((entry) => entry.action === "cancel" && !entry.inboxID.startsWith("inb_seed_"))).toBe(
      true,
    )
    await expect(view.rows.locator('[data-action="session-queue-edit"]')).toHaveText(order)
    expect(mock.rows.map((row) => row.payload.text)).toEqual(order)
    // A failed edit keeps its draft in the composer so nothing typed is lost.
    if (change === "edit") await expect(view.input).toHaveText("second queued prompt, edited")
  })
}

for (const delivery of ["queue", "steer"] as const) {
  test(`editing a prompt the server delivered meanwhile keeps the edit draft (${delivery})`, async ({ page }) => {
    const mock = createQueueMock(["first queued prompt", "second queued prompt"])
    const view = await openSession(page, mock, "queue")
    await view.rows.getByText("second queued prompt", { exact: true }).click()
    await expect(view.input).toHaveText("second queued prompt")
    await expect(view.input).toBeFocused()
    await view.input.press("End")
    await view.input.pressSequentially(", edited")
    // The server delivers the original before the edit lands; this client has not heard yet.
    mock.rows.splice(1, 1)
    await view.input.press(delivery === "queue" ? "Enter" : "ControlOrMeta+Enter")

    await expect(page.getByText("Request failed")).toBeVisible()
    await expect(view.input).toHaveText("second queued prompt, edited")
    expect(mock.prompts).toEqual([])
    expect(mock.changes).toEqual([])
  })
}

for (const change of ["reorder", "edit"] as const) {
  test(`a staged revert refuses a queue ${change}, whose admission would commit it`, async ({ page }) => {
    const order = ["first queued prompt", "second queued prompt"]
    const mock = createQueueMock(order, [
      { id: "msg_queue_delivered", type: "user", text: "First prompt", time: { created: 1 } },
    ])
    const view = await openSession(page, mock, undefined, "msg_queue_delivered")
    await expect(view.rows).toHaveCount(2)

    if (change === "reorder") {
      await view.rows.filter({ hasText: order[0] }).getByRole("button", { name: "Reorder queued prompt" }).hover()
      await page.mouse.down()
      const target = await view.rows.filter({ hasText: order[1] }).boundingBox()
      if (!target) throw new Error("The target queue row is not visible")
      await page.mouse.move(target.x + target.width / 2, target.y + target.height / 2, { steps: 10 })
      await page.mouse.up()
    }
    if (change === "edit") await view.rows.getByText(order[1], { exact: true }).click()

    await expect(page.getByText("Redo the revert before you reorder or edit queued prompts")).toBeVisible()
    await expect(view.rows.locator('[data-action="session-queue-edit"]')).toHaveText(order)
    await expect(view.input).toHaveText("")
    expect(mock.prompts).toEqual([])
    expect(mock.changes).toEqual([])
  })
}

test("a prompt commits a staged revert after the agent switch and before the model switch", async ({ page }) => {
  const mock = createQueueMock(
    [],
    [{ id: "msg_queue_delivered", type: "user", text: "First prompt", time: { created: 1 } }],
  )
  const requests: string[] = []
  page.on("request", (request) => {
    const path = new URL(request.url()).pathname
    if (request.method() === "GET" || !path.startsWith(`/api/session/${sessionID}/`)) return
    requests.push(path.slice(`/api/session/${sessionID}/`.length))
  })
  const view = await openSession(page, mock, "steer", "msg_queue_delivered")
  await view.input.fill("start over from here")
  await view.input.press("Enter")

  await expect.poll(() => mock.prompts.map((prompt) => prompt.text)).toEqual(["start over from here"])
  expect(requests.filter((path) => path !== "agent")).toEqual(["revert/commit", "model", "prompt"])
})

for (const [width, height] of [
  [1440, 900],
  [390, 844],
]) {
  for (const [action, status] of [
    ["Move to queue", "steering"],
    ["Delete", "steering"],
    ["Move to queue", "starting"],
    ["Delete", "starting"],
  ] as const) {
    test(`${action} on a ${status} pending steer replaces Revert at ${width}px`, async ({ page }, testInfo) => {
      await page.setViewportSize({ width, height })
      // A steer waits behind work only once the running execution delivered input; before that it is starting.
      const delivered: SessionMessageInfo[] =
        status === "steering"
          ? [{ id: "msg_queue_delivered", type: "user", text: "First prompt", time: { created: 1 } }]
          : []
      const mock = createQueueMock(["U2: Also check the retry path."], delivered)
      const inboxID = mock.rows[0].id
      mock.rows[0].delivery = "steer"
      const view = await openSession(page, mock)
      const pending = page.locator(
        `[data-timeline-virtual-content] [data-timeline-row="UserMessage"][data-message-id="${inboxID}"]`,
      )

      await expect(pending).toContainText("U2: Also check the retry path.")
      const message = pending.locator('[data-component="user-message"]')
      if (status === "steering") {
        await expect(message).toHaveAttribute("data-pending", "true")
        await expect(message.locator('[data-slot="user-message-meta"]')).toContainText("Pending")
      }
      if (status === "starting") {
        await expect(message).not.toHaveAttribute("data-pending")
        await expect(message).not.toContainText("Pending")
      }
      await pending.hover()
      await expect(pending.getByRole("button", { name: "Revert message" })).toHaveCount(0)
      await expect(pending.getByRole("button", { name: "Fork to new session" })).toHaveCount(0)
      await expect(pending.getByRole("button", { name: action })).toBeVisible()
      await pending.screenshot({ path: testInfo.outputPath(`pending-${status}.png`) })
      await pending.getByRole("button", { name: action }).click()

      await expect(pending).toHaveCount(0)
      expect(mock.changes).toEqual([{ inboxID, action: action === "Delete" ? "cancel" : "queue" }])
      // Neither action returns the prompt to the composer; a moved steer waits in the queue.
      await expect(view.input).toHaveText("")
      await expect(view.rows).toHaveCount(action === "Delete" ? 0 : 1)
      if (action === "Move to queue") await expect(view.rows).toContainText("U2: Also check the retry path.")
    })
  }
}

test("the side question composer hides the queue panel until it closes", async ({ page }) => {
  const mock = createQueueMock(["first queued prompt"])
  const view = await openSession(page, mock)
  await expect(view.rows).toHaveCount(1)

  await view.input.click()
  await page.keyboard.type("/btw")
  await expect(page.locator('[data-suggestion-id="session.btw"]')).toHaveAttribute("data-active", "")
  await page.keyboard.press("Enter")
  const side = page.getByRole("region", { name: "Ask a side question", exact: true })
  await expect(side).toBeVisible()
  await expect(view.rows).toHaveCount(0)

  await page.keyboard.press("Escape")
  await expect(side).toHaveCount(0)
  await expect(view.rows).toHaveCount(1)
})

test("a queued compaction shows after the active turn and ahead of pending steers", async ({ page }) => {
  const mock = createQueueMock(
    ["U2: Also check the retry path."],
    [{ id: "msg_queue_delivered", type: "user", text: "First prompt", time: { created: 1 } }],
  )
  mock.rows[0].delivery = "steer"
  mock.compactions.push({
    id: "msg_queue_compaction",
    sessionID,
    time: { created: 1700000000005 },
    type: "compaction",
    payload: {},
    delivery: "steer",
  })
  await openSession(page, mock)
  const transcript = page.locator("[data-timeline-virtual-content]")
  const queued = transcript.locator('[data-timeline-row="CompactionQueued"]')

  await expect(queued).toHaveText("Session compaction queued")
  await expect(
    transcript.locator('[data-timeline-row="UserMessage"], [data-timeline-row="CompactionQueued"]'),
  ).toHaveText([/First prompt/, "Session compaction queued", /U2: Also check the retry path\./])
})

for (const [width, height] of [
  [1440, 900],
  [390, 844],
]) {
  test(`undo restores a queued prompt after the draft and keeps unrestorable prompts queued at ${width}px`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height })
    const mock = createQueueMock([
      {
        text: "tighten the error copy\nAttached file: `/remote/document.pdf`",
        files: [{ data: "cGRm", mime: "application/pdf", name: "document.pdf", source: { type: "inline" } }],
        metadata: { displayText: "tighten the error copy", comments: [], attachments: [] },
      },
      {
        text: "fix it\nThe user made the following comment regarding line 2 of src/a.ts: tighten",
        files: [{ data: "", mime: "text/plain", source: { type: "uri", uri: "file:///repo/src/a.ts?start=2&end=2" } }],
        metadata: { displayText: "fix it", comments: [{ path: "src/a.ts", comment: "tighten" }] },
      },
    ])
    const view = await openSession(page, mock)
    await expect(view.rows).toHaveCount(2)
    await view.input.fill("my in-progress draft")

    const commented = view.rows.filter({ hasText: "fix it" })
    await commented.locator('[data-action="session-queue-undo"]').click()
    await expect(
      page.getByText("This queued prompt can't be restored without losing context. Edit it in the queue instead."),
    ).toBeVisible()
    await expect(view.rows).toHaveCount(2)
    expect(mock.changes).toEqual([])

    await view.rows.filter({ hasText: "tighten the error copy" }).locator('[data-action="session-queue-undo"]').click()
    await expect(view.rows).toHaveCount(1)
    await expect(view.input.locator(".cm-line")).toHaveText(["my in-progress draft", "", "tighten the error copy"])
    await expect(view.composer.locator('div[data-attachment-id="inb_seed_1:file:0"]')).toContainText("document.pdf")
    expect(mock.changes).toEqual([{ inboxID: "inb_seed_1", action: "cancel" }])
  })
}

for (const delivery of ["steer", "queue"] as const) {
  test(`keeps finished tools above a pending ${delivery === "queue" ? "queue-to-steer" : "steer"} follow-up`, async ({
    page,
  }, testInfo) => {
    const model = { id: "queue-model", providerID: "opencode" }
    const userID = "msg_queue_initial_user"
    const assistantID = "msg_queue_continued_assistant"
    const followUp = "U2: Also check the retry path."
    const mock = createQueueMock(
      [],
      [
        { id: userID, type: "user", text: "U1: Inspect the queue ordering.", time: { created: 1700000000000 } },
        {
          id: "msg_queue_initial_assistant",
          type: "assistant",
          agent: "build",
          model,
          content: [{ type: "text", text: "A1: I will inspect the current implementation." }],
          finish: "tool-calls",
          time: { created: 1700000000001, completed: 1700000000002 },
        },
      ],
    )
    const view = await openSession(page, mock, delivery)
    const transcript = page.locator("[data-timeline-virtual-content]")
    const thinking = transcript.locator('[data-timeline-row="Thinking"]')
    await expect(transcript.getByText("A1: I will inspect the current implementation.", { exact: true })).toBeVisible()
    await expect(thinking).toHaveCount(0)
    await expect(view.input).toBeEditable()
    await view.input.fill(followUp)
    await view.input.press("Enter")
    await expect.poll(() => mock.rows.map((row) => row.delivery)).toEqual([delivery])
    await expect(view.input).toHaveText("")

    const inboxID = mock.rows[0].id
    const pending = transcript.locator(`[data-timeline-row="UserMessage"][data-message-id="${inboxID}"]`)
    if (delivery === "queue") {
      const queued = view.rows.filter({ hasText: followUp })
      await expect(queued).toBeVisible()
      await expect(pending).toHaveCount(0)
      await expect(thinking).toHaveCount(0)
      await queued.hover()
      await queued.getByRole("button", { name: "Steer", exact: true }).click()
      await expect.poll(() => mock.changes).toEqual([{ inboxID, action: "steer" }])
    }
    await expect(view.rows).toHaveCount(0)
    await expect(pending).toContainText(followUp)
    await expect(thinking).toHaveCount(0)

    // The next assistant step still belongs to U1: U2 has been admitted, not delivered.
    mock.emit("session.step.started", {
      sessionID,
      assistantMessageID: assistantID,
      agent: "build",
      model,
      started: Date.now(),
    })
    for (const tool of [
      { id: "tool_queue_read", name: "read", input: { path: "src/queue.ts" } },
      { id: "tool_queue_grep", name: "grep", input: { pattern: "retry", path: "src" } },
    ]) {
      const ref = { sessionID, assistantMessageID: assistantID, id: tool.id }
      mock.emit("session.tool.input.started", { ...ref, name: tool.name })
      mock.emit("session.tool.input.ended", { ...ref, text: JSON.stringify(tool.input) })
      mock.emit("session.tool.called", { ...ref, input: tool.input, executed: true })
      mock.emit("session.tool.success", {
        ...ref,
        content: [{ type: "text", text: "Inspection complete." }],
        executed: true,
      })
    }
    mock.emit("session.step.ended", {
      sessionID,
      assistantMessageID: assistantID,
      finish: "tool-calls",
      cost: 0,
      tokens: { input: 100, output: 20, reasoning: 0, cache: { read: 0, write: 0 } },
    })
    const tools = page.locator('[data-timeline-part-ids="tool_queue_read,tool_queue_grep"]')
    await expect(tools).toBeVisible()
    await expect(tools).toHaveText(/^Used\s*2\s*Read, Grep$/)
    await expect(tools.locator('[data-slot="basic-tool-tool-title"]')).toHaveText("Read, Grep")
    await expect(thinking).toHaveCount(0)
    await expect(pending).toBeVisible()
    expect(mock.rows.map((row) => ({ id: row.id, delivery: row.delivery }))).toEqual([
      { id: inboxID, delivery: "steer" },
    ])
    await transcript.screenshot({ path: testInfo.outputPath("pending-steer.png") })

    // Soft assertions let delivery run too, even when the pending ordering regresses.
    await expect.soft(tools.or(pending)).toHaveText([/^Used\s*2\s*Read, Grep$/, /U2: Also check the retry path\./])
    await expect
      .soft(transcript.locator('[data-timeline-row="AssistantPart"]').filter({ has: tools }))
      .toHaveAttribute("data-message-id", userID)
    await expect
      .configure({ soft: true })
      .poll(async () => {
        const boxes = await Promise.all([tools.boundingBox(), pending.boundingBox()])
        return boxes.every((box) => box !== null) && boxes[0]!.y + boxes[0]!.height <= boxes[1]!.y
      })
      .toBe(true)

    mock.rows.splice(0, 1)
    mock.emit("session.inbox.delivered", { sessionID, inboxID })
    await expect(thinking).toHaveCount(0)
    await expect(pending).toHaveCount(1)
    await expect(transcript.locator('[data-timeline-row="UserMessage"]')).toHaveCount(2)
    await expect(transcript.locator('[data-timeline-row="AssistantPart"]').filter({ has: tools })).toHaveAttribute(
      "data-message-id",
      userID,
    )

    const later = { sessionID, assistantMessageID: "msg_queue_follow_up_assistant" }
    mock.emit("session.step.started", { ...later, agent: "build", model, started: Date.now() })
    mock.emit("session.text.started", { ...later, ordinal: 0 })
    mock.emit("session.text.ended", { ...later, ordinal: 0, text: "A3: Now checking the retry path for U2." })
    const response = transcript
      .locator('[data-timeline-row="AssistantPart"]')
      .filter({ hasText: "A3: Now checking the retry path for U2." })
    await expect(response).toHaveAttribute("data-message-id", inboxID)
    await expect(thinking).toHaveCount(0)
    await expect(tools.or(pending).or(response)).toHaveText([
      /^Used\s*2\s*Read, Grep$/,
      /U2: Also check the retry path\./,
      /A3: Now checking the retry path for U2\./,
    ])
  })
}
