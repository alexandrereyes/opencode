import { describe, expect, test } from "bun:test"
import type { ModelSelection } from "@/providers/models/selection"
import type { SessionMessageUser } from "@opencode/client/promise"
import { Skill } from "@opencode/schema/skill"
import { Session } from "@opencode/schema/session"
import { AbsolutePath } from "@opencode/schema/schema"
import type { ActiveComposerAdapter, ComposerControls, ComposerSession, NewSessionComposerAdapter } from "./adapter"
import { createMemoryComposerState, type Prompt } from "./state"
import type { PromptHistoryComment } from "./history/entry"
import { createComposerSubmit } from "./submit"
import { createSessionRevertActions } from "@/session/revert"

const selectedModel = {
  id: "model-1",
  name: "Model 1",
  provider: { id: "provider-1" },
} as NonNullable<ReturnType<ModelSelection["current"]>>

const selection = {
  ready: Object.assign(() => true, { promise: undefined }),
  current: () => selectedModel,
  recent: () => [selectedModel],
  list: () => [selectedModel],
  cycle() {},
  set() {},
  visible: () => true,
  setVisibility() {},
  variant: {
    configured: () => undefined,
    selected: () => "balanced",
    current: () => "balanced",
    list: () => ["balanced"],
    set() {},
    cycle() {},
  },
} satisfies ModelSelection

const slashSkill = Skill.Info.make({
  id: Skill.ID.make("show-me"),
  name: Skill.Name.make("Show Me"),
  description: "Explain visually",
  slash: true,
  autoinvoke: false,
  location: AbsolutePath.make("/skills/show-me/SKILL.md"),
  content: "Explain visually",
})

function controls(): ComposerControls {
  return {
    agents: {
      available: [{ name: "build", mode: "primary" }],
      options: ["build"],
      current: "build",
      visible: true,
      select() {},
    },
    model: { selection, paid: true, loading: false },
    session: {
      tabs: { active: () => undefined, all: () => [], open() {}, setActive() {} },
      reviewPanel: { opened: () => false, open() {} },
    },
  }
}

function submitInput(
  adapter: ActiveComposerAdapter | NewSessionComposerAdapter,
  notify = { missingSelection() {}, failed(_kind: "shell" | "command" | "prompt", _error: unknown) {} },
  mode: "normal" | "shell" = "normal",
  commands: () => readonly { name: string }[] | undefined = () => [],
  skills: () => readonly Skill.Info[] | undefined = () => [],
  lifecycle?: {
    history?: (prompt: Prompt, mode: "normal" | "shell") => void
    comments?: {
      capture: () => PromptHistoryComment[]
      clear: () => void
      current?: () => object
      restore: (comments: PromptHistoryComment[]) => void
    }
  },
) {
  return createComposerSubmit({
    adapter,
    mode: () => mode,
    commands,
    skills,
    editor: () => undefined,
    queueScroll() {},
    addToHistory: lifecycle?.history ?? (() => undefined),
    resetHistory() {},
    setMode() {},
    closePopover() {},
    notify,
    comments: lifecycle?.comments ?? { capture: () => [], clear() {}, restore() {} },
  })
}

function session(input: {
  calls: string[]
  prompt: (value: Parameters<ComposerSession["data"]["session"]["prompt"]>[0]) => Promise<void>
  handoff?: ComposerSession["handoff"]
  statuses?: ("idle" | "running")[]
  current?: ComposerSession["current"]
  admitted?: (messageID: string) => boolean
  shell?: () => Promise<unknown>
  command?: ComposerSession["api"]["command"]
  switchAgent?: ComposerSession["api"]["switchAgent"]
  switchModel?: ComposerSession["api"]["switchModel"]
}): ComposerSession {
  return {
    id: "session-1",
    directory: "C:/repo",
    handoff: input.handoff,
    current: input.current ?? (() => undefined),
    admitted: input.admitted ?? (() => false),
    api: {
      switchAgent:
        input.switchAgent ??
        (async () => {
          input.calls.push("switch-agent")
        }),
      switchModel:
        input.switchModel ??
        (async () => {
          input.calls.push("switch-model")
        }),
      shell: input.shell ?? (async () => undefined),
      command: input.command ?? (async () => undefined),
    },
    data: {
      location: { command: { list: () => [] } },
      session: {
        setStatus: (_sessionID, status) => input.statuses?.push(status),
        prompt: async (value) => {
          input.calls.push("prompt")
          await input.prompt(value)
        },
      },
    },
  }
}

