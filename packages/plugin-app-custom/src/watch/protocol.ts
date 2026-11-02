import { Option, Schema } from "effect"
import { sanitize } from "../voice/sanitize.js"

// GPT Live's wire as the gateway reaches it: the Codex route (`OpenAI-Alpha: quicksilver=v2`), not OpenAI's public Live
// API. Its paths and headers, the creation's body, and the sideband's events, commands and field names live here, so
// moving to the official API changes this file while `voice.ts` keeps the orchestration. The iPhone's `VoiceProtocol`
// (OpenCodeKit) is the same wire; `packages/ios-custom/docs/voice.md` ("Rota do Codex e API oficial") maps each name.

export const model = "gpt-live-1-codex"
/** The Codex alpha headers, on the creation and on the sideband. */
export const alphaHeaders = { "OpenAI-Alpha": "quicksilver=v2", originator: "a2a-chat" }
export const createPath = "/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas"
/** The sideband of a created call, a WebSocket through the llm-proxy. */
export const sidebandPath = (callID: string) => `/v1/live/${callID}`
/** At most this many UTF-8 bytes of text per append. */
export const appendBytes = 500

/** GPT Live's ID of the call: the last segment of the creation's `Location` (`/v1/realtime/calls/rtc_…`). */
export function callID(location: string) {
  return location.split("?")[0]?.replace(/\/$/, "").split("/").pop() || undefined
}

/** The creation's body: the offer and the `session`, with client delegation and, when there are any, `initial_items`. */
export function creation(input: {
  readonly sdp: string
  readonly instructions: string
  readonly voice: string
  readonly items: readonly ReturnType<typeof message>[]
}) {
  return {
    sdp: input.sdp,
    session: {
      model,
      instructions: input.instructions,
      audio: { output: { voice: input.voice } },
      delegation: { type: "client" },
      ...(input.items.length > 0 ? { initial_items: input.items } : {}),
    },
  }
}

/** Turns keep their speaker; what the server tells GPT Live (summary, Mestra state) is a developer message. */
export function message(role: "developer" | "user" | "assistant", text: string) {
  return { type: "message", role, content: [{ type: role === "assistant" ? "output_text" : "input_text", text }] }
}

const SidebandEvent = Schema.Struct({
  type: Schema.String,
  item: Schema.optionalKey(
    Schema.Struct({
      id: Schema.optionalKey(Schema.String),
      type: Schema.optionalKey(Schema.String),
      text: Schema.optionalKey(Schema.String),
      target: Schema.optionalKey(Schema.String),
      user_bidi_turn_id: Schema.optionalKey(Schema.String),
      content: Schema.optionalKey(
        Schema.Array(Schema.Struct({ type: Schema.String, text: Schema.optionalKey(Schema.String) })),
      ),
    }),
  ),
  turn: Schema.optionalKey(
    Schema.Struct({
      id: Schema.optionalKey(Schema.String),
      role: Schema.optionalKey(Schema.String),
      transcript: Schema.optionalKey(Schema.String),
      status: Schema.optionalKey(Schema.String),
      interrupted: Schema.optionalKey(Schema.Boolean),
    }),
  ),
  // Free-form on purpose: an error's fields must reach the log whatever their shape, nested or at the top level.
  error: Schema.optionalKey(Schema.Unknown),
  code: Schema.optionalKey(Schema.Unknown),
  message: Schema.optionalKey(Schema.Unknown),
  param: Schema.optionalKey(Schema.Unknown),
  event_id: Schema.optionalKey(Schema.Unknown),
  // `session.started` and `session.closed`, read field by field below: a field of an unexpected type must not lose the
  // event.
  session: Schema.optionalKey(Schema.Unknown),
  reason: Schema.optionalKey(Schema.Unknown),
  usage: Schema.optionalKey(Schema.Unknown),
})
export const decodeEvent = Schema.decodeUnknownOption(Schema.fromJsonString(SidebandEvent))
export const decodeType = Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Struct({ type: Schema.String })))
const decodeStartedID = Schema.decodeUnknownOption(Schema.Struct({ session: Schema.Struct({ id: Schema.String }) }))
const decodeStartedExpiry = Schema.decodeUnknownOption(
  Schema.Struct({ session: Schema.Struct({ expires_at: Schema.Finite }) }),
)
const decodeClosedReason = Schema.decodeUnknownOption(Schema.Struct({ reason: Schema.String }))
const decodeClosedUsage = Schema.decodeUnknownOption(
  Schema.Struct({ usage: Schema.Struct({ audio_duration_ms: Schema.Finite }) }),
)

/**
 * `session.started`: GPT Live's ID of the call (`session.id`, the `Location`'s on 02/11) and when the session expires
 * (`session.expires_at`, epoch seconds: the creation plus 2 h), each when readable.
 */
export function started(event: typeof SidebandEvent.Type) {
  return {
    id: Option.getOrUndefined(decodeStartedID(event))?.session.id,
    expiresAt: Option.getOrUndefined(decodeStartedExpiry(event))?.session.expires_at,
  }
}

/** `session.closed`: its reason and the audio it counted (`usage.audio_duration_ms`), each when readable. */
export function closed(event: typeof SidebandEvent.Type) {
  return {
    reason: Option.getOrUndefined(decodeClosedReason(event))?.reason,
    audioMs: Option.getOrUndefined(decodeClosedUsage(event))?.usage.audio_duration_ms,
  }
}

