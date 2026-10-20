import { Plugin } from "@opencode/plugin/effect"
import { SessionMessage } from "@opencode/schema/session-message"
import { Effect, Schema } from "effect"
import { omitInlineMedia, Transcript } from "./rpc.js"

const encodePage = Schema.encodeSync(Transcript.Page)

export const registerTranscript = Effect.fn("Transcript.register")(function* (ctx: Plugin.Context) {
  yield* ctx.rpc
    .register(Transcript.Definition, {
      list: (input, context) =>
        list(ctx.message, input).pipe(
          Effect.mapError(() =>
            context.error("read_failed", "Unable to read session messages", { sessionID: input.sessionID }),
          ),
        ),
    })
    .pipe(Effect.orDie)
})

/** The same page as `GET /api/session/:sessionID/message`, without inline tool-result media. */
export const list = Effect.fn("Transcript.list")(function* (
  messages: Plugin.Context["message"],
  input: typeof Transcript.ListInput.Type,
) {
  const page = yield* messages.list(input)
  return encodePage({ data: page.data.map(leanMessage), cursor: page.cursor })
})

function leanMessage(message: SessionMessage.Info): SessionMessage.Info {
  if (message.type !== "assistant") return message
  return { ...message, content: message.content.map((part) => (part.type === "tool" ? leanTool(part) : part)) }
}

function leanTool(tool: SessionMessage.AssistantTool): SessionMessage.AssistantTool {
  if ((tool.state.status !== "completed" && tool.state.status !== "error") || !tool.state.content) return tool
  return { ...tool, state: { ...tool.state, content: omitInlineMedia(tool.state.content) } }
}
