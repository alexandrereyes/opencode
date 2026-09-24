import { getFilename } from "@opencode/util/path"
import { AppMentions } from "@opencode/plugin-app-custom/rpc"
import type { FileSelection } from "@/workspaces/files/model"
import { encodeFilePath } from "@/workspaces/files/path"
import type { AgentPart, FileAttachmentPart, Prompt, SkillPart } from "@/composer/state"
import {
  formatAttachmentReference,
  formatCommentNote,
  type PromptAttachmentReference,
  type PromptComment,
} from "@/composer/comment-note"
import type { DeliveredAttachment } from "@/composer/attachments/deliver"
import { expandSnippets, isAttachment } from "./prompt-parts"
import type { ChatQuote } from "./schema"
import { formatChatQuotes } from "./chat-quote"
import { formatSessionContexts } from "./session-reference"

// Network fields feed both boundaries; display fields keep desktop-only rendering details in the local echo.
type PromptRequest = {
  text: string
  displayText: string
  files: { uri: string; mime: string; name?: string; mention?: { start: number; end: number; text: string } }[]
  agents: { name: string; mention?: { start: number; end: number; text: string } }[]
  skills: { id: string; name: string; mention?: { start: number; end: number; text: string } }[]
  comments: PromptComment[]
  apps: Extract<Prompt[number], { type: "app" }>[]
  sessions: Extract<Prompt[number], { type: "session" }>[]
  quotes: ChatQuote[]
  attachments: PromptAttachmentReference[]
  fileReferences: PromptAttachmentReference[]
}

type ContextFile = {
  key: string
  type: "file"
  path: string
  selection?: FileSelection
  comment?: string
  commentID?: string
  commentOrigin?: "review" | "file"
  preview?: string
}

type BuildPromptRequestInput = {
  prompt: Prompt
  context: ContextFile[]
  attachments: DeliveredAttachment[]
  text: string
  sessionDirectory: string
  quotes?: ChatQuote[]
}

const absolute = (directory: string, path: string) => {
  if (path.startsWith("/")) return path
  if (/^[A-Za-z]:[\\/]/.test(path) || /^[A-Za-z]:$/.test(path)) return path
  if (path.startsWith("\\\\") || path.startsWith("//")) return path
  return `${directory.replace(/[\\/]+$/, "")}/${path}`
}

const fileQuery = (selection: FileSelection | undefined) =>
  selection ? `?start=${selection.startLine}&end=${selection.endLine}` : ""

