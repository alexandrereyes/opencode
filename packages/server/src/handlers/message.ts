import { Session } from "@opencode/core/session"
import { Effect } from "effect"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { Api } from "../api"
import { InvalidCursorError } from "@opencode/protocol/errors"
import { MessagePage } from "@opencode/schema/session-message-page"
import { failedMessageDecode, missingSession } from "./session-error"

const DefaultMessagesLimit = 50

export const MessageHandler = HttpApiBuilder.group(Api, "server.message", (handlers) =>
  Effect.gen(function* () {
    const session = yield* Session.Service

    return handlers.handle(
      "session.messages",
      Effect.fn(function* (ctx) {
        if (ctx.query.cursor && ctx.query.order !== undefined)
          return yield* new InvalidCursorError({ message: "Cursor cannot be combined with order" })
        const decoded = ctx.query.cursor
          ? yield* MessagePage.Cursor.parse(ctx.query.cursor).pipe(
              Effect.mapError(() => new InvalidCursorError({ message: "Invalid cursor" })),
            )
          : undefined
        const order = decoded?.order ?? ctx.query.order ?? "desc"
        const messages = yield* session
          .messages({
            sessionID: ctx.params.sessionID,
            limit: ctx.query.limit ?? DefaultMessagesLimit,
            order,
            type: ctx.query.type,
            cursor: decoded ? { id: decoded.id, direction: decoded.direction } : undefined,
          })
          .pipe(
            Effect.catchTag("Session.NotFoundError", missingSession),
            Effect.catchTag("Session.MessageDecodeError", failedMessageDecode),
          )
        const first = messages[0]
        const last = messages.at(-1)
        return {
          data: messages,
          cursor: {
            previous: first ? MessagePage.Cursor.make({ id: first.id, order, direction: "previous" }) : undefined,
            next: last ? MessagePage.Cursor.make({ id: last.id, order, direction: "next" }) : undefined,
          },
        }
      }),
    )
  }),
)
