import { isolateHistory } from "@codemirror/commands"
import { EditorState, StateField, Transaction, type TransactionSpec } from "@codemirror/state"
import { Decoration, EditorView } from "@codemirror/view"
import { composerReferences } from "./codemirror"

type Style =
  | "marker"
  | "code"
  | "fence"
  | "link"
  | "url"
  | "heading"
  | "quote"
  | "list"
  | "strong"
  | "emphasis"
  | "attention"
export type MarkdownRange = { from: number; to: number; style: Style }

export function tokenizeMarkdown(text: string): MarkdownRange[] {
  const ranges: MarkdownRange[] = []
  const cursor = { offset: 0, fence: "" }
  text.split("\n").forEach((line) => {
    const from = cursor.offset
    cursor.offset += line.length + 1
    if (cursor.fence) {
      if (line.length) ranges.push({ from, to: from + line.length, style: "fence" })
      if (new RegExp(`^\\s*${cursor.fence[0]}{${cursor.fence.length},}\\s*$`).test(line)) cursor.fence = ""
      return
    }
    const fence = /^\s*(`{3,}|~{3,})/.exec(line)
    if (fence) {
      cursor.fence = fence[1]
      ranges.push({ from, to: from + line.length, style: "fence" })
      return
    }
    const block = /^(\s*)(!!!|#{1,6})(\s+)/.exec(line)
    const quote = /^(\s*)(>+)(\s?)/.exec(line)
    const list = /^(\s*)([-*+]|\d{1,9}[.)])(\s+)/.exec(line)
    const match = block ?? quote ?? list
    if (!match) return scanInline(line, from, ranges)
    const start = from + match[1].length
    const content = from + match[0].length
    ranges.push({ from: start, to: start + match[2].length, style: list && !block && !quote ? "list" : "marker" })
    if (content < from + line.length && (block || quote)) {
      ranges.push({
        from: content,
        to: from + line.length,
        style: quote ? "quote" : match[2] === "!!!" ? "attention" : "heading",
      })
    }
    scanInline(line.slice(match[0].length), content, ranges)
  })
  return ranges
}

function scanInline(text: string, base: number, ranges: MarkdownRange[]) {
  let index = 0
  while (index < text.length) {
    const char = text[index]
    const ticks = char === "`" ? /^`+/.exec(text.slice(index))?.[0] : undefined
    const close = ticks ? text.indexOf(ticks, index + ticks.length) : -1
    if (ticks && close !== -1) {
      ranges.push({ from: base + index, to: base + close + ticks.length, style: "code" })
      index = close + ticks.length
      continue
    }
    const link = char === "[" ? /^\[([^\]\n]*)\]\(([^)\n]*)\)/.exec(text.slice(index)) : undefined
    if (link) {
      const from = base + index
      ranges.push({ from, to: from + 1, style: "marker" })
      if (link[1]) ranges.push({ from: from + 1, to: from + 1 + link[1].length, style: "link" })
      const middle = from + 1 + link[1].length
      const end = from + link[0].length
      ranges.push({ from: middle, to: middle + 2, style: "marker" })
      if (link[2]) ranges.push({ from: middle + 2, to: end - 1, style: "url" })
      ranges.push({ from: end - 1, to: end, style: "marker" })
      index += link[0].length
      continue
    }
    const run = char === "*" || char === "_" ? /^(\*{1,3}|_{1,3})/.exec(text.slice(index))?.[0] : undefined
    if (
      run &&
      text[index + run.length] &&
      !/\s/.test(text[index + run.length]) &&
      !(run[0] === "_" && /\w/.test(text[index - 1] ?? ""))
    ) {
      let end = text.indexOf(run, index + run.length)
      while (end !== -1) {
        if (text[end + run.length] === run[0]) {
          end = text.indexOf(run, end + run.length + 1)
          continue
        }
        if (!/\s/.test(text[end - 1]) && !(run[0] === "_" && /\w/.test(text[end + run.length] ?? ""))) break
        end = text.indexOf(run, end + run.length)
      }
      if (end !== -1) {
        const from = base + index + run.length
        const to = base + end
        ranges.push({ from: base + index, to: from, style: "marker" })
        if (to > from && run.length >= 2) ranges.push({ from, to, style: "strong" })
        if (to > from && run.length !== 2) ranges.push({ from, to, style: "emphasis" })
        ranges.push({ from: to, to: to + run.length, style: "marker" })
        scanInline(text.slice(index + run.length, end), from, ranges)
        index = end + run.length
        continue
      }
    }
    index += 1
  }
}

