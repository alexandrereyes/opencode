export * as OpenCodeTools from "./opencode.js"

import { SystemPart, ToolFailure } from "@opencode/ai"
import type { Context } from "@opencode/plugin/effect/plugin"
import { AbsolutePath, PositiveInt } from "@opencode/schema/schema"
import { Effect, Schema } from "effect"
import { Session } from "../../session.js"
import { SessionMessage } from "../../session/message.js"

export const RenameInput = Schema.Struct({
  sessionID: Schema.optionalKey(Session.ID).annotate({ description: "Omit to rename the current session." }),
  title: Schema.String.check(Schema.isMinLength(1)).annotate({ description: "New session title." }),
})

const RenameOutput = Schema.Struct({ sessionID: Session.ID, title: Schema.String })

export const MoveInput = Schema.Struct({
  sessionID: Schema.optionalKey(Session.ID).annotate({ description: "Omit to move the current session." }),
  directory: AbsolutePath.check(Schema.isMinLength(1)).annotate({
    description: "Destination directory, relative to the target session's directory or absolute. Supports ~.",
  }),
})

const MoveOutput = Schema.Struct({ sessionID: Session.ID, directory: AbsolutePath })

const ReadInput = Schema.Struct({
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

export const Plugin = {
  id: "opencode.tools",
  effect: Effect.fn("OpenCodeTools.Plugin")(function* (ctx: Context) {
    const sessions = yield* Session.Service
    yield* ctx.session.hook("context", (event) =>
      Effect.sync(() => {
        event.system.push(
          SystemPart.make(
            "When you create a worktree outside the current working directory and intend to use it as your primary working directory, consider using `execute` to call `tools.opencode.session_move` and make the worktree the session's working directory.",
          ),
        )
      }),
    )
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
              const session = yield* sessions.get(input.sessionID)
              const limit = input.limit ?? 20
              const page = yield* sessions.messages({
                sessionID: input.sessionID,
                order: "desc",
                limit,
                ...(input.cursor ? { cursor: { id: input.cursor, direction: "next" } } : {}),
              })
              const compact = page.reduce(
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
                ...(compact.cursor && (compact.exhausted || page.length === limit) ? { next: compact.cursor } : {}),
              }
              return { output, content: JSON.stringify(output) }
            }).pipe(
              Effect.mapError(
                (error) => new ToolFailure({ message: `Unable to read session ${input.sessionID}`, error }),
              ),
            ),
        })
        draft.add({
          name: "session_rename",
          description:
            "Rename a session, or omit sessionID to rename the current session. Use a short, specific title that summarizes the work being done.",
          input: RenameInput,
          output: RenameOutput,
          options: { namespace: "opencode", codemode: true },
          execute: (input, context) => {
            const sessionID = input.sessionID ?? context.sessionID
            const title = input.title.trim()
            if (!title) return Effect.fail(new ToolFailure({ message: "Session title must not be empty" }))
            return ctx.session.rename({ sessionID, title }).pipe(
              Effect.as({
                output: { sessionID, title },
                content: `Renamed session ${sessionID} to ${title}.`,
              }),
              Effect.mapError((error) => new ToolFailure({ message: `Unable to rename session ${sessionID}`, error })),
            )
          },
        })
        draft.add({
          name: "session_move",
          description:
            "Move a session to another directory, or omit sessionID to move the current session. The current session moves at the next safe boundary; do not run destination-dependent tools in the same execute call.",
          input: MoveInput,
          output: MoveOutput,
          options: { namespace: "opencode", codemode: true, pinned: true },
          execute: (input, context) =>
            Effect.gen(function* () {
              const sessionID = input.sessionID ?? context.sessionID
              yield* ctx.session.move({
                sessionID,
                directory: input.directory,
                delivery: "steer",
              })
              return {
                output: { sessionID, directory: input.directory },
                content: `Moved session ${sessionID} to ${input.directory}.`,
              }
            }).pipe(
              Effect.mapError(
                (error) => new ToolFailure({ message: `Unable to move session to ${input.directory}`, error }),
              ),
            ),
        })
      })
      .pipe(Effect.orDie)
  }),
}

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
