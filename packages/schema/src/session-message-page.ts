export * as MessagePage from "./session-message-page.js"

import { Effect, Result, Schema } from "effect"
import { Base64Url } from "effect/encoding"
import { statics } from "./schema.js"
import { SessionMessage } from "./session-message.js"

export interface CursorInput extends Schema.Schema.Type<typeof CursorInput> {}
export const CursorInput = Schema.Struct({
  id: SessionMessage.ID,
  order: Schema.Literals(["asc", "desc"]),
  direction: Schema.Literals(["previous", "next"]),
}).annotate({ identifier: "Session.MessagePage.CursorInput" })

const CursorJson = Schema.fromJsonString(CursorInput)
const encodeCursor = Schema.encodeSync(CursorJson)
const decodeCursor = Schema.decodeUnknownEffect(CursorJson)
const invalidCursor = "Invalid cursor" as const

export const Cursor = Schema.String.pipe(
  Schema.brand("Session.MessagePage.Cursor"),
  statics((schema) => {
    const make = schema.make.bind(schema)
    return {
      make: (input: CursorInput) => make(Base64Url.encode(encodeCursor(input))),
      parse: (input: string) =>
        Effect.suspend(() => {
          const result = Base64Url.decodeString(input)
          return Result.isFailure(result)
            ? Effect.fail(invalidCursor)
            : decodeCursor(result.success).pipe(Effect.mapError(() => invalidCursor))
        }),
    }
  }),
)
export type Cursor = typeof Cursor.Type
