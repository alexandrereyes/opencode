import { expect, test } from "bun:test"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import { createComposerEditor } from "@/composer/editor/interaction"
import type { ComposerPersistedState } from "@/composer/types"

test("composition keys leave the composer mode and actions untouched", () => {
  createRoot((dispose) => {
    const actions: string[] = []
    const store = createStore<ComposerPersistedState>({
      prompt: [{ type: "text", content: "configuração", start: 0, end: 12 }],
      context: { items: [] },
      mode: "shell",
    })
    const editor = createComposerEditor({
      store,
      commands: () => [],
      context: () => [],
      searchContextFiles: () => [],
      view: {
        add: { onAttach: () => actions.push("attach") },
        submit: {
          stopping: () => false,
          working: () => true,
          onStop: () => actions.push("stop"),
          onSubmit: () => actions.push("submit"),
        },
      },
    })

    for (const init of [
      { key: "Escape", isComposing: true },
      { key: "Escape", keyCode: 229 },
      { key: "Enter", isComposing: true },
      { key: "Dead" },
    ]) {
      const event = new KeyboardEvent("keydown", { ...init, cancelable: true })
      expect(editor.onKeyDown(event)).toBe(true)
      expect(event.defaultPrevented).toBe(false)
      expect(editor.state.mode).toBe("shell")
    }

    editor.onKeyDown(new KeyboardEvent("keydown", { key: "Escape" }))
    expect(editor.state.mode).toBe("normal")
    for (const init of [{ isComposing: true }, { keyCode: 229 }]) {
      editor.onKeyDown(new KeyboardEvent("keydown", { key: "u", metaKey: true, ...init }))
      editor.onKeyDown(new KeyboardEvent("keydown", { key: "Escape", ...init }))
    }
    expect(actions).toEqual([])
    expect(editor.value()).toBe("configuração")

    editor.onKeyDown(new KeyboardEvent("keydown", { key: "u", metaKey: true }))
    editor.onKeyDown(new KeyboardEvent("keydown", { key: "Escape" }))
    expect(actions).toEqual(["attach", "stop"])
    dispose()
  })
})
