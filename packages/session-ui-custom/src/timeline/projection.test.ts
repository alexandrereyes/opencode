import { describe, expect, test } from "bun:test"
import type {
  ModelRef,
  SessionMessageAssistant,
  SessionMessageAssistantTool,
  SessionMessageInfo,
} from "@opencode/client/promise"
import { createStore } from "solid-js/store"
import { timelinePresets, type TimelineDetail } from "./detail"
import { createTimelineProjection, reuseTimelineRows, Timeline, TimelineRow, type PartGroup } from "./projection"

const context = (key: string, partIDs: string[], identity: { userMessageID?: string; messageID?: string } = {}) =>
  new TimelineRow.AssistantPart({
    userMessageID: identity.userMessageID ?? "user-1",
    group: {
      key,
      type: "context",
      refs: partIDs.map((partID) => ({ messageID: identity.messageID ?? "assistant-1", partID })),
    } satisfies PartGroup,
    previousAssistantPart: false,
  })

const patch = (key: string, partIDs: string[], userMessageID = "user-1") =>
  new TimelineRow.AssistantPart({
    userMessageID,
    group: {
      key,
      type: "file",
      refs: partIDs.map((partID) => ({ messageID: "assistant-1", partID })),
    } satisfies PartGroup,
    previousAssistantPart: false,
  })

const part = (key: string, partID: string) =>
  new TimelineRow.AssistantPart({
    userMessageID: "user-1",
    group: {
      key,
      type: "part",
      ref: { messageID: "assistant-1", partID },
    } satisfies PartGroup,
    previousAssistantPart: false,
  })

const user = (userMessageID = "user-1") => new TimelineRow.UserMessage({ userMessageID })
const keys = (rows: TimelineRow.TimelineRow[]) => rows.map(TimelineRow.key)

describe("Timeline.resolveContent", () => {
  const assistant = (content: SessionMessageAssistant["content"]): SessionMessageAssistant => ({
    id: "assistant",
    type: "assistant",
    agent: "build",
    model: { id: "model", providerID: "provider" },
    content,
    time: { created: 0 },
  })
  const tool = (id: string): SessionMessageAssistantTool => ({
    id,
    type: "tool",
    name: "read",
    state: { status: "running", input: {}, metadata: {} },
    time: { created: 0 },
  })

  test("resolves interleaved ordinals and current store references", () => {
    const [store, setStore] = createStore({
      message: assistant([
        { type: "text", text: "" },
        { type: "reasoning", text: "", time: { created: 0 } },
        tool("read"),
        { type: "text", text: "answer" },
        { type: "reasoning", text: "thought", time: { created: 0 } },
      ]),
    })
    expect(Timeline.resolveContent(store.message, "assistant:text:0")).toBe(store.message.content[0])
    expect(Timeline.resolveContent(store.message, "assistant:reasoning:0")).toBe(store.message.content[1])
    expect(Timeline.resolveContent(store.message, "read")).toBe(store.message.content[2])
    expect(Timeline.resolveContent(store.message, "assistant:text:1")).toBe(store.message.content[3])
    expect(Timeline.resolveContent(store.message, "assistant:reasoning:1")).toBe(store.message.content[4])
    const original = store.message.content[3]
    setStore("message", "content", 3, { type: "text", text: "updated" })
    expect(Timeline.resolveContent(store.message, "assistant:text:1")).toBe(original)
    expect(Timeline.resolveContent(store.message, "assistant:text:1")).toMatchObject({ text: "updated" })

    setStore("message", "content", () => [{ type: "text" as const, text: "replacement" }, tool("replacement-tool")])
    expect(Timeline.resolveContent(store.message, "assistant:text:0")).toBe(store.message.content[0])
    expect(Timeline.resolveContent(store.message, "replacement-tool")).toBe(store.message.content[1])
    expect(Timeline.resolveContent(store.message, "read")).toBeUndefined()
    expect(Timeline.resolveContent(store.message, "assistant:text:1")).toBeUndefined()
  })

  test("stops reading as soon as the part is found", () => {
    const message = assistant([tool("first")])
    message.content.push({
      get type(): "text" {
        throw new Error("read past the matching part")
      },
      text: "later",
    })
    expect(Timeline.resolveContent(message, "first")).toBe(message.content[0])
  })
})

