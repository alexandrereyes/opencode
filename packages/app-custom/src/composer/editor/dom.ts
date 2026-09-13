type ComposerEditorBinding = {
  selection: () => { start: number; end: number }
  setSelection: (start: number, end: number) => void
}

const bindings = new WeakMap<HTMLElement, ComposerEditorBinding>()

export function bindComposerEditor(parent: HTMLElement, binding: ComposerEditorBinding) {
  bindings.set(parent, binding)
  return () => bindings.delete(parent)
}

export function getCursorPosition(parent: HTMLElement) {
  return bindings.get(parent)?.selection().end ?? 0
}

export function getSelectionRange(parent: HTMLElement) {
  return bindings.get(parent)?.selection()
}

export function setCursorPosition(parent: HTMLElement, position: number) {
  bindings.get(parent)?.setSelection(position, position)
}
