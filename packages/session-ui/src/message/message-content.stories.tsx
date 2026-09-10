import type { SessionMessageAssistant } from "@opencode/client/promise"
import { AssistantTextContent } from "./message-content"
import { CurrentSessionProviders } from "../storybook/current-session-story"
import { CURRENT_SESSION_ID } from "../storybook/current-session-fixtures"

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