describe("reuseTimelineRows", () => {
  test.each([
    {
      name: "reuses an unchanged context group",
      previous: [context("context:a", ["a", "b"])],
      rows: [context("context:a", ["a", "b"])],
      expected: ["assistant-part:context:context:a"],
      reused: [[0, 0]],
    },
    {
      name: "preserves the group key when a member is appended",
      previous: [context("context:a", ["a"])],
      rows: [context("context:a", ["a", "b"])],
      expected: ["assistant-part:context:context:a"],
      reused: [],
    },
    {
      name: "preserves a patch group key when a member is appended",
      previous: [patch("patch:a", ["a"])],
      rows: [patch("patch:a", ["a", "b"])],
      expected: ["assistant-part:file:patch:a"],
      reused: [],
    },
    {
      name: "preserves the group key when the first member is removed",
      previous: [context("context:a", ["a", "b"])],
      rows: [context("context:b", ["b"])],
      expected: ["assistant-part:context:context:a"],
      reused: [],
    },
    {
      name: "lets only the natural owner retain an old key after a split",
      previous: [context("context:a", ["a", "b"])],
      rows: [context("context:a", ["a"]), context("context:b", ["b"])],
      expected: ["assistant-part:context:context:a", "assistant-part:context:context:b"],
      reused: [],
    },
    {
      name: "preserves the file group identity when its first member becomes standalone",
      previous: [patch("part:a", ["a", "b"])],
      rows: [part("part:a", "a"), patch("part:b", ["b"])],
      expected: ["assistant-part:part:part:a", "assistant-part:file:part:a"],
      reused: [],
    },
    {
      name: "preserves the file group identity before a later standalone member",
      previous: [patch("part:a", ["a", "b"])],
      rows: [patch("part:b", ["b"]), part("part:a", "a")],
      expected: ["assistant-part:file:part:a", "assistant-part:part:part:a"],
      reused: [],
    },
    {
      name: "chooses the earliest prior key when groups merge",
      previous: [context("context:a", ["a"]), context("context:b", ["b"])],
      rows: [context("context:b", ["b", "a"])],
      expected: ["assistant-part:context:context:a"],
      reused: [],
    },
    {
      name: "reserves an old key for its natural owner when two new groups compete",
      previous: [context("context:a", ["a", "b"])],
      rows: [context("context:b", ["b"]), context("context:a", ["a"])],
      expected: ["assistant-part:context:context:b", "assistant-part:context:context:a"],
      reused: [],
    },
    {
      // A history prepend can regroup a page-boundary turn under its real user
      // message; the same parts must keep their identity across that move.
      name: "reuses context identity when the same parts move to another user message",
      previous: [context("context:a", ["a", "b"], { userMessageID: "user-1" })],
      rows: [context("context:b", ["b"], { userMessageID: "user-2" })],
      expected: ["assistant-part:context:context:a"],
      reused: [],
    },
    {
      name: "does not reuse context identity across assistant messages",
      previous: [context("context:assistant-1:a", ["a"], { messageID: "assistant-1" })],
      rows: [context("context:assistant-2:a", ["a"], { messageID: "assistant-2" })],
      expected: ["assistant-part:context:context:assistant-2:a"],
      reused: [],
    },
    {
      name: "reuses an unaffected ordinary row",
      previous: [user()],
      rows: [user()],
      expected: ["user-message:user-1"],
      reused: [[0, 0]],
    },
    {
      name: "does not create accidental key collisions",
      previous: [context("context:a", ["a", "b", "c"])],
      rows: [context("context:b", ["b"]), context("context:a", ["a"]), context("context:c", ["c"])],
      expected: [
        "assistant-part:context:context:b",
        "assistant-part:context:context:a",
        "assistant-part:context:context:c",
      ],
      reused: [],
    },
  ])("$name", ({ previous, rows, expected, reused }) => {
    const result = reuseTimelineRows([...previous], [...rows])

    expect(keys(result)).toEqual([...expected])
    expect(new Set(keys(result)).size).toBe(result.length)
    reused.forEach(([resultIndex, previousIndex]) => expect(result[resultIndex]).toBe(previous[previousIndex]))
  })
})

