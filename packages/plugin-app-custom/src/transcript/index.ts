import { Plugin } from "@opencode/plugin/effect"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { DateTime, Effect, Schema } from "effect"
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
      skills: (input, context) =>
        skills(ctx.message, input.sessionID).pipe(
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

/**
 * Skills loaded into the session: direct activations, skills attached to prompts and completed `skill` tool calls.
 * Pages are read and reduced here so a phone receives only the IDs and names, never the transcript.
 */
export const skills = Effect.fn("Transcript.skills")(function* (
  messages: Plugin.Context["message"],
  sessionID: Session.ID,
) {
  const loaded = yield* Effect.forEach(
    ["skill", "user", "assistant"] as const,
    (type) => loadedSkills(messages, sessionID, type),
    { concurrency: "unbounded" },
  )
  const names = new Map<string, string>()
  loaded
    .flat()
    .sort((a, b) => a.at - b.at)
    .forEach((skill) => {
      if (!names.has(skill.id)) names.set(skill.id, skill.name)
    })
  return { data: [...names].map(([id, name]) => ({ id, name })) }
})

type LoadedSkill = { id: string; name: string; at: number }

const PageSize = 200

function loadedSkills(
  messages: Plugin.Context["message"],
  sessionID: Session.ID,
  type: "skill" | "user" | "assistant",
  cursor?: string,
): Effect.Effect<LoadedSkill[], unknown> {
  return messages
    .list(cursor ? { sessionID, type, limit: PageSize, cursor } : { sessionID, type, limit: PageSize, order: "asc" })
    .pipe(
      Effect.flatMap((page) => {
        const found = page.data.flatMap(messageSkills)
        if (page.data.length < PageSize || !page.cursor.next) return Effect.succeed(found)
        return loadedSkills(messages, sessionID, type, page.cursor.next).pipe(Effect.map((rest) => [...found, ...rest]))
      }),
    )
}

function messageSkills(message: SessionMessage.Info): LoadedSkill[] {
  const at = DateTime.toEpochMillis(message.time.created)
  if (message.type === "skill") return [{ id: message.skill, name: message.name, at }]
  if (message.type === "user") return (message.skills ?? []).map((skill) => ({ id: skill.id, name: skill.name, at }))
  if (message.type !== "assistant") return []
  return message.content.flatMap((part) => {
    if (part.type !== "tool" || part.name !== "skill" || part.state.status !== "completed") return []
    const id = part.state.input.id
    if (typeof id !== "string") return []
    const name = part.state.metadata?.name
    return [{ id, name: typeof name === "string" ? name : id, at: DateTime.toEpochMillis(part.time.created) }]
  })
}

function leanMessage(message: SessionMessage.Info): SessionMessage.Info {
  if (message.type !== "assistant") return message
  return { ...message, content: message.content.map((part) => (part.type === "tool" ? leanTool(part) : part)) }
}

function leanTool(tool: SessionMessage.AssistantTool): SessionMessage.AssistantTool {
  if ((tool.state.status !== "completed" && tool.state.status !== "error") || !tool.state.content) return tool
  return { ...tool, state: { ...tool.state, content: omitInlineMedia(tool.state.content) } }
}
