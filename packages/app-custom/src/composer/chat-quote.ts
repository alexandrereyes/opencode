import { Schema, Option } from "effect"
import { ChatQuote } from "./schema"
import { expandSnippets } from "./prompt-parts"

const decodeQuotes = Schema.decodeUnknownOption(Schema.Array(ChatQuote))
export function readChatQuotes(value: unknown): ChatQuote[] {
  return [...Option.getOrElse(decodeQuotes(value), () => [])]
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