/**
 * Every command carries an `event_id` of the gateway's, `oc_` and 16 hex digits: GPT Live takes one on any command and
 * returns it in an `error` about that command (`error.event_id`), never in a confirmation (02/11).
 */
const command = (type: string, fields: Readonly<Record<string, unknown>> = {}) => ({
  ...fields,
  type,
  event_id: "oc_" + crypto.randomUUID().replaceAll("-", "").slice(0, 16),
})
export type Command = ReturnType<typeof command>

/** Text for one delegation item, to be spoken (`speakable`) or as quiet state (`commentary`), in parts. */
export function append(itemID: string, text: string, channel: "speakable" | "commentary") {
  return chunks(text).map((chunk) =>
    command("delegation.context.append", {
      delegation_item_id: itemID,
      channel,
      content: [{ type: "input_text", text: chunk }],
    }),
  )
}

/** Asks GPT Live to end the session; it answers `session.closed`, then closes the sideband. */
export function close() {
  return command("session.close")
}

/** Splits text into parts of at most `appendBytes` UTF-8 bytes without breaking a code point. */
export function chunks(text: string) {
  return Array.from(text).reduce<string[]>((parts, char) => {
    const last = parts.at(-1)
    if (last !== undefined && Buffer.byteLength(last + char) <= appendBytes) parts[parts.length - 1] = last + char
    else parts.push(char)
    return parts
  }, [])
}

const ErrorFields = Schema.Struct({
  type: Schema.optionalKey(Schema.Unknown),
  code: Schema.optionalKey(Schema.Unknown),
  message: Schema.optionalKey(Schema.Unknown),
  param: Schema.optionalKey(Schema.Unknown),
  event_id: Schema.optionalKey(Schema.Unknown),
})
const decodeErrorFields = Schema.decodeUnknownOption(ErrorFields)

/** The service's moderation error, by its structured `type` or `code`; never by its message. */
export function moderated(error: ReturnType<typeof upstreamError>) {
  return error.type === "content_filter" || error.code === "content_filter"
}

/**
 * Same rule as the iPhone's `VoiceProtocol.closedByModeration`: a `session.closed` reason that names moderation.
 * OpenAI documents `content`; this route was only seen sending `client_request`, so any reason mentioning content or
 * moderation counts.
 */
export function closedByModeration(reason: string | undefined) {
  const value = reason?.toLowerCase() ?? ""
  return value.includes("content") || value.includes("moderat")
}

/**
 * An upstream `error` event's fields for the log, from `error.*` or else the top level (a string `error` is its
 * message). The event IDs stay apart: `clientEventID` is ours, `error.event_id`, the command the error is about;
 * `serverEventID` is the event's own, the service's (02/11). Every value is sanitized and bounded; the message may
 * quote a request, never a transcript.
 */
export function upstreamError(event: typeof ErrorFields.Type & { readonly error?: unknown }) {
  const nested = Option.getOrUndefined(decodeErrorFields(event.error))
  const scalar = (value: unknown, max: number) =>
    typeof value === "string" || typeof value === "number" ? sanitize(String(value), max) : undefined
  const field = (name: "type" | "code" | "message" | "param", max: number) =>
    scalar(nested?.[name] ?? (name === "type" ? undefined : event[name]), max)
  const message = field("message", 240) ?? (typeof event.error === "string" ? sanitize(event.error, 240) : undefined)
  return Object.fromEntries(
    Object.entries({
      type: field("type", 64),
      code: field("code", 64),
      param: field("param", 120),
      message,
      clientEventID: scalar(nested?.event_id, 64),
      serverEventID: scalar(event.event_id, 64),
    }).filter((entry): entry is [string, string] => entry[1] !== undefined && entry[1] !== ""),
  )
}

const VoiceRejection = Schema.Struct({
  error: Schema.optionalKey(
    Schema.Struct({
      code: Schema.optionalKey(Schema.NullOr(Schema.String)),
      type: Schema.optionalKey(Schema.NullOr(Schema.String)),
      param: Schema.optionalKey(Schema.NullOr(Schema.String)),
    }),
  ),
  detail: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({ loc: Schema.optionalKey(Schema.Array(Schema.Unknown)), type: Schema.optionalKey(Schema.String) }),
    ),
  ),
})
const decodeRejection = Schema.decodeUnknownOption(Schema.fromJsonString(VoiceRejection))

/** Same rule as the iPhone's `VoiceProtocol.rejectsVoice`. */
export function rejectsVoice(status: number, body: string) {
  if (status !== 400 && status !== 422) return false
  const root = Option.getOrUndefined(decodeRejection(body))
  if (!root) return false
  if (["invalid_voice", "unsupported_voice"].includes(root.error?.code ?? "")) return true
  if (
    root.error?.type === "invalid_request_error" &&
    ["session.audio.output.voice", "audio.output.voice", "voice"].includes(root.error.param ?? "")
  )
    return true
  return (root.detail ?? []).some(
    (item) =>
      (item.loc ?? []).slice(-4).join(".") === "session.audio.output.voice" &&
      ["enum", "literal_error", "value_error"].includes(item.type ?? ""),
  )
}
