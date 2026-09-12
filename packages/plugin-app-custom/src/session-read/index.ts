import { MessagePage } from "@opencode/plugin/message"
import { Plugin } from "@opencode/plugin/effect"
import { AbsolutePath, PositiveInt } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Tool } from "@opencode/schema/tool"
import { Effect, Schema } from "effect"

export const ReadInput = Schema.Struct({
  sessionID: Session.ID,
  limit: Schema.optionalKey(PositiveInt.check(Schema.isLessThanOrEqualTo(50))).annotate({
    description: "Maximum number of messages to return. Defaults to 20 and cannot exceed 50.",
  }),
  cursor: Schema.optionalKey(SessionMessage.ID).annotate({
    description: "The next cursor from a previous call, used to read older messages.",
  }),
})

const ReadMessage = Schema.Struct({
  id: SessionMessage.ID,
  type: Schema.String,
  text: Schema.String,
  truncated: Schema.optionalKey(Schema.Boolean),
})

export const ReadOutput = Schema.Struct({
  session: Schema.Struct({ id: Session.ID, title: Schema.optionalKey(Schema.String), directory: AbsolutePath }),
  messages: Schema.Array(ReadMessage),
  next: Schema.optionalKey(SessionMessage.ID),
})

const MaxReadCharacters = 20_000

export const registerSessionRead = Effect.fn("SessionRead.register")(function* (ctx: Plugin.Context) {
  yield* ctx.tool
    .transform((draft) => {
      draft.namespace({ name: "opencode", description: "OpenCode session and runtime tools." })
      draft.add({
        name: "session_read",
        description:
          "Read a bounded page of an existing OpenCode session. Results are newest-first, contain compact textual message content, and cap returned message text at 20,000 characters. Pass next as cursor to read older messages.",
        input: ReadInput,
        output: ReadOutput,
        options: { namespace: "opencode", codemode: true },
        execute: (input) =>
          Effect.gen(function* () {
            const session = yield* ctx.session.get({ sessionID: input.sessionID })
            const limit = input.limit ?? 20
            const page = yield* ctx.message.list({
              sessionID: input.sessionID,
              limit,
              ...(input.cursor
                ? { cursor: MessagePage.Cursor.make({ id: input.cursor, order: "desc", direction: "next" }) }
                : {}),
            })
            const compact = page.data.reduce(
              (result, message) => {
                if (result.exhausted) return result
                const text = sessionMessageText(message)
                if (!text) return { ...result, cursor: message.id }
                const remaining = MaxReadCharacters - result.size
                if (remaining <= 0) return { ...result, exhausted: true }
                const value = text.slice(0, remaining)
                return {
                  messages: [
                    ...result.messages,
                    {
                      id: message.id,
                      type: message.type,
                      text: value,
                      ...(value.length < text.length ? { truncated: true } : {}),
                    },
                  ],
                  size: result.size + value.length,
                  cursor: message.id,
                  exhausted: value.length < text.length || result.size + value.length >= MaxReadCharacters,
                }
              },
              {
                messages: [] as Array<typeof ReadMessage.Type>,
                size: 0,
                cursor: undefined as SessionMessage.ID | undefined,
                exhausted: false,
              },
            )
            const output = {
              session: {
                id: session.id,
                ...(session.title ? { title: session.title } : {}),
                directory: session.location.directory,
              },
              messages: compact.messages,
              ...(compact.cursor && (compact.exhausted || page.data.length === limit) ? { next: compact.cursor } : {}),
            }
            return { output, content: JSON.stringify(output) }
          }).pipe(
            Effect.mapError((error) => new Tool.Error({ message: `Unable to read session ${input.sessionID}`, error })),
          ),
      })
    })
    .pipe(Effect.orDie)
})

function sessionMessageText(message: SessionMessage.Info) {
  if (message.type === "user" || message.type === "synthetic" || message.type === "system" || message.type === "skill")
    return message.text
  if (message.type === "assistant")
    return message.content
      .flatMap((part) => {
        if (part.type === "text") return [part.text]
        if (part.type === "tool") return [`[tool ${part.name}: ${part.state.status}]`]
        return []
      })
      .join("\n")
  if (message.type === "shell") return `$ ${message.command}`
  if (message.type === "compaction" && message.status !== "failed") return message.summary
  return ""
}