describe("Composer submission", () => {
  for (const command of [false, true]) {
    test(`expands snippets for ${command ? "command arguments" : "prompt admission"}`, async () => {
      const state = createMemoryComposerState().capture()
      const prefix = command ? "/review " : ""
      state.set([
        { type: "text", content: prefix, start: 0, end: prefix.length },
        {
          type: "snippet",
          id: "snippet",
          name: "review",
          content: "#review",
          expansion: "/review is literal\nSecond line",
          start: prefix.length,
          end: prefix.length + 7,
        },
      ])
      const completed = Promise.withResolvers<void>()
      const target = session({
        calls: [],
        prompt: async (value) => {
          expect(command).toBe(false)
          expect(value.text).toBe("/review is literal\nSecond line")
          expect(value.metadata?.displayText).toBe(value.text)
          completed.resolve()
        },
        command: async (value) => {
          expect(command).toBe(true)
          expect(value.command).toBe("review")
          expect(value.text).toBe("/review is literal\nSecond line")
          completed.resolve()
        },
      })
      const adapter: ActiveComposerAdapter = {
        kind: "active-session",
        state,
        ready: () => true,
        controls,
        working: () => false,
        session: () => target,
        interrupt: async () => undefined,
        submitted() {},
        setEditor() {},
      }
      await submitInput(adapter, undefined, "normal", () => [{ name: "review" }]).submit(new Event("submit"))
      await completed.promise
    })
  }

  test("sends a quote-only prompt and restores its comment after a failed admission", async () => {
    const state = createMemoryComposerState().capture()
    const id = state.quotes.add({ messageID: "msg_answer", partID: "msg_answer:text:0", text: "Quoted passage" })
    state.quotes.update(id, "Please explain")
    const failed = Promise.withResolvers<void>()
    const requests: Parameters<ComposerSession["data"]["session"]["prompt"]>[0][] = []
    const target = session({
      calls: [],
      prompt: async (value) => {
        requests.push(value)
        throw new Error("offline")
      },
    })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }
    await submitInput(adapter, { missingSelection() {}, failed: () => failed.resolve() }).submit(new Event("submit"))
    await failed.promise
    expect(requests).toHaveLength(2)
    expect(requests[0].id).toBe(requests[1].id)
    expect(requests[0].text).toContain("> Quoted passage\nUser comment: Please explain")
    expect(state.quotes.all()).toEqual([
      { id, messageID: "msg_answer", partID: "msg_answer:text:0", text: "Quoted passage", comment: "Please explain" },
    ])
  })
  test.each(["prompt", "command"] as const)("preserves new quotes while %s waits for undo", async (kind) => {
    const state = createMemoryComposerState({
      prompt: kind === "command" ? "/review changes" : "Review changes",
    }).capture()
    const original = state.quotes.add({
      messageID: "msg_original",
      partID: "msg_original:text:0",
      text: "Original quote",
    })
    state.quotes.update(original, "Original comment")
    const ready = Promise.withResolvers<boolean>()
    const sent = Promise.withResolvers<string>()
    const target = session({
      calls: [],
      prompt: async (request) => sent.resolve(request.text),
      command: async (request) => sent.resolve(request.text),
    })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submissionBarrier: { pending: () => true, wait: () => ready.promise },
      submitted() {},
      setEditor() {},
    }
    const submitting = submitInput(adapter, undefined, "normal", () => [{ name: "review" }]).submit(new Event("submit"))
    expect(state.quotes.all()).toEqual([])
    const next = state.quotes.add({ messageID: "msg_next", partID: "msg_next:text:0", text: "Next quote" })
    state.quotes.update(next, "Next comment")
    ready.resolve(true)
    await submitting
    const text = await sent.promise
    expect(text).toContain("Original quote")
    expect(text).toContain("Original comment")
    expect(text).not.toContain("Next quote")
    expect(state.quotes.all()).toEqual([
      { id: next, messageID: "msg_next", partID: "msg_next:text:0", text: "Next quote", comment: "Next comment" },
    ])
  })

  test("applies the captured agent and model before a custom command without passing over its overrides", async () => {
    const state = createMemoryComposerState({ prompt: "/review changes" }).capture()
    const calls: string[] = []
    const selected = controls()
    const agent = Promise.withResolvers<void>()
    const started = Promise.withResolvers<void>()
    const committed = Promise.withResolvers<void>()
    const completed = Promise.withResolvers<void>()
    const target = session({
      calls,
      prompt: async () => {
        throw new Error("command must not call prompt")
      },
      switchAgent: async (request) => {
        expect(request.agent).toBe("build")
        calls.push("agent")
        started.resolve()
        await agent.promise
      },
      switchModel: async (request) => {
        expect(request.model).toEqual({ providerID: "provider-1", id: "model-1", variant: "balanced" })
        calls.push("model")
        await committed.promise
      },
      command: async (request) => {
        expect(request).toMatchObject({ command: "review", text: "changes", delivery: "steer" })
        expect(request).not.toHaveProperty("model")
        expect(request).not.toHaveProperty("agent")
        calls.push("command")
        completed.resolve()
      },
    })
    selected.model.selection = {
      ...selection,
      trackSessionCommit: (_id, value) => {
        expect(value).toEqual({
          agent: "build",
          model: { providerID: "provider-1", modelID: "model-1" },
          variant: "balanced",
        })
        calls.push("track")
        return () => calls.push("cancel")
      },
    }
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls: () => selected,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }
    await submitInput(adapter, undefined, "normal", () => [{ name: "review" }]).submit(new Event("submit"))
    await started.promise
    expect(calls).toEqual(["track", "agent"])
    selected.agents.current = "plan"
    selected.model.selection = { ...selection, variant: { ...selection.variant, current: () => "high" } }
    agent.resolve()
    committed.resolve()
    await completed.promise
    expect(calls).toEqual(["track", "agent", "model", "command"])
  })

  test("commits the model even when cached session state already matches", async () => {
    const state = createMemoryComposerState({ prompt: "continue" }).capture()
    const calls: string[] = []
    const done = Promise.withResolvers<void>()
    const target = session({
      calls,
      current: () => ({ agent: "build", model: { providerID: "provider-1", id: "model-1", variant: "balanced" } }),
      prompt: async () => done.resolve(),
    })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }
    await submitInput(adapter).submit(new Event("submit"))
    await done.promise
    expect(calls).toEqual(["switch-model", "prompt"])
  })

  test("cancels selection tracking and does not execute a command when selection fails", async () => {
    const state = createMemoryComposerState({ prompt: "/review changes" }).capture()
    const calls: string[] = []
    const selected = controls()
    const failed = Promise.withResolvers<unknown>()
    const error = new Error("model unavailable")
    const target = session({
      calls,
      prompt: async () => {
        calls.push("prompt")
      },
      switchModel: async () => {
        throw error
      },
      command: async () => {
        calls.push("command")
      },
    })
    selected.model.selection = {
      ...selection,
      trackSessionCommit: () => {
        calls.push("track")
        return () => {
          calls.push("cancel")
        }
      },
    }
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls: () => selected,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }
    await submitInput(
      adapter,
      { missingSelection() {}, failed: (_kind, error) => failed.resolve(error) },
      "normal",
      () => [{ name: "review" }],
    ).submit(new Event("submit"))
    expect(await failed.promise).toBe(error)
    expect(calls).toEqual(["track", "switch-agent", "cancel"])
    expect(state.current()[0]).toMatchObject({ content: "/review changes" })
  })

  test("submits a slash skill with its trailing text and attachments", async () => {
    const state = createMemoryComposerState({ prompt: "/show-me explain " }).capture()
    state.set([
      { type: "text", content: "/show-me explain ", start: 0, end: 17 },
      { type: "file", path: "src/cache.ts", content: "@src/cache.ts", start: 17, end: 30 },
    ])
    const admitted = Promise.withResolvers<Parameters<ComposerSession["data"]["session"]["prompt"]>[0]>()
    const target = session({ calls: [], prompt: async (value) => admitted.resolve(value) })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }

    await submitInput(
      adapter,
      undefined,
      "normal",
      () => [],
      () => [slashSkill],
    ).submit(new Event("submit"))
    const request = await admitted.promise
    expect(request.text).toBe("/show-me explain @src/cache.ts")
    expect(request.skills).toEqual([
      expect.objectContaining({ id: "show-me", mention: { start: 0, end: 8, text: "/show-me" } }),
    ])
    expect(request.files).toEqual([
      { uri: "file:///C:/repo/src/cache.ts", name: "cache.ts", mention: { start: 17, end: 30, text: "@src/cache.ts" } },
    ])
  })

  test.each([
    { text: "/show-me", slash: true, expected: ["show-me"] },
    { text: "/show-me\nexplain caching", slash: true, expected: ["show-me"] },
    { text: "/show-me\texplain caching", slash: true, expected: ["show-me"] },
    { text: "/show-me", slash: false, expected: [] },
    { text: "/show-me", slash: undefined, expected: [] },
    { text: "/show-me-extra", slash: true, expected: [] },
    { text: "Explain /show-me", slash: true, expected: [] },
  ])("resolves raw slash skill input $text with slash=$slash", async ({ text, slash, expected }) => {
    const state = createMemoryComposerState({ prompt: text }).capture()
    const admitted = Promise.withResolvers<Parameters<ComposerSession["data"]["session"]["prompt"]>[0]>()
    const target = session({ calls: [], prompt: async (value) => admitted.resolve(value) })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }
    await submitInput(
      adapter,
      undefined,
      "normal",
      () => [],
      () => [{ ...slashSkill, slash }],
    ).submit(new Event("submit"))
    const request = await admitted.promise
    expect(request.text).toBe(text)
    expect(request.skills?.map((skill) => skill.id)).toEqual([...expected])
  })

  test("captures slash skills before creating a session in a new worktree", async () => {
    const state = createMemoryComposerState({ prompt: "/show-me" }).capture()
    let skills: readonly Skill.Info[] | undefined = [slashSkill]
    const admitted = Promise.withResolvers<Parameters<ComposerSession["data"]["session"]["prompt"]>[0]>()
    const target = session({ calls: [], prompt: async (value) => admitted.resolve(value) })
    const adapter: NewSessionComposerAdapter = {
      kind: "new-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      submitted() {},
      async start() {
        skills = undefined
        return { session: target, cleanupReady: Promise.resolve() }
      },
    }
    await submitInput(
      adapter,
      undefined,
      "normal",
      () => [],
      () => skills,
    ).submit(new Event("submit"))
    expect((await admitted.promise).skills).toEqual([
      expect.objectContaining({ id: "show-me", mention: { start: 0, end: 8, text: "/show-me" } }),
    ])
  })

  test("sends one captured value with explicit delivery after selection switches", async () => {
    const state = createMemoryComposerState({ prompt: "ship it" }).capture()
    const calls: string[] = []
    const admitted = Promise.withResolvers<Parameters<ComposerSession["data"]["session"]["prompt"]>[0]>()
    const target = session({
      calls,
      current: () => ({ agent: "plan", model: { id: "old", providerID: "old" } }),
      prompt: async (value) => admitted.resolve(value),
    })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }

    await submitInput(adapter).submit(new Event("submit"))
    const request = await admitted.promise

    expect(calls).toEqual(["switch-agent", "switch-model", "prompt"])
    expect(request.delivery).toBe("steer")
    expect(request.text).toBe("ship it")
    expect(request.id).toMatch(/^msg_/)
    expect(request.metadata).toMatchObject({
      displayText: "ship it",
      agent: "build",
      model: { providerID: "provider-1", modelID: "model-1", variant: "balanced" },
    })
    expect(state.current()).toEqual([{ type: "text", content: "", start: 0, end: 0 }])
  })

  test("starts and promotes a New Session once before admitting its first prompt", async () => {
    const draft = createMemoryComposerState({ prompt: "first prompt" }).capture()
    const promoted = createMemoryComposerState({ prompt: "restored draft" }).capture()
    const calls: string[] = []
    const statuses: ("idle" | "running")[] = []
    const admitted = Promise.withResolvers<Parameters<ComposerSession["data"]["session"]["prompt"]>[0]>()
    const cleanupReady = Promise.withResolvers<void>()
    const target = session({ calls, statuses, prompt: async (value) => admitted.resolve(value) })
    const adapter: NewSessionComposerAdapter = {
      kind: "new-session",
      state: draft,
      ready: () => true,
      controls,
      working: () => false,
      submitted() {
        calls.push("submitted")
      },
      async start(_selection, submission) {
        calls.push("start")
        submission.retarget(promoted)
        return { session: target, cleanupReady: cleanupReady.promise }
      },
    }

    const submitted = submitInput(adapter).submit(new Event("submit"))
    const request = await admitted.promise

    expect(calls).toEqual(["start", "switch-agent", "switch-model", "prompt"])
    expect(statuses).toEqual(["running"])
    expect(promoted.current()).toMatchObject([{ type: "text", content: "restored draft" }])
    cleanupReady.resolve()
    await submitted

    expect(calls).toEqual(["start", "switch-agent", "switch-model", "prompt", "submitted"])
    expect(request.delivery).toBe("steer")
    expect(request.text).toBe("first prompt")
    expect(draft.current()).toEqual([{ type: "text", content: "", start: 0, end: 0 }])
    expect(promoted.current()).toEqual([{ type: "text", content: "", start: 0, end: 0 }])
  })

  test("hands off cited images with offsets remapped after snippet expansion", async () => {
    const draft = createMemoryComposerState().capture()
    draft.set([
      { type: "snippet", id: "short", name: "short", expansion: "Expanded", content: "#s", start: 0, end: 2 },
      { type: "text", content: " [image.png]", start: 2, end: 14 },
      {
        type: "image",
        id: "attachment",
        filename: "image.png",
        mime: "image/png",
        blob: { id: "attachment", url: "data:image/png;base64,YQ==" },
        mention: { text: "[image.png]", start: 3, end: 14 },
      },
    ])
    const handedOff = Promise.withResolvers<SessionMessageUser>()
    const target = session({
      calls: [],
      handoff: { set: handedOff.resolve, clear() {} },
      prompt: async () => undefined,
    })
    const adapter: NewSessionComposerAdapter = {
      kind: "new-session",
      state: draft,
      ready: () => true,
      controls,
      working: () => false,
      submitted() {},
      async start() {
        return { session: target, cleanupReady: Promise.resolve() }
      },
    }

    await submitInput(adapter).submit(new Event("submit"))

    const message = await handedOff.promise
    expect(message).toMatchObject({
      type: "user",
      text: "Expanded [image.png]",
      files: [
        {
          data: "",
          mime: "image/png",
          source: { type: "uri", uri: "data:image/png;base64,YQ==" },
          name: "image.png",
          mention: { text: "[image.png]", start: 9, end: 20 },
        },
      ],
    })
    const mention = message.files?.[0]?.mention
    if (!mention) throw new Error("Missing image mention")
    expect(message.text.slice(mention.start, mention.end)).toBe(mention.text)
  })

  test("previews the first prompt while starting and hands it off before completing preparation", async () => {
    const draft = createMemoryComposerState({ prompt: "prepare my worktree" }).capture()
    const promoted = createMemoryComposerState().capture()
    const preview = Promise.withResolvers<SessionMessageUser>()
    const ready = Promise.withResolvers<void>()
    const calls: string[] = []
    const handoff: SessionMessageUser[] = []
    const target = session({
      calls,
      handoff: { set: (message) => handoff.push(message), clear() {} },
      prompt: async () => undefined,
    })
    const adapter: NewSessionComposerAdapter = {
      kind: "new-session",
      state: draft,
      ready: () => true,
      controls,
      working: () => false,
      submitted() {},
      async start(_selection, submission, message) {
        preview.resolve(message)
        await ready.promise
        submission.retarget(promoted, { preserveDraft: true })
        return {
          session: target,
          cleanupReady: Promise.resolve(),
          async complete() {
            expect(handoff).toHaveLength(1)
            expect(handoff[0]?.id).toBe(message.id)
            expect(handoff[0]?.text).toBe("prepare my worktree")
            expect(promoted.current()).toEqual([{ type: "text", content: "", start: 0, end: 0 }])
            promoted.set([{ type: "text", content: "follow up", start: 0, end: 9 }], 9)
            calls.push("complete")
          },
        }
      },
    }

    const submitted = submitInput(adapter).submit(new Event("submit"))
    expect(await preview.promise).toMatchObject({ type: "user", text: "prepare my worktree" })
    expect(calls).toEqual([])
    expect(draft.current()).toMatchObject([{ content: "prepare my worktree" }])
    ready.resolve()
    await submitted
    expect(calls).toContain("complete")
    expect(draft.current()).toEqual([{ type: "text", content: "", start: 0, end: 0 }])
    expect(promoted.current()).toEqual([{ type: "text", content: "follow up", start: 0, end: 9 }])
  })

  test("does not restore a prompt already acknowledged by the durable inbox", async () => {
    const state = createMemoryComposerState({ prompt: "admitted prompt" }).capture()
    const checked = Promise.withResolvers<void>()
    const attempts: string[] = []
    const target = session({
      calls: [],
      admitted: () => {
        checked.resolve()
        return true
      },
      prompt: async (value) => {
        attempts.push(value.id ?? "")
        throw new Error("response lost")
      },
    })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }

    await submitInput(adapter).submit(new Event("submit"))
    await checked.promise

    expect(state.current()).toEqual([{ type: "text", content: "", start: 0, end: 0 }])
    expect(attempts).toHaveLength(2)
    expect(new Set(attempts).size).toBe(1)
  })

  test("restores first-prompt comments into the promoted Session", async () => {
    const draft = createMemoryComposerState({ prompt: "first prompt" }).capture()
    draft.store[1]("context", "items", [
      {
        key: "file:src/app.ts:1:1:comment",
        type: "file",
        path: "src/app.ts",
        comment: "Keep this comment",
        selection: { startLine: 1, startChar: 0, endLine: 1, endChar: 4 },
      },
    ])
    expect(draft.context.items()).toHaveLength(1)
    const promoted = createMemoryComposerState().capture()
    const failed = Promise.withResolvers<void>()
    const target = session({
      calls: [],
      prompt: async () => undefined,
      shell: async () => Promise.reject(new Error("send failed")),
    })
    const adapter: NewSessionComposerAdapter = {
      kind: "new-session",
      state: draft,
      ready: () => true,
      controls,
      working: () => false,
      submitted() {},
      async start(_selection, submission) {
        submission.retarget(promoted)
        return { session: target, cleanupReady: Promise.resolve() }
      },
    }

    await submitInput(adapter, { missingSelection() {}, failed: () => failed.resolve() }, "shell").submit(
      new Event("submit"),
    )
    await failed.promise

    expect(promoted.current()).toMatchObject([{ type: "text", content: "first prompt" }])
    expect(promoted.context.items()).toMatchObject([{ type: "file", path: "src/app.ts", comment: "Keep this comment" }])
    expect(promoted.mode.current()).toBe("shell")
  })

  test.each(["retry me", "/show-me retry me"])("restores and retries an unacknowledged admission: %s", async (text) => {
    const state = createMemoryComposerState({ prompt: text }).capture()
    const attempts: string[] = []
    const statuses: ("idle" | "running")[] = []
    const first = Promise.withResolvers<void>()
    const second = Promise.withResolvers<void>()
    const target = session({
      calls: [],
      statuses,
      prompt: async (value) => {
        attempts.push(value.id ?? "")
        expect(value.skills?.map((skill) => skill.id)).toEqual(text.startsWith("/") ? ["show-me"] : [])
        throw new Error("network unavailable")
      },
    })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }
    const notify = {
      missingSelection() {},
      failed: () => (attempts.length === 2 ? first.resolve() : second.resolve()),
    }
    const submission = submitInput(
      adapter,
      notify,
      "normal",
      () => [],
      () => [slashSkill],
    )

    await submission.submit(new Event("submit"))
    await first.promise
    await submission.submit(new Event("submit"))
    await second.promise

    expect(attempts).toHaveLength(4)
    expect(new Set(attempts).size).toBe(1)
    expect(statuses).toEqual(["running", "idle", "running", "idle"])
    expect(state.current()).toMatchObject([{ type: "text", content: text }])
  })

  test("forwards structured mentions to custom commands", async () => {
    const state = createMemoryComposerState().capture()
    state.set([
      { type: "text", content: "/review ", start: 0, end: 8 },
      { type: "file", path: "src/app.ts", content: "@src/app.ts", start: 8, end: 19 },
      { type: "text", content: " ", start: 19, end: 20 },
      { type: "agent", name: "review", content: "@review", start: 20, end: 27 },
      { type: "text", content: " ", start: 27, end: 28 },
      {
        type: "skill",
        id: Skill.ID.make("effect"),
        name: Skill.Name.make("Effect"),
        content: "$effect",
        start: 28,
        end: 35,
      },
      { type: "text", content: " ", start: 35, end: 36 },
      {
        type: "session",
        session: {
          id: Session.ID.make("ses_referenced_12345678901234567890"),
          server: "sidecar",
          title: "Shared",
          directory: "/repo/shared",
        },
        content: "@Shared",
        start: 36,
        end: 43,
      },
      { type: "text", content: " ", start: 43, end: 44 },
      {
        type: "session",
        session: {
          id: Session.ID.make("ses_referenced_12345678901234567890"),
          server: "sidecar",
          title: "Shared",
          directory: "/repo/shared",
        },
        content: "@Shared",
        start: 44,
        end: 51,
      },
    ])
    const sent = Promise.withResolvers<Parameters<ComposerSession["api"]["command"]>[0]>()
    const target = session({
      calls: [],
      prompt: async () => undefined,
      command: async (value) => sent.resolve(value),
    })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }

    await submitInput(adapter, undefined, "normal", () => [{ name: "review" }]).submit(new Event("submit"))
    const request = await sent.promise

    expect(request.files).toMatchObject([{ name: "app.ts", mention: { text: "@src/app.ts" } }])
    expect(request.agents).toMatchObject([{ name: "review", mention: { text: "@review" } }])
    expect(request.skills).toMatchObject([{ id: "effect", name: "Effect", mention: { text: "$effect" } }])
    expect(request.text.match(/"sessionID":"ses_referenced_12345678901234567890"/g)).toHaveLength(1)
    expect(request.text).toContain("tools.opencode.session_read")
    expect(request.delivery).toBe("steer")
  })

  test("captures commands before creating a session in a new worktree", async () => {
    const state = createMemoryComposerState({ prompt: "/review https://github.com/example/repo/pull/1" }).capture()
    const catalog = [{ name: "review" }]
    const sent = Promise.withResolvers<"prompt" | "command">()
    const requests: Parameters<ComposerSession["api"]["command"]>[0][] = []
    const target = session({
      calls: [],
      prompt: async () => sent.resolve("prompt"),
      command: async (value) => {
        requests.push(value)
        sent.resolve("command")
      },
    })
    target.directory = "C:/new-worktree"
    target.data.location.command.list = () => undefined
    const adapter: NewSessionComposerAdapter = {
      kind: "new-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      submitted() {},
      async start() {
        // The destination catalog has not loaded, and the source composer is leaving.
        catalog.splice(0)
        return { session: target, cleanupReady: Promise.resolve() }
      },
    }

    await submitInput(
      adapter,
      undefined,
      "normal",
      () => catalog,
      () => [{ ...slashSkill, id: Skill.ID.make("review") }],
    ).submit(new Event("submit"))

    expect(await sent.promise).toBe("command")
    expect(requests).toEqual([
      {
        sessionID: target.id,
        command: "review",
        text: "https://github.com/example/repo/pull/1",
        files: [],
        agents: [],
        skills: [],
        delivery: "steer",
      },
    ])
  })

  test("does not run an empty shell command from hidden attachments", async () => {
    const state = createMemoryComposerState().capture()
    state.set([
      { type: "text", content: "", start: 0, end: 0 },
      {
        type: "image",
        id: "attachment",
        filename: "notes.txt",
        mime: "text/plain",
        blob: { id: "attachment", url: "data:text/plain;base64,bm90ZXM=" },
      },
    ])
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => {
        throw new Error("shell should not run")
      },
      interrupt: async () => undefined,
      submitted() {},
      setEditor() {},
    }

    await submitInput(adapter, undefined, "shell").submit(new Event("submit"))

    expect(state.current().some((part) => part.type === "image")).toBe(true)
  })

  test("waits for a pending revert before sending and preserves the draft composed meanwhile", async () => {
    const state = createMemoryComposerState({ prompt: "send after undo" }).capture()
    const ready = Promise.withResolvers<boolean>()
    const received = Promise.withResolvers<string>()
    const calls: string[] = []
    const target = session({
      calls,
      prompt: async (value) => received.resolve(value.text),
    })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submissionBarrier: { pending: () => true, wait: () => ready.promise },
      submitted() {},
      setEditor() {},
    }

    const submitted = submitInput(adapter).submit(new Event("submit"))
    expect(state.current()).toEqual([{ type: "text", content: "", start: 0, end: 0 }])
    const nextDraft: Prompt = [
      { type: "text", content: "next draft", start: 0, end: 10 },
      {
        type: "image",
        id: "next-attachment",
        filename: "next.png",
        mime: "image/png",
        blob: { id: "next-attachment", url: "data:image/png;base64,bmV4dA==" },
      },
    ]
    state.set(nextDraft)
    expect(calls).toEqual([])

    ready.resolve(true)
    await submitted

    expect(await received.promise).toBe("send after undo")
    expect(state.current()).toEqual(nextDraft)
  })

  test("does not send through a failed revert or overwrite the draft composed meanwhile", async () => {
    const state = createMemoryComposerState({ prompt: "blocked by undo" }).capture()
    const ready = Promise.withResolvers<boolean>()
    const calls: string[] = []
    const history: Prompt[] = []
    const target = session({ calls, prompt: async () => undefined })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submissionBarrier: { pending: () => true, wait: () => ready.promise },
      submitted() {},
      setEditor() {},
    }

    const submitted = submitInput(adapter, undefined, "normal", undefined, undefined, {
      history: (prompt) => history.push(prompt),
    }).submit(new Event("submit"))
    state.set([{ type: "text", content: "keep this draft", start: 0, end: 15 }])
    ready.resolve(false)
    await submitted

    expect(calls).toEqual([])
    expect(state.current()).toEqual([{ type: "text", content: "keep this draft", start: 0, end: 15 }])
    expect(history).toEqual([[{ type: "text", content: "blocked by undo", start: 0, end: 15 }]])
  })

  test("does not restore captured comments over comment-only work added while revert waits", async () => {
    const state = createMemoryComposerState({ prompt: "blocked by undo" }).capture()
    const ready = Promise.withResolvers<boolean>()
    const cleared = {}
    const next = {}
    let commentState = cleared
    let restored = 0
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => session({ calls: [], prompt: async () => undefined }),
      interrupt: async () => undefined,
      submissionBarrier: { pending: () => true, wait: () => ready.promise },
      submitted() {},
      setEditor() {},
    }

    const submitted = submitInput(adapter, undefined, "normal", undefined, undefined, {
      comments: {
        capture: () => [],
        clear: () => (commentState = cleared),
        current: () => commentState,
        restore: () => restored++,
      },
    }).submit(new Event("submit"))
    commentState = next
    ready.resolve(false)
    await submitted

    expect(restored).toBe(0)
    expect(state.current()).toEqual([{ type: "text", content: "", start: 0, end: 0 }])
  })

  test("restores scoped comments without touching the destination after navigating during a failed revert", async () => {
    const state = createMemoryComposerState({ prompt: "session A" }).capture()
    state.context.add({ type: "file", path: "src/a.ts", comment: "comment A", commentID: "comment-a" })
    const ready = Promise.withResolvers<boolean>()
    const commentA: PromptHistoryComment = {
      id: "comment-a",
      path: "src/a.ts",
      selection: { start: 1, end: 1 },
      comment: "comment A",
      time: 1,
    }
    const commentB = { ...commentA, id: "comment-b", path: "src/b.ts", comment: "comment B" }
    const cleared: PromptHistoryComment[] = []
    let commentsA = [commentA]
    const commentsB = [commentB]
    let active = true
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => session({ calls: [], prompt: async () => undefined }),
      active: () => active,
      interrupt: async () => undefined,
      submissionBarrier: { pending: () => true, wait: () => ready.promise },
      submitted() {},
      setEditor() {},
    }

    const submitted = submitInput(adapter, undefined, "normal", undefined, undefined, {
      comments: {
        capture: () => commentsA,
        clear: () => (commentsA = cleared),
        current: () => commentsA,
        restore: (comments) => (commentsA = comments),
      },
    }).submit(new Event("submit"))
    active = false
    ready.resolve(false)
    await submitted

    expect(commentsA).toEqual([commentA])
    expect(commentsB).toEqual([commentB])
    expect(state.context.items()).toMatchObject([{ path: "src/a.ts", comment: "comment A" }])
  })

  test.each([
    { name: "shell", text: "echo retry-me", mode: "shell" as const, commands: () => [] },
    { name: "command", text: "/review retry-me", mode: "normal" as const, commands: () => [{ name: "review" }] },
  ])("restores an unchanged $name submission when a pending revert fails", async ({ text, mode, commands }) => {
    const state = createMemoryComposerState({ prompt: text }).capture()
    const ready = Promise.withResolvers<boolean>()
    const comments = {}
    let restored = 0
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => session({ calls: [], prompt: async () => undefined }),
      interrupt: async () => undefined,
      submissionBarrier: { pending: () => true, wait: () => ready.promise },
      submitted() {},
      setEditor() {},
    }

    const submitted = submitInput(adapter, undefined, mode, commands, undefined, {
      comments: {
        capture: () => [],
        clear() {},
        current: () => comments,
        restore: () => restored++,
      },
    }).submit(new Event("submit"))
    ready.resolve(false)
    await submitted

    expect(state.current()).toEqual([{ type: "text", content: text, start: 0, end: text.length }])
    expect(state.mode.current()).toBe(mode)
    expect(restored).toBe(1)
  })

  test("cleans captured comments before waiting and preserves comments added to the next draft", async () => {
    const state = createMemoryComposerState({ prompt: "review this" }).capture()
    state.context.add({
      type: "file",
      path: "src/file.ts",
      comment: "original",
      commentID: "comment-1",
    })
    const ready = Promise.withResolvers<boolean>()
    const sent = Promise.withResolvers<void>()
    const original: PromptHistoryComment = {
      id: "comment-1",
      path: "src/file.ts",
      selection: { start: 1, end: 1 },
      comment: "original",
      time: 1,
    }
    const next = { ...original, comment: "next", time: 2 }
    let comments = [original]
    let clears = 0
    const target = session({ calls: [], prompt: async () => sent.resolve() })
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submissionBarrier: { pending: () => true, wait: () => ready.promise },
      submitted() {},
      setEditor() {},
    }

    const submitted = submitInput(adapter, undefined, "normal", undefined, undefined, {
      comments: {
        capture: () => comments,
        clear: () => {
          clears++
          comments = []
        },
        restore: (value) => (comments = value),
      },
    }).submit(new Event("submit"))
    expect(clears).toBe(1)
    expect(state.context.items()).toEqual([])

    state.context.add({
      type: "file",
      path: "src/file.ts",
      comment: "next",
      commentID: "comment-1",
    })
    comments = [next]
    ready.resolve(true)
    await submitted
    await sent.promise

    expect(clears).toBe(1)
    expect(comments).toEqual([next])
    expect(state.context.items()).toHaveLength(1)
    expect(state.context.items()[0]?.comment).toBe("next")
  })

  test("keeps a session revert barrier across composer remounts without blocking another session", async () => {
    const composerA = createMemoryComposerState({ prompt: "session A" })
    const stateA = composerA.capture()
    const stateB = createMemoryComposerState({ prompt: "session B" }).capture()
    const gate = Promise.withResolvers<void>()
    const revert = stateA.revert.schedule("message-a", async () => {
      await gate.promise
      return true
    })
    const callsA: string[] = []
    const callsB: string[] = []
    const sentA = Promise.withResolvers<void>()
    const sentB = Promise.withResolvers<void>()
    const adapter = (state: typeof stateA, target: ComposerSession): ActiveComposerAdapter => ({
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => target,
      interrupt: async () => undefined,
      submissionBarrier: state.revert,
      submitted() {},
      setEditor() {},
    })
    const targetA = session({ calls: callsA, prompt: async () => sentA.resolve() })
    const targetB = session({ calls: callsB, prompt: async () => sentB.resolve() })

    await submitInput(adapter(stateB, targetB)).submit(new Event("submit"))
    await sentB.promise
    expect(callsB.at(-1)).toBe("prompt")

    const submittedA = submitInput(adapter(composerA.capture(), targetA)).submit(new Event("submit"))
    expect(callsA).toEqual([])
    gate.resolve()
    await revert
    await submittedA
    await sentA.promise
    expect(callsA.at(-1)).toBe("prompt")
  })

  test("captures the active session location and does not submit view callbacks after navigation", async () => {
    const state = createMemoryComposerState().capture()
    state.set([
      { type: "text", content: "review ", start: 0, end: 7 },
      { type: "file", path: "src/file.ts", content: "@src/file.ts", start: 7, end: 19 },
    ])
    const gate = Promise.withResolvers<void>()
    state.revert.schedule("message-a", async () => {
      await gate.promise
      return true
    })
    const admitted = Promise.withResolvers<Parameters<ComposerSession["data"]["session"]["prompt"]>[0]>()
    const target = session({ calls: [], prompt: async (value) => admitted.resolve(value) })
    let directory = "/workspace-a"
    let active = true
    let submitted = 0
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state,
      ready: () => true,
      controls,
      working: () => false,
      session: () => ({ ...target, directory }),
      active: () => active,
      interrupt: async () => undefined,
      submissionBarrier: state.revert,
      submitted: () => submitted++,
      setEditor() {},
    }

    const request = submitInput(adapter).submit(new Event("submit"))
    directory = "/workspace-b"
    active = false
    gate.resolve()
    await request

    expect((await admitted.promise).files).toEqual([
      {
        uri: "file:///workspace-a/src/file.ts",
        name: "file.ts",
        mention: { start: 7, end: 19, text: "@src/file.ts" },
      },
    ])
    expect(submitted).toBe(0)
  })

  test("holds a reverted submission until the captured inbox cleanup finishes", async () => {
    const composer = createMemoryComposerState()
    const message: SessionMessageUser = {
      id: "message-old",
      type: "user",
      text: "old prompt",
      time: { created: 0 },
    }
    const listed = Promise.withResolvers<void>()
    const list = Promise.withResolvers<
      {
        id: string
        sessionID: string
        timeCreated: number
        type: "user"
        payload: { text: string }
        delivery: "queue"
      }[]
    >()
    const cancelling = Promise.withResolvers<void>()
    const cancel = Promise.withResolvers<void>()
    const revert = createSessionRevertActions(
      {
        session: {
          identity: { params: { id: "session-1" } },
          history: { userMessages: () => [message] },
          data: { revertMessageID: () => undefined },
        },
        setActiveMessage() {},
      },
      {
        prompt: composer,
        directory: () => "/repo",
        failed: () => undefined,
        pending: { list: () => [] },
        api: {
          interrupt: async () => ({ interrupted: true }),
          wait: async () => undefined,
          revert: {
            stage: async () => ({ messageID: message.id }),
            clear: async () => undefined,
          },
          inbox: {
            list: async () => {
              listed.resolve()
              return list.promise
            },
            cancel: async () => {
              cancelling.resolve()
              await cancel.promise
            },
          },
        },
      },
    )
    const undo = revert.undo()
    expect(composer.current()).toEqual([{ type: "text", content: "old prompt", start: 0, end: 10 }])
    composer.set([{ type: "text", content: "edited prompt", start: 0, end: 13 }])
    expect(composer.current()[0]).toMatchObject({ content: "edited prompt" })

    const calls: string[] = []
    const sent = Promise.withResolvers<string>()
    const adapter: ActiveComposerAdapter = {
      kind: "active-session",
      state: composer.capture(),
      ready: () => true,
      controls,
      working: () => false,
      session: () => session({ calls, prompt: async (value) => sent.resolve(value.text) }),
      interrupt: async () => undefined,
      submissionBarrier: { pending: revert.pending, wait: revert.wait },
      submitted() {},
      setEditor() {},
    }
    const submitted = submitInput(adapter).submit(new Event("submit"))

    await listed.promise
    expect(calls).toEqual([])
    list.resolve([
      {
        id: "inbox-old",
        sessionID: "session-1",
        timeCreated: 0,
        type: "user",
        payload: { text: "old" },
        delivery: "queue",
      },
    ])
    await cancelling.promise
    expect(calls).toEqual([])

    cancel.resolve()
    await undo
    await submitted
    expect(await sent.promise).toBe("edited prompt")
    expect(calls.at(-1)).toBe("prompt")
  })
})
