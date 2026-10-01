import { Schema, Option } from "effect"
import { createLegacyBlobReference } from "@/runtime/persistence/drafts"
import { ChatQuote } from "./schema"
import { expandSnippets, isAttachment } from "./prompt-parts"

const decodeQuotes = Schema.decodeUnknownOption(Schema.Array(ChatQuote))
export function readChatQuotes(value: unknown): ChatQuote[] {
  return [...Option.getOrElse(decodeQuotes(value), () => [])]
}

type MessageFile = { mime: string; data: string; source: { type: "inline" } | { type: "uri"; uri: string } }

// Quote images are delivered after the prompt's own files, so the trailing message files hold their bytes in order.
export function restoreChatQuotes<File extends MessageFile>(value: unknown, files: readonly File[] = []) {
  const quotes = readChatQuotes(value)
  const ids = quotes.flatMap((quote) =>
    (quote.commentPrompt ?? []).flatMap((part) => (part.type === "image" ? [part.id] : [])),
  )
  if (ids.length === 0 || ids.length > files.length) return { quotes, files: [...files] }
  const own = files.slice(0, files.length - ids.length)
  const urls = new Map(ids.map((id, index) => [id, fileDataUrl(files[own.length + index]!)]))
  return {
    files: own,
    quotes: quotes.map((quote) =>
      quote.commentPrompt
        ? {
            ...quote,
            commentPrompt: quote.commentPrompt.map((part) => {
              const url = part.type === "image" ? urls.get(part.id) : undefined
              return url && part.type === "image" ? { ...part, blob: createLegacyBlobReference(url) } : part
            }),
          }
        : quote,
    ),
  }
}

export function chatQuoteAttachments(quotes: readonly ChatQuote[]) {
  return quotes.flatMap((quote) => (quote.commentPrompt ?? []).filter(isAttachment))
}

// Append context after the draft so mention offsets keep referring to the user's text.
export function formatChatQuotes(quotes: ChatQuote[]) {
  if (!quotes.length) return ""
  return [
    "Comments on earlier assistant messages:",
    ...quotes.map((quote, index) => {
      const comment = chatQuoteComment(quote).trim()
      return [
        `${index + 1}. Quoted from message ${quote.messageID} (part ${quote.partID}):`,
        quote.text
          .split("\n")
          .map((line) => `> ${line}`)
          .join("\n"),
        ...(comment ? [`User comment: ${comment}`] : []),
        ...chatQuoteAttachments([quote]).map((part) =>
          part.type === "image"
            ? `Image attached to this comment: ${part.sourcePath ?? part.filename}`
            : `File attached to this comment: \`${part.path}\``,
        ),
      ].join("\n")
    }),
  ].join("\n\n")
}

export function chatQuoteComment(quote: ChatQuote) {
  if (!quote.commentPrompt) return quote.comment
  return expandSnippets(quote.commentPrompt)
    .map((part) => ("content" in part ? part.content : ""))
    .join("")
}

function fileDataUrl(file: MessageFile) {
  if (file.source.type === "uri") return file.source.uri.startsWith("data:") ? file.source.uri : undefined
  return file.data ? `data:${file.mime};base64,${file.data}` : undefined
}
