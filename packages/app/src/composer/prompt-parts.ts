import type { Prompt } from "./state"

export function clonePrompt(prompt: Prompt): Prompt {
  return prompt.map((part) =>
    part.type === "file" ? { ...part, selection: part.selection ? { ...part.selection } : undefined } : { ...part },
  )
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
