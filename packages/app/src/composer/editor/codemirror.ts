import { invertedEffects } from "@codemirror/commands"
import { StateEffect, StateField, type ChangeDesc, type Extension } from "@codemirror/state"
import { Decoration, EditorView, type DecorationSet } from "@codemirror/view"
import type { ComposerAttachment, ComposerPrompt } from "../types"
import { normalizeComposerPrompt } from "../prompt-parts"
import { formatSessionReference } from "../session-reference"

export type ComposerReference = Exclude<ComposerPrompt[number], { type: "text" }>

export type ComposerReferenceRange = {
  from: number
  to: number
  part: ComposerReference
  label?: string
}

export const setComposerReferences = StateEffect.define<readonly ComposerReferenceRange[]>({
  map: (references, changes) => mapComposerReferences(references, changes),
})

export const composerReferences = StateField.define<readonly ComposerReferenceRange[]>({
  create: () => [],
  update(references, transaction) {
    const replacement = transaction.effects.find((effect) => effect.is(setComposerReferences))
    if (replacement?.is(setComposerReferences)) return replacement.value
    if (!transaction.docChanged) return references
    return mapComposerReferences(references, transaction.changes)
  },
  provide: (field) => EditorView.decorations.from(field, referenceDecorations),
})

export const composerReferenceHistory: Extension = invertedEffects.of((transaction) => {
  if (!transaction.docChanged && !transaction.effects.some((effect) => effect.is(setComposerReferences))) return []
  return [setComposerReferences.of(transaction.startState.field(composerReferences))]
})

export function composerReferencesFromPrompt(
  prompt: ComposerPrompt,
  labels?: { app: string; session: string },
): ComposerReferenceRange[] {
  let offset = 0
  const normalized = normalizeComposerPrompt(prompt)
  const references = normalized.flatMap((part) => {
    if (part.type === "image") return []
    const from = offset
    offset += part.content.length
    if (part.type === "text") return []
    return [
      {
        from,
        to: offset,
        part: { ...part, start: from, end: offset },
        ...(part.type === "app" ? { label: labels?.app } : part.type === "session" ? { label: labels?.session } : {}),
      },
    ]
  })
  return [
    ...references,
    ...normalized.flatMap((part) => {
      if (part.type !== "image" || !part.mention) return []
      return [{ from: part.mention.start, to: part.mention.end, part }]
    }),
  ].toSorted((a, b) => a.from - b.from)
}

export function composerPromptFromDocument(
  text: string,
  references: readonly ComposerReferenceRange[],
  images: readonly ComposerAttachment[],
): ComposerPrompt {
  const valid = references
    .filter(
      (reference) =>
        reference.from >= 0 &&
        reference.from < reference.to &&
        reference.to <= text.length &&
        text.slice(reference.from, reference.to) === referenceText(reference.part),
    )
    .toSorted((a, b) => a.from - b.from)
  const structured = valid.filter(
    (reference): reference is ComposerReferenceRange & { part: Exclude<ComposerReference, ComposerAttachment> } =>
      reference.part.type !== "image",
  )
  const prompt: ComposerPrompt = []
  let offset = 0
  structured.forEach((reference) => {
    if (reference.from < offset) return
    if (reference.from > offset) {
      prompt.push({ type: "text", content: text.slice(offset, reference.from), start: offset, end: reference.from })
    }
    prompt.push({ ...reference.part, start: reference.from, end: reference.to })
    offset = reference.to
  })
  if (offset < text.length || prompt.length === 0) {
    prompt.push({ type: "text", content: text.slice(offset), start: offset, end: text.length })
  }
  const referenced = valid.flatMap((reference) => {
    if (reference.part.type !== "image") return []
    return [
      {
        ...reference.part,
        mention: { text: text.slice(reference.from, reference.to), start: reference.from, end: reference.to },
      },
    ]
  })
  const ids = new Set(referenced.map((image) => image.id))
  const uncited = images.filter((image) => !image.mention && !ids.has(image.id)).map((image) => ({ ...image }))
  return [...prompt, ...referenced, ...uncited]
}

