import { expect, test } from "bun:test"
import type { SessionMessageAssistant, SessionMessageInfo } from "@opencode/client/promise"
import { createRoot } from "solid-js"
import { createStore, produce } from "solid-js/store"
import { createReactiveTimelineProjection } from "../projection"

function assistant(id: string, phase?: string): SessionMessageAssistant {
  return {
    id,
    type: "assistant",
    agent: "build",
    model: { id: "model", providerID: "provider" },
    time: { created: 2 },
    content: [{ type: "text", text: id, ...(phase ? { state: { phase } } : {}) }],
  }
}

function fixture(phase?: string) {
  const [state, setState] = createStore({
    work: assistant("work", "commentary"),
    answer: assistant("answer", phase),
    late: assistant("late", phase),
    notices: [] as SessionMessageInfo[],
    showLate: false,
  })
  const projection = createReactiveTimelineProjection({
    sessionMessages: () => [
      { id: "user", type: "user", text: "Question", time: { created: 1 } },
      state.work,
      state.answer,
      ...state.notices,
      ...(state.showLate ? [state.late] : []),
    ],
    status: () => ({ type: "busy" }),
    reasoningMode: () => "full",
  })
  const boundary = () => {
    const rows = projection.rows()
    expect(rows.filter((row) => row._tag === "FinalAnswerDivider").length).toBeLessThanOrEqual(1)
    const index = rows.findIndex((row) => row._tag === "FinalAnswerDivider")
    const next = rows[index + 1]
    return index >= 0 && next?._tag === "AssistantPart" && next.group.type === "part"
      ? next.group.ref.messageID
      : undefined
  }
  return { setState, projection, boundary }
}

test("explicit phase waits for completion and remains anchored through late activity", () => {
  createRoot((dispose) => {
    try {
      const view = fixture("final_answer")
      expect(view.boundary()).toBeUndefined()
      view.setState("answer", "finish", "stop")
      expect(view.boundary()).toBeUndefined()
      view.setState("answer", "time", "completed", 3)
      expect(view.boundary()).toBe("answer")
      view.setState("answer", "content", 0, produce((content) => {
        expect(content.type).toBe("text")
        if (content.type === "text") content.text = "   "
      }))
      expect(view.boundary()).toBeUndefined()
      view.setState("answer", "content", 0, produce((content) => {
        expect(content.type).toBe("text")
        if (content.type === "text") content.text = "Final answer"
      }))
      expect(view.boundary()).toBe("answer")
      const divider = view.projection.rowByKey().get("final-answer-divider:user")
      view.setState("notices", [
        {
          id: "notice",
          type: "synthetic",
          text: "Subagent completed",
          metadata: { source: "subagent", state: "completed" },
          time: { created: 4 },
        },
      ])
      expect(view.boundary()).toBe("answer")
      view.setState("showLate", true)
      expect(view.boundary()).toBe("answer")
      view.setState("late", "finish", "stop")
      expect(view.boundary()).toBe("answer")
      view.setState("late", "time", "completed", 5)
      expect(view.boundary()).toBe("answer")
      expect(view.projection.rowByKey().get("final-answer-divider:user")).toBe(divider)
    } finally {
      dispose()
    }
  })
})

test("mixed metadata fallback advances only on completion and reacts to phase changes", () => {
  createRoot((dispose) => {
    try {
      const view = fixture()
      expect(view.boundary()).toBeUndefined()
      view.setState("answer", "finish", "stop")
      expect(view.boundary()).toBeUndefined()
      view.setState("answer", "time", "completed", 3)
      expect(view.boundary()).toBe("answer")
      view.setState("showLate", true)
      expect(view.boundary()).toBe("answer")
      view.setState("late", "finish", "stop")
      expect(view.boundary()).toBe("answer")
      view.setState("late", "time", "completed", 4)
      expect(view.boundary()).toBe("late")
      view.setState("answer", "content", 0, "state", { phase: "commentary" })
      expect(view.boundary()).toBe("late")
      view.setState("answer", "content", 0, "state", { phase: "final_answer" })
      expect(view.boundary()).toBe("answer")
      view.setState("answer", "content", 0, "state", { phase: "commentary" })
      expect(view.boundary()).toBe("late")
    } finally {
      dispose()
    }
  })
})
