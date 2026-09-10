import { Session } from "@opencode/schema/session"
import { Schema } from "effect"
import type { Prompt, SessionPart } from "./state"

const link = /\[((?:\\.|[^\]])*)\]\((opencode:\/\/session\/[^)\s]+)\)/g

export function formatSessionContext(part: SessionPart) {
  return `Referenced OpenCode session: ${JSON.stringify({
    sessionID: part.session.id,
    title: part.session.title,
    directory: part.session.directory,
  })}. Use tools.opencode.session_read when you need to discuss its contents.`
}

export function formatSessionContexts(parts: SessionPart[]) {
  return [
    ...new Map(
      parts.map((part) => [`${part.session.server}\n${part.session.id}`, formatSessionContext(part)]),
    ).values(),
  ]
}

export function formatSessionReference(part: SessionPart) {
  const title = part.session.title ?? part.session.id
  const label = `@${title}`.replaceAll("\\", "\\\\").replaceAll("]", "\\]")
  const params = new URLSearchParams({
    server: part.session.server,
    ...(part.session.directory ? { directory: part.session.directory } : {}),
  })
  return `[${label}](opencode://session/${part.session.id}?${params})`
}

export function formatSessionReferences(text: string, sessions: SessionPart[]) {
  const ordered = sessions.toSorted((a, b) => a.start - b.start)
  let cursor = 0
  return (
    ordered.reduce((result, part) => {
      if (part.start < cursor || text.slice(part.start, part.end) !== part.content) return result
      const next = result + text.slice(cursor, part.start) + formatSessionReference(part)
      cursor = part.end
      return next
    }, "") + text.slice(cursor)
  )
}

export function parseSessionReferences(text: string, server: string): Prompt | undefined {
  const result: Prompt = []
  let source = 0
  let offset = 0
  let found = false
  const pushText = (content: string) => {
    if (!content) return
    result.push({ type: "text", content, start: offset, end: offset + content.length })
    offset += content.length
  }

  for (const match of text.matchAll(link)) {
    const raw = match[0]
    const start = match.index
    const parsed = URL.parse(match[2] ?? "")
    const id = parsed?.pathname.slice(1)
    if (
      !parsed ||
      parsed.protocol !== "opencode:" ||
      parsed.hostname !== "session" ||
      parsed.searchParams.get("server") !== server ||
      !Schema.is(Session.ID)(id)
    )
      continue
    pushText(text.slice(source, start))
    const title = (match[1] ?? "").replace(/^@/, "").replaceAll("\\]", "]").replaceAll("\\\\", "\\")
    const directory = parsed.searchParams.get("directory")
    const content = `@${title || id}`
    result.push({
      type: "session",
      content,
      start: offset,
      end: offset + content.length,
      session: {
        id,
        server,
        ...(title ? { title } : {}),
        ...(directory ? { directory } : {}),
      },
    })
    offset += content.length
    source = start + raw.length
    found = true
  }
  if (!found) return undefined
  pushText(text.slice(source))
  return result
}
