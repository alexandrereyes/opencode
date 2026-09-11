import type { SessionMessageAssistant } from "@opencode/client/promise"
import { For, createMemo } from "solid-js"
import { createStore } from "solid-js/store"
import type { SessionDocument } from "../document"
import { CURRENT_SESSION_ID, STORY_MODEL, STORY_TIME } from "../storybook/current-session-fixtures"
import { CurrentSessionProviders } from "../storybook/current-session-story"
import { SessionTimeline } from "./session-timeline"
import { timelinePresets, type TimelinePlacement } from "./detail"
import { createReactiveTimelineProjection, TimelineRow } from "./projection"
import { createSessionTimelineRowRenderer } from "./session-timeline-row"

export default {
  title: "OpenCode/Conversation/Final answer",
  id: "current-session-final-answer",
  component: SessionTimeline,
  parameters: { layout: "fullscreen" },
}

export const Divider = {
  args: { earlier: "tool", completed: true, finish: "stop", hideReasoning: false, notices: "separate" },
  argTypes: {
    earlier: { control: "select", options: ["tool", "text", "reasoning", "notice", "none"] },
    finish: { control: "select", options: ["stop", "tool-calls", "length", "error"] },
    notices: { control: "select", options: ["separate", "grouped", "hidden"] },
  },
  render: (args: {
    earlier: string
    completed: boolean
    finish: SessionMessageAssistant["finish"]
    hideReasoning: boolean
    notices: TimelinePlacement
  }) => <FinalAnswerStory {...args} />,
}

function FinalAnswerStory(props: {
  earlier: string
  completed: boolean
  finish: SessionMessageAssistant["finish"]
  hideReasoning: boolean
  notices: TimelinePlacement
}) {
  const [state, setState] = createStore({ completed: props.completed })
  const document = createMemo(
    (): SessionDocument => ({
      sessionID: CURRENT_SESSION_ID,
      status: { type: state.completed ? "idle" : "busy" },
      diffs: [],
      messages: [
        {
          id: "msg_final_user",
          type: "user",
          text: "Check the project and summarize what you found.",
          time: { created: STORY_TIME },
        },
        ...(props.earlier === "tool" || props.earlier === "text"
          ? [
              {
                id: "msg_final_activity",
                type: "assistant" as const,
                agent: "build",
                model: STORY_MODEL,
                finish: "tool-calls" as const,
                time: { created: STORY_TIME + 100, completed: STORY_TIME + 200 },
                content:
                  props.earlier === "text"
                    ? [{ type: "text" as const, text: "I will inspect the project configuration." }]
                    : [
                        {
                          type: "tool" as const,
                          id: "tool_final_read",
                          name: "read",
                          state: {
                            status: "completed" as const,
                            input: { filePath: "package.json" },
                            output: "{}",
                            metadata: {},
                          },
                          time: { created: STORY_TIME + 100, completed: STORY_TIME + 200 },
                        },
                      ],
              },
            ]
          : []),
        ...(props.earlier === "notice"
          ? [
              {
                id: "msg_final_notice",
                type: "synthetic" as const,
                text: "The subagent completed its inspection.",
                description: "Project inspection",
                metadata: { source: "subagent", state: "completed", agent: "explore" },
                time: { created: STORY_TIME + 200 },
              },
            ]
          : []),
        {
          id: "msg_final_answer",
          type: "assistant",
          agent: "build",
          model: STORY_MODEL,
          finish: state.completed ? props.finish : undefined,
          time: { created: STORY_TIME + 300, ...(state.completed ? { completed: STORY_TIME + 400 } : {}) },
          content: [
            ...(props.earlier === "reasoning"
              ? [
                  {
                    type: "reasoning" as const,
                    text: "Checking the project configuration.",
                    time: { created: STORY_TIME + 300, completed: STORY_TIME + 350 },
                  },
                ]
              : []),
            { type: "text", text: "   " },
            { type: "text", text: "The project configuration is consistent." },
            { type: "text", text: "No changes are needed." },
          ],
        },
      ],
    }),
  )
  const detail = () => ({
    ...timelinePresets[0].value,
    thinking: {
      placement: props.hideReasoning ? ("hidden" as const) : ("separate" as const),
      details: "collapsed" as const,
    },
    tools: { placement: "grouped" as const },
    notices: { placement: props.notices },
  })
  function Timeline() {
    const projection = createReactiveTimelineProjection({
      sessionMessages: () => document().messages,
      status: () => document().status,
      reasoningMode: () => "compact",
      timelineDetail: detail,
    })
    const [disclosure, setDisclosure] = createStore<Record<string, boolean>>({})
    const renderer = createSessionTimelineRowRenderer({
      sessionID: () => CURRENT_SESSION_ID,
      status: () => document().status,
      projection,
      presentation: () => undefined,
      reasoningMode: () => "compact",
      shellToolDefaultOpen: () => false,
      editToolDefaultOpen: () => false,
      timelineDetail: detail,
      disclosure: { value: (key) => disclosure[key], set: (key, open) => setDisclosure(key, open) },
    })
    const keys = createMemo(() => projection.rows().map(TimelineRow.key))
    return (
      <div data-component="session-timeline">
        <For each={keys()}>{(key) => <renderer.Row row={() => projection.rowByKey().get(key)!} />}</For>
      </div>
    )
  }
  return (
    <section class="mx-auto flex w-full max-w-[840px] flex-col gap-4 p-6">
      <button type="button" onClick={() => setState("completed", (value) => !value)}>
        {state.completed ? "Stream response" : "Complete response"}
      </button>
      <CurrentSessionProviders document={document()}>
        <Timeline />
      </CurrentSessionProviders>
    </section>
  )
}