describe("createTimelineProjection", () => {
  test.each([...timelinePresets])("omits idle markers while preserving notices in $id", (preset) => {
    const messages: SessionMessageInfo[] = [
      { id: "user-1", type: "user", text: "question", time: { created: 1 } },
      {
        id: "assistant-1",
        type: "assistant",
        agent: "build",
        model: { id: "model", providerID: "provider" },
        content: [{ type: "text", text: "answer" }],
        time: { created: 2, completed: 3 },
      },
      { id: "notice-1", type: "system", text: "Updated", description: "Updated", time: { created: 4 } },
    ]
    const project = (sessionMessages: SessionMessageInfo[]) =>
      createTimelineProjection({
        sessionMessages,
        status: { type: "idle" },
        reasoningMode: "full",
        timelineDetail: preset.value,
      }).rows
    const expected = project(messages)
    ;(["succeeded", "failed", "interrupted"] as const).forEach((outcome) => {
      expect(project([...messages, { id: "idle-1", type: "idle", outcome, time: { created: 5 } }])).toEqual(expected)
    })
  })

  test("builds current message, parent, context, and row indexes", () => {
    const selectedModel = { id: "selected", providerID: "provider" } satisfies ModelRef
    const assistantModel = { id: "assistant", providerID: "provider", variant: "fast" } satisfies ModelRef
    const messages = [
      { id: "agent", type: "agent-switched", agent: "explore", time: { created: 1 } },
      { id: "model", type: "model-switched", model: selectedModel, time: { created: 2 } },
      { id: "user-1", type: "user", text: "first", time: { created: 3 } },
      {
        id: "assistant-1",
        type: "assistant",
        agent: "build",
        model: assistantModel,
        content: [{ type: "text", text: "answer" }],
        time: { created: 4, completed: 5 },
      },
      {
        id: "user-2",
        type: "user",
        text: "second",
        metadata: {
          agent: "review",
          model: { modelID: "override", providerID: "custom", variant: "precise" },
        },
        time: { created: 6 },
      },
    ] satisfies SessionMessageInfo[]

    const result = createTimelineProjection({
      sessionMessages: messages,
      status: { type: "busy" },
      reasoningMode: "full",
    })

    expect(result.activeMessageID).toBe("user-2")
    expect(result.messageByID).toBe(result.sessionMessageByID)
    expect(result.sessionMessageByID.get("assistant-1")).toBe(messages[3])
    expect(result.assistantMessagesByParent.get("user-1")?.map((message) => message.id)).toEqual(["assistant-1"])
    expect(result.assistantMessagesByParent.has("user-2")).toBe(false)
    expect(result.userContextByID.get("user-1")).toEqual({ agent: "build", model: assistantModel })
    expect(result.userContextByID.get("user-2")).toEqual({
      agent: "review",
      model: { id: "override", providerID: "custom", variant: "precise" },
    })
    expect(result.messageRowIndex.get("user-1")).toBe(0)
    expect(result.messageLastRowIndex.get("user-1")).toBe(3)
    expect(result.lastAssistantGroupKey.get("user-1")).toBe("part:assistant-1:assistant-1:text:0")
    expect(result.rowByKey.get("user-message:user-1")).toBe(result.rows[2])
  })

  describe("final answer divider", () => {
    const assistant = (
      id: string,
      text: string,
      options: { finish?: SessionMessageAssistant["finish"]; phase?: string; completed?: boolean } = {},
    ): SessionMessageAssistant => ({
      id,
      type: "assistant",
      agent: "build",
      model: { id: "model", providerID: "provider" },
      finish: options.finish,
      content: [{ type: "text", text, ...(options.phase ? { state: { phase: options.phase } } : {}) }],
      time: { created: 2, ...(options.completed === false ? {} : { completed: 3 }) },
    })
    const project = (entries: SessionMessageInfo[], detail: TimelineDetail = timelinePresets[0].value) =>
      createTimelineProjection({
        sessionMessages: [{ id: "user-1", type: "user", text: "question", time: { created: 1 } }, ...entries],
        status: { type: "idle" },
        reasoningMode: "full",
        timelineDetail: detail,
      }).rows

    test("preserves the first divider and separates the answer after late activity", () => {
      const rows = project([
        assistant("assistant-commentary", "Checking the repository.", { finish: "tool-calls" }),
        assistant("assistant-final-1", "My understanding: the issue is confirmed.", {
          finish: "stop",
          phase: "final_answer",
        }),
        {
          id: "notice-late",
          type: "synthetic",
          text: "The subagent completed.",
          description: "Late result",
          metadata: { source: "subagent", state: "completed" },
          time: { created: 4 },
        },
        assistant("assistant-final-2", "The last agent added another detail.", {
          finish: "stop",
          phase: "final_answer",
        }),
      ])

      expect(keys(rows)).toEqual([
        "user-message:user-1",
        "assistant-part:part:part:assistant-commentary:assistant-commentary:text:0",
        "final-answer-divider:assistant-final-1:assistant-final-1:text:0",
        "assistant-part:part:part:assistant-final-1:assistant-final-1:text:0",
        "notice:notice-late",
        "final-answer-divider:assistant-final-2:assistant-final-2:text:0",
        "assistant-part:part:part:assistant-final-2:assistant-final-2:text:0",
      ])
      expect(rows[2]).toMatchObject({ _tag: "FinalAnswerDivider", spacing: "content" })
      expect(rows[3]).toMatchObject({ _tag: "AssistantPart", spacing: undefined })
    })

    test("explicit phases take precedence over an earlier legacy stop", () => {
      const rows = project([
        assistant("assistant-legacy", "A completed commentary message.", { finish: "stop" }),
        assistant("assistant-final", "The explicit final answer.", { finish: "stop", phase: "final_answer" }),
      ])

      expect(rows.findIndex((row) => row._tag === "FinalAnswerDivider")).toBe(2)
      expect(keys(rows)[3]).toContain("assistant-final")
    })

    for (const phase of [undefined, "final_answer"]) {
      for (const activity of ["tool", "reasoning", "commentary"] as const) {
        test(`separates repeated ${phase ?? "legacy"} conclusions after ${activity}`, () => {
          const work = assistant("resumed", "More work", { finish: "tool-calls" })
          if (activity === "commentary") {
            work.finish = phase ? "stop" : "tool-calls"
            work.content = [{ type: "text", text: "Checking again", state: { phase: "commentary" } }]
          }
          if (activity === "reasoning") work.content = [{ type: "reasoning", text: "Thinking again" }]
          if (activity === "tool")
            work.content = [
              {
                type: "tool",
                id: "tool-resumed",
                name: "shell",
                time: { created: 3, completed: 4 },
                state: { status: "completed", input: { command: "true" }, content: [{ type: "text", text: "Done" }] },
              },
            ]
          const rows = project([
            assistant("work", "Working", { finish: "tool-calls" }),
            assistant("first", "First answer", { finish: "stop", phase }),
            work,
            assistant("second", "Second answer", { finish: "stop", phase }),
          ])
          expect(rows.filter((row) => row._tag === "FinalAnswerDivider").map((row) => row.ref.messageID)).toEqual([
            "first",
            "second",
          ])
          expect(new Set(keys(rows)).size).toBe(rows.length)
        })
      }
    }

    test("does not duplicate a boundary for consecutive explicit final messages or parts", () => {
      const first = assistant("first", "First answer", { finish: "stop", phase: "final_answer" })
      first.content.push({ type: "text", text: "More answer", state: { phase: "final_answer" } })
      const rows = project([
        assistant("work", "Working", { finish: "tool-calls" }),
        first,
        assistant("second", "Another answer", { finish: "stop", phase: "final_answer" }),
      ])
      expect(rows.filter((row) => row._tag === "FinalAnswerDivider").map((row) => row.ref.partID)).toEqual([
        "first:text:0",
      ])
    })

    test("uses the last completed stop with visible text when the turn has no phases", () => {
      const rows = project([
        assistant("assistant-activity", "Working on it.", { finish: "tool-calls" }),
        assistant("assistant-stop-1", "First completed answer.", { finish: "stop" }),
        assistant("assistant-stop-2", "Later completed answer.", { finish: "stop" }),
      ])

      expect(rows.findIndex((row) => row._tag === "FinalAnswerDivider")).toBe(3)
      expect(keys(rows)[4]).toContain("assistant-stop-2")
    })

    test("keeps legacy fallback when an explicit non-final phase is present", () => {
      const rows = project([
        assistant("assistant-activity", "Working on it.", { finish: "tool-calls" }),
        assistant("assistant-stop", "Commentary stop.", { finish: "stop" }),
        assistant("assistant-phase", "Still commentary.", { finish: "stop", phase: "commentary" }),
      ])

      expect(rows.findIndex((row) => row._tag === "FinalAnswerDivider")).toBe(3)
      expect(keys(rows)[4]).toContain("assistant-phase")
    })

    const boundary = (entries: SessionMessageInfo[]) => {
      const rows = project(entries)
      const dividers = rows.filter((row) => row._tag === "FinalAnswerDivider")
      expect(dividers.length).toBeLessThanOrEqual(1)
      const index = rows.findIndex((row) => row._tag === "FinalAnswerDivider")
      const next = rows[index + 1]
      return index >= 0 && next?._tag === "AssistantPart" && next.group.type === "part" ? next.group.ref : undefined
    }

    test("skips an explicit answer without preceding activity when a later answer completes", () => {
      const entries: SessionMessageInfo[] = [
        assistant("first", "Standalone", { finish: "stop", phase: "final_answer" }),
      ]
      expect(boundary(entries)).toBeUndefined()
      entries.push(assistant("work", "More work", { finish: "tool-calls" }))
      expect(boundary(entries)).toBeUndefined()
      const answer = assistant("answer", "Final", { phase: "final_answer", completed: false })
      entries.push(answer)
      expect(boundary(entries)).toBeUndefined()
      answer.finish = "stop"
      answer.time.completed = 5
      const expected = { messageID: "answer", partID: "answer:text:0" }
      expect(boundary(entries)).toEqual(expected)
      entries.push(assistant("later", "Later", { finish: "stop", phase: "final_answer" }))
      expect(boundary(entries)).toEqual(expected)
    })

    for (const phase of [undefined, "final_answer"]) {
      test(`requires a successful completed stop for ${phase ?? "legacy"} text`, () => {
        const answer = assistant("answer", "Answer", { finish: "stop", phase })
        const entries = [assistant("work", "Working", { finish: "tool-calls" }), answer]
        expect(boundary(entries)?.messageID).toBe("answer")
        answer.time.completed = undefined
        expect(boundary(entries)).toBeUndefined()
        answer.time.completed = 3
        for (const finish of [undefined, "tool-calls", "length", "error"] as const) {
          answer.finish = finish
          expect(boundary(entries)).toBeUndefined()
        }
        answer.finish = "stop"
        answer.error = { type: "Error", message: "Failed" }
        expect(boundary(entries)).toBeUndefined()
        answer.error = undefined
        expect(boundary(entries)?.messageID).toBe("answer")
        answer.retry = { attempt: 1, at: 10, error: { type: "ProviderError", message: "Retry" } }
        expect(boundary(entries)).toBeUndefined()
        answer.retry = undefined
        expect(boundary(entries)?.messageID).toBe("answer")
      })
    }

    test("places the explicit boundary between individual text parts in the same message", () => {
      const answer = assistant("answer", "", { finish: "stop" })
      answer.content = [
        { type: "text", text: "   ", state: { phase: "final_answer" } },
        { type: "text", text: "Commentary", state: { phase: "commentary" } },
        { type: "text", text: "Final", state: { phase: "final_answer" } },
      ]
      expect(boundary([answer])).toEqual({ messageID: "answer", partID: "answer:text:2" })
    })

    for (const resumed of [false, true]) {
      test(`does not count hidden activity before ${resumed ? "a repeated" : "the first"} final answer`, () => {
        const reasoning: SessionMessageAssistant = {
          ...assistant("assistant-reasoning", "", { finish: "tool-calls" }),
          content: [{ type: "reasoning", text: "Hidden thought", time: { created: 2, completed: 3 } }],
        }
        const notice: SessionMessageInfo = {
          id: "notice-hidden",
          type: "synthetic",
          text: "Hidden notice",
          description: "Hidden notice",
          time: { created: 3 },
        }
        const rows = project(
          [
            ...(resumed
              ? [
                  assistant("work", "Working", { finish: "tool-calls" }),
                  assistant("first", "First answer", { finish: "stop", phase: "final_answer" }),
                ]
              : []),
            reasoning,
            notice,
            assistant("assistant-final", "Only visible content.", { finish: "stop", phase: "final_answer" }),
          ],
          timelinePresets[4].value,
        )

        expect(rows.filter((row) => row._tag === "FinalAnswerDivider").map((row) => row.ref.messageID)).toEqual(
          resumed ? ["first"] : [],
        )
      })
    }

    for (const failure of [
      { error: { type: "Error", message: "Failed" } },
      { retry: { attempt: 1, at: 10, error: { type: "ProviderError", message: "Retry" } } },
    ]) {
      test(`keeps only the first divider when a resumed answer has ${"error" in failure ? "an error" : "a retry"}`, () => {
        const second = assistant("second", "Second answer", { finish: "stop", phase: "final_answer" })
        const entries = [
          assistant("work", "Working", { finish: "tool-calls" }),
          assistant("first", "First answer", { finish: "stop", phase: "final_answer" }),
          assistant("resumed", "Checking again", { finish: "tool-calls" }),
          { ...second, ...failure },
        ]
        expect(boundary(entries)).toEqual({ messageID: "first", partID: "first:text:0" })
        entries[3] = second
        expect(
          project(entries)
            .filter((row) => row._tag === "FinalAnswerDivider")
            .map((row) => row.ref.messageID),
        ).toEqual(["first", "second"])
      })
    }

    test("keeps a grouped visible notice on the activity side of the boundary", () => {
      const rows = project(
        [
          {
            id: "notice-grouped",
            type: "synthetic",
            text: "Visible notice",
            description: "Visible notice",
            time: { created: 2 },
          },
          assistant("assistant-final", "Final answer.", { finish: "stop", phase: "final_answer" }),
        ],
        timelinePresets[2].value,
      )

      expect(keys(rows)).toEqual([
        "user-message:user-1",
        "assistant-part:context:message:notice-grouped",
        "final-answer-divider:assistant-final:assistant-final:text:0",
        "assistant-part:part:part:assistant-final:assistant-final:text:0",
      ])
    })
  })

  test("reuses a stable projected row array", () => {
    const messages = [
      { id: "user-1", type: "user", text: "first", time: { created: 1 } },
      {
        id: "assistant-1",
        type: "assistant",
        agent: "build",
        model: { id: "model", providerID: "provider" },
        content: [{ type: "text", text: "answer" }],
        time: { created: 2, completed: 3 },
      },
    ] satisfies SessionMessageInfo[]
    const first = createTimelineProjection({
      sessionMessages: messages,
      status: { type: "idle" },
      reasoningMode: "full",
    })
    const second = createTimelineProjection({
      sessionMessages: messages,
      status: { type: "idle" },
      reasoningMode: "full",
      previousRows: first.rows,
    })

    expect(second.rows).toBe(first.rows)
    expect(second.rows[0]).toBe(first.rows[0])
    expect(second.rows[1]).toBe(first.rows[1])
  })

  test("indexes a leading partial assistant turn under its projected turn ID", () => {
    const messages = [
      {
        id: "assistant-1",
        type: "assistant",
        agent: "build",
        model: { id: "model", providerID: "provider" },
        content: [{ type: "text", text: "partial answer" }],
        time: { created: 2, completed: 3 },
      },
      {
        id: "assistant-2",
        type: "assistant",
        agent: "build",
        model: { id: "model", providerID: "provider" },
        content: [{ type: "text", text: "final answer" }],
        time: { created: 4, completed: 5 },
      },
    ] satisfies SessionMessageInfo[]

    const result = createTimelineProjection({
      sessionMessages: messages,
      status: { type: "idle" },
      reasoningMode: "full",
    })

    expect(result.assistantMessagesByParent.get("assistant-1")?.map((message) => message.id)).toEqual([
      "assistant-1",
      "assistant-2",
    ])
  })
})