const mention = /(^|[\s([{"'])@(\S+)/g

const parseCommentMentions = (comment: string) => {
  return Array.from(comment.matchAll(mention)).flatMap((match) => {
    const path = (match[2] ?? "").replace(/[.,!?;:)}\]"']+$/, "")
    if (!path) return []
    return [path]
  })
}

const isFileAttachment = (part: Prompt[number]): part is FileAttachmentPart => part.type === "file"
const isAgentAttachment = (part: Prompt[number]): part is AgentPart => part.type === "agent"
const isSkillAttachment = (part: Prompt[number]): part is SkillPart => part.type === "skill"

export function buildPromptRequest(input: BuildPromptRequestInput): PromptRequest {
  const prompt = input.prompt.some((part) => part.type === "snippet") ? expandSnippets(input.prompt) : input.prompt
  const quotePrompt = (input.quotes ?? []).flatMap((quote) =>
    quote.commentPrompt?.some((part) => part.type === "snippet")
      ? expandSnippets(quote.commentPrompt)
      : (quote.commentPrompt ?? []),
  )
  const text =
    prompt === input.prompt ? input.text : prompt.map((part) => ("content" in part ? part.content : "")).join("")
  const apps = [...prompt, ...quotePrompt].filter((part) => part.type === "app")
  const sessions = [...prompt, ...quotePrompt].filter((part) => part.type === "session")
  const skills = prompt.filter(isSkillAttachment).map((attachment) => ({
    id: attachment.id,
    name: attachment.name,
    mention: { start: attachment.start, end: attachment.end, text: attachment.content },
  }))
  const quoteSkills = quotePrompt.filter(isSkillAttachment).map((attachment) => ({
    id: attachment.id,
    name: attachment.name,
  }))
  const files = prompt.filter(isFileAttachment).map((attachment) => {
    const path = absolute(input.sessionDirectory, attachment.path)
    return {
      uri: attachment.url ?? `file://${encodeFilePath(path)}${fileQuery(attachment.selection)}`,
      mime: attachment.mime ?? "text/plain",
      name: attachment.filename ?? getFilename(attachment.path),
      mention: { start: attachment.start, end: attachment.end, text: attachment.content },
    }
  })
  const quoteFiles = quotePrompt.filter(isFileAttachment).map((attachment) => {
    const path = absolute(input.sessionDirectory, attachment.path)
    return {
      uri: attachment.url ?? `file://${encodeFilePath(path)}${fileQuery(attachment.selection)}`,
      mime: attachment.mime ?? "text/plain",
      name: attachment.filename ?? getFilename(attachment.path),
    }
  })

  const agents = prompt.filter(isAgentAttachment).map((attachment) => ({
    name: attachment.name,
    mention: { start: attachment.start, end: attachment.end, text: attachment.content },
  }))
  const quoteAgents = quotePrompt.filter(isAgentAttachment).map((attachment) => ({ name: attachment.name }))

  const used = new Set([...files, ...quoteFiles].map((file) => file.uri))
  const comments: PromptComment[] = []
  const context = input.context.flatMap((item) => {
    const path = absolute(input.sessionDirectory, item.path)
    const uri = `file://${encodeFilePath(path)}${fileQuery(item.selection)}`
    const comment = item.comment?.trim()
    if (!comment && used.has(uri)) return []
    used.add(uri)

    const file = { uri, mime: "text/plain", name: getFilename(item.path) }
    if (!comment) return [file]

    comments.push({
      path: item.path,
      selection: item.selection,
      comment,
      preview: item.preview,
      origin: item.commentOrigin,
    })
    const mentions = parseCommentMentions(comment).flatMap((path) => {
      const uri = `file://${encodeFilePath(absolute(input.sessionDirectory, path))}`
      if (used.has(uri)) return []
      used.add(uri)
      return [{ uri, mime: "text/plain", name: getFilename(path) }]
    })
    return [file, ...mentions]
  })

  const imageMentions = new Map(
    prompt.flatMap((part) => (isAttachment(part) ? [[part.id, part.mention] as const] : [])),
  )
  const inline = input.attachments.flatMap((item) =>
    item.type === "inline"
      ? [
          {
            uri: item.dataUrl,
            mime: item.attachment.mime,
            name: item.attachment.sourcePath ?? item.attachment.filename,
            mention: imageMentions.get(item.attachment.id),
          },
        ]
      : [],
  )
  const attachments = input.attachments.flatMap((item) =>
    item.type === "path"
      ? [
          {
            name: item.attachment.filename,
            mime: item.attachment.mime,
            path: item.path,
            ...(imageMentions.get(item.attachment.id) ? { mention: imageMentions.get(item.attachment.id) } : {}),
          },
        ]
      : [],
  )
  const fileReferences = input.attachments.map((item) => ({
    name: item.attachment.filename,
    mime: item.attachment.mime,
    path: item.path,
  }))

  return {
    text: [
      ...(text.trim() ? [text] : []),
      ...fileReferences.map(formatAttachmentReference),
      ...comments.map(formatCommentNote),
      ...apps.map(formatAppContext),
      ...formatSessionContexts(sessions),
      ...(input.quotes?.length ? [formatChatQuotes(input.quotes)] : []),
    ].join("\n"),
    displayText: text,
    files: [...files, ...quoteFiles, ...context, ...inline],
    agents: [...agents, ...quoteAgents],
    skills: [...skills, ...quoteSkills],
    comments,
    apps,
    sessions,
    quotes: input.quotes ?? [],
    attachments,
    fileReferences,
  }
}

export function formatAppContext(part: Extract<Prompt[number], { type: "app" }>) {
  if (AppMentions.isSafariDevTools(part.app))
    return `Safari DevTools selected by the user: ${JSON.stringify(part.app)}. Use only the native ${AppMentions.SafariDevTools.server} MCP tools, which operate in Safari's isolated automation window; do not use codex-computer-use or silently fall back to the user's ordinary Safari. If no automation window exists, begin with navigate_to_url because list_tabs and create_tab may error before initial navigation. Safari WebDriver supports a single active session; if it is already in use, report a clear conflict instead of touching personal Safari.`
  return `Computer use app selected by the user: ${JSON.stringify(part.app)}. Use its bundleID as the app argument to ${part.app.server} tools.`
}
