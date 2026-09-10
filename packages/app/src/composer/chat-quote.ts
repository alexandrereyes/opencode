import { Schema, Option } from "effect"
import { ChatQuote } from "./schema"

const decodeQuotes = Schema.decodeUnknownOption(Schema.Array(ChatQuote))
export function readChatQuotes(value: unknown): ChatQuote[] {
  return [...Option.getOrElse(decodeQuotes(value), () => [])]
}

// Append context after the draft so mention offsets keep referring to the user's text.
export function formatChatQuotes(quotes: ChatQuote[]) {
  if (!quotes.length) return ""
  return [
    "Comments on earlier assistant messages:",
    ...quotes.map((quote, index) =>
      [
        `${index + 1}. Quoted from message ${quote.messageID} (part ${quote.partID}):`,
        quote.text
          .split("\n")
          .map((line) => `> ${line}`)
          .join("\n"),
        ...(quote.comment.trim() ? [`User comment: ${quote.comment.trim()}`] : []),
      ].join("\n"),
    ),
  ].join("\n\n")
}
