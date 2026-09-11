import type { Prompt } from "./state"

export function clonePrompt(prompt: Prompt): Prompt {
  return prompt.map((part) =>
    part.type === "file" ? { ...part, selection: part.selection ? { ...part.selection } : undefined } : { ...part },
  )
}

export function normalizeComposerText(value: string) {
  return value.replace(/\r\n?/g, "\n")
}

export function normalizeComposerPrompt(prompt: Prompt): Prompt {
  let offset = 0
  return clonePrompt(prompt).map((part) => {
    if (part.type === "image") return part
    const content = normalizeComposerText(part.content)
    const next = { ...part, content, start: offset, end: offset + content.length }
    offset = next.end
    return next
  })
}

export function normalizeComposerCursor(prompt: Prompt, cursor: number) {
  const text = prompt.map((part) => ("content" in part ? part.content : "")).join("")
  return normalizeComposerText(text.slice(0, Math.min(Math.max(cursor, 0), text.length))).length
}

export function promptLength(prompt: Prompt) {
  return prompt.reduce((length, part) => length + ("content" in part ? part.content.length : 0), 0)
}

export function expandSnippets(prompt: Prompt): Prompt {
  let offset = 0
  return prompt.map((part) => {
    if (part.type === "image") return part
    const content = part.type === "snippet" ? part.expansion : part.content
    const start = offset
    offset += content.length
    if (part.type === "snippet") return { type: "text", content, start, end: offset }
    return { ...part, start, end: offset }
  })
}

export function appendPrompt(prompt: Prompt, following: Prompt): Prompt {
  const start = promptLength(prompt)
  const offset = start + 2
  return [
    ...clonePrompt(prompt),
    { type: "text", content: "\n\n", start, end: offset },
    ...clonePrompt(following).map((part) =>
      part.type === "image" ? part : { ...part, start: part.start + offset, end: part.end + offset },
    ),
  ]
}