export function mapComposerReferences(
  references: readonly ComposerReferenceRange[],
  changes: ChangeDesc,
): ComposerReferenceRange[] {
  return references.flatMap((reference) => {
    let edited = false
    changes.iterChangedRanges((fromA, toA) => {
      if (fromA === toA) {
        if (fromA > reference.from && fromA < reference.to) edited = true
        return
      }
      if (fromA < reference.to && toA > reference.from) edited = true
    })
    if (edited) return []
    return [
      {
        ...reference,
        from: changes.mapPos(reference.from, 1),
        to: changes.mapPos(reference.to, -1),
        part:
          reference.part.type === "image"
            ? {
                ...reference.part,
                mention: {
                  text: reference.part.mention?.text ?? "",
                  start: changes.mapPos(reference.from, 1),
                  end: changes.mapPos(reference.to, -1),
                },
              }
            : {
                ...reference.part,
                start: changes.mapPos(reference.from, 1),
                end: changes.mapPos(reference.to, -1),
              },
      },
    ]
  })
}

export function copyComposerText(
  text: string,
  references: readonly ComposerReferenceRange[],
  from: number,
  to: number,
) {
  const sessions = references
    .filter(
      (reference): reference is ComposerReferenceRange & { part: Extract<ComposerReference, { type: "session" }> } =>
        reference.part.type === "session" && reference.from >= from && reference.to <= to,
    )
    .toSorted((a, b) => a.from - b.from)
  if (sessions.length === 0) return
  let offset = from
  return (
    sessions.reduce((result, reference) => {
      const start = Math.max(reference.from, from)
      const end = Math.min(reference.to, to)
      const value = result + text.slice(offset, start) + formatSessionReference(reference.part)
      offset = end
      return value
    }, "") + text.slice(offset, to)
  )
}

function referenceDecorations(references: readonly ComposerReferenceRange[]): DecorationSet {
  return Decoration.set(
    references.map((reference) =>
      Decoration.mark({
        class: "composer-reference",
        attributes: referenceAttributes(reference),
      }).range(reference.from, reference.to),
    ),
    true,
  )
}

function referenceAttributes(reference: ComposerReferenceRange) {
  const part = reference.part
  const mention =
    part.type === "image"
      ? "file"
      : part.type === "file" && part.mime === "application/x-directory"
        ? "reference"
        : part.type
  const base = { "data-mention": mention, dir: "auto", style: "unicode-bidi: isolate" }
  if (part.type === "image") {
    return { ...base, "data-id": part.id, "data-filename": part.filename, title: part.filename }
  }
  if (part.type === "agent") return { ...base, "data-name": part.name }
  if (part.type === "skill") {
    return { ...base, "data-id": part.id, "data-name": part.name }
  }
  if (part.type === "snippet") return { ...base, title: part.expansion }
  if (part.type === "app") {
    return {
      ...base,
      "data-label": reference.label ?? "",
      title: `${part.app.name} — ${part.app.bundleID}${part.app.path ? `\n${part.app.path}` : ""}`,
    }
  }
  if (part.type === "session") {
    return {
      ...base,
      "data-id": part.session.id,
      "data-server": part.session.server,
      ...(part.session.title ? { "data-title": part.session.title } : {}),
      ...(part.session.directory ? { "data-directory": part.session.directory } : {}),
      "data-reference": formatSessionReference(part),
      "data-label": reference.label ?? "",
      title: `${part.session.title ?? part.session.id} — ${part.session.id}${part.session.directory ? `\n${part.session.directory}` : ""}`,
    }
  }
  return {
    ...base,
    "data-path": part.path,
    ...(part.mime ? { "data-mime": part.mime } : {}),
    ...(part.filename ? { "data-filename": part.filename } : {}),
  }
}

function referenceText(part: ComposerReference) {
  return part.type === "image" ? (part.mention?.text ?? "") : part.content
}

export const composerEditorTheme = EditorView.theme({
  "&": {
    backgroundColor: "transparent",
    color: "var(--v2-text-text-base)",
    minHeight: "60px",
  },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": {
    fontFamily: "inherit",
    fontSize: "inherit",
    lineHeight: "inherit",
    overflow: "visible",
  },
  ".cm-content": {
    boxSizing: "border-box",
    minHeight: "60px",
    padding: "16px 16px 8px",
    fontFamily: "inherit",
    fontSize: "13px",
    fontWeight: "440",
    lineHeight: "var(--line-height-base)",
    caretColor: "var(--v2-text-text-base)",
  },
  ".cm-line": { padding: "0" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--v2-text-text-base)" },
  ".cm-selectionBackground, &.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground": {
    backgroundColor: "var(--v2-overlay-simple-overlay-pressed)",
  },
})