const priority: Record<Style, number> = {
  code: 90,
  fence: 90,
  link: 80,
  url: 78,
  heading: 70,
  attention: 60,
  quote: 40,
  list: 35,
  marker: 10,
  strong: 0,
  emphasis: 0,
}

// Keep tokenization cached across cursor movements and reference-only updates.
export const composerMarkdown = StateField.define<MarkdownRange[]>({
  create: (state) => tokenizeMarkdown(state.doc.toString()),
  update: (ranges, transaction) => (transaction.docChanged ? tokenizeMarkdown(transaction.newDoc.toString()) : ranges),
  provide: (field) =>
    EditorView.decorations.compute([field, composerReferences], (state) => {
      const references = state.field(composerReferences)
      const ranges = state.field(field).toSorted((a, b) => a.from - b.from)
      const bounds = [...new Set([...ranges, ...references].flatMap((range) => [range.from, range.to]))].toSorted(
        (a, b) => a - b,
      )
      const active: MarkdownRange[] = []
      let next = 0
      return Decoration.set(
        bounds.flatMap((from, index) => {
          const to = bounds[index + 1]
          if (to === undefined || references.some((reference) => reference.from <= from && reference.to >= to))
            return []
          while (next < ranges.length && ranges[next].from <= from) active.push(ranges[next++])
          const covering = active.filter((range) => range.to > from)
          active.splice(0, active.length, ...covering)
          if (!covering.length) return []
          const winner = covering.reduce((best, range) => (priority[range.style] > priority[best.style] ? range : best))
          const styles = new Set([
            winner.style,
            ...covering
              .filter((range) => range.style === "strong" || range.style === "emphasis")
              .map((range) => range.style),
          ])
          return [
            Decoration.mark({ class: [...styles].map((style) => `composer-md-${style}`).join(" ") }).range(from, to),
          ]
        }),
        true,
      )
    }),
})

export function markdownKeyEdit(state: EditorState, key: string): TransactionSpec | undefined {
  const selection = state.selection.main
  const pairs: Record<string, string> = {
    "`": "`",
    "*": "*",
    _: "_",
    "~": "~",
    "(": ")",
    "[": "]",
    "{": "}",
    '"': '"',
    "'": "'",
  }
  if (!selection.empty && pairs[key]) {
    return {
      changes: [
        { from: selection.from, insert: key },
        { from: selection.to, insert: pairs[key] },
      ],
      selection: { anchor: selection.anchor + 1, head: selection.head + 1 },
      annotations: [isolateHistory.of("full"), Transaction.userEvent.of("input.type")],
    }
  }
  if (
    key !== "`" ||
    !selection.empty ||
    !/^\s*``$/.test(state.sliceDoc(state.doc.lineAt(selection.from).from, selection.from))
  )
    return
  return {
    changes: { from: selection.from, insert: "`\n\n```" },
    selection: { anchor: selection.from + 2 },
    annotations: [isolateHistory.of("full"), Transaction.userEvent.of("input.type")],
  }
}

export function markdownLinkEdit(state: EditorState, url: string): TransactionSpec | undefined {
  const selection = state.selection.main
  const selected = state.sliceDoc(selection.from, selection.to)
  if (
    !/^(https?:\/\/|mailto:)\S+$/i.test(url) ||
    !selected.trim() ||
    /^(https?:\/\/|mailto:)\S+$/i.test(selected.trim()) ||
    selected.includes("](")
  )
    return
  return {
    changes: [
      { from: selection.from, insert: "[" },
      { from: selection.to, insert: `](${url})` },
    ],
    selection: { anchor: selection.to + url.length + 4 },
    annotations: [isolateHistory.of("full"), Transaction.userEvent.of("input.paste")],
  }
}
