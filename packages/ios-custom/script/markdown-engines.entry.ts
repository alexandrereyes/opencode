import hljs from "highlight.js"
import { renderMermaidASCII, renderMermaidSVG } from "beautiful-mermaid"

declare global {
  var openCodeHighlight: (source: string, language: string) => string | null
  var openCodeMermaid: (source: string) => string
  var openCodeMermaidASCII: (source: string) => string
}

// JavaScriptCore consumes only these entry points. Highlighting returns
// text/style runs, never HTML to be installed in the native conversation.
globalThis.openCodeHighlight = (source, language) => {
  if (!hljs.getLanguage(language)) return null
  const html = hljs.highlight(source, { language, ignoreIllegals: true }).value
  const stack: string[] = []
  const tokens: { text: string; style: string }[] = []
  const entities: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', "#x27": "'" }
  for (const match of html.matchAll(/<span class="([^"]+)">|(<\/span>)|([^<]+)/g)) {
    if (match[1]) { stack.push(match[1]); continue }
    if (match[2]) { stack.pop(); continue }
    if (!match[3]) continue
    tokens.push({
      text: match[3].replace(/&(amp|lt|gt|quot|#x27);/g, (_, entity: string) => entities[entity]!),
      style: stack.join(" "),
    })
  }
  return JSON.stringify(tokens)
}

globalThis.openCodeMermaid = (source) => renderMermaidSVG(source, {
  bg: "var(--diagram-background)", fg: "var(--diagram-text)",
  line: "var(--diagram-line)", accent: "var(--diagram-accent)",
  muted: "var(--diagram-muted)", surface: "var(--diagram-surface)",
  border: "var(--diagram-border)", transparent: true, font: "system-ui, sans-serif",
})
globalThis.openCodeMermaidASCII = (source) => renderMermaidASCII(source)
