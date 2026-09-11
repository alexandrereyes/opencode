import type { SessionMessageAssistant, SessionMessageInfo } from "@opencode/client/promise"
import { AssistantTextContent } from "./message-content"
import { CurrentSessionProviders } from "../storybook/current-session-story"
import { CURRENT_SESSION_ID } from "../storybook/current-session-fixtures"
import { SessionTimeline } from "../timeline/session-timeline"

export default {
  title: "OpenCode/Conversation/Inference footer",
  id: "inference-footer",
  component: AssistantTextContent,
}

const message = {
  id: "message_inference_footer",
  type: "assistant",
  agent: "build",
  model: { providerID: "anthropic", id: "claude-sonnet-4", variant: "high" },
  content: [{ type: "text", text: "The inference details remain visible below the response." }],
  tokens: { input: 1000, output: 200, reasoning: 0, cache: { read: 0, write: 0 } },
  time: {
    created: new Date(2026, 8, 10, 17, 19).getTime(),
    streamed: new Date(2026, 8, 10, 17, 19, 4).getTime(),
    completed: new Date(2026, 8, 10, 17, 19, 4).getTime(),
  },
} satisfies SessionMessageAssistant

export const Completed = {
  render: () => (
    <CurrentSessionProviders
      document={{ sessionID: CURRENT_SESSION_ID, messages: [message], status: { type: "idle" }, diffs: [] }}
    >
      <AssistantTextContent id={message.id} message={message} text={message.content[0].text} showCopy />
    </CurrentSessionProviders>
  ),
}

const input = {
  id: "message_footer_user",
  type: "user",
  text: "Check the project and summarize the result.",
  time: { created: message.time.created - 30_000 },
} satisfies SessionMessageInfo

const first = {
  ...message,
  id: "message_footer_first",
  finish: "tool-calls",
  tokens: { ...message.tokens, output: 40, reasoning: 1000 },
  time: {
    created: message.time.created - 29_000,
    streamed: message.time.created - 27_000,
    completed: message.time.created - 10_000,
  },
  content: [
    {
      type: "tool",
      id: "tool_footer_read",
      name: "read",
      state: { status: "completed", input: { filePath: "package.json" }, output: "{}", metadata: {} },
      time: { created: message.time.created - 27_000, completed: message.time.created - 10_000 },
    },
  ],
} satisfies SessionMessageAssistant

export const MultiStep = {
  render: () => <FooterTimeline messages={[input, first, message]} />,
}

export const SyntheticInput = {
  render: () => (
    <FooterTimeline
      messages={[
        input,
        first,
        {
          id: "message_footer_synthetic",
          type: "synthetic",
          text: "Continue with the summary.",
          time: { created: message.time.created - 8_000 },
        },
        message,
      ]}
    />
  ),
}

export const MissingStream = {
  render: () => (
    <FooterTimeline messages={[input, { ...first, time: { ...first.time, streamed: undefined } }, message]} />
  ),
}

function FooterTimeline(props: { messages: SessionMessageInfo[] }) {
  const document = () => ({
    sessionID: CURRENT_SESSION_ID,
    messages: props.messages,
    status: { type: "idle" as const },
    diffs: [],
  })
  return (
    <CurrentSessionProviders document={document()}>
      <SessionTimeline document={document()} />
    </CurrentSessionProviders>
  )
}
