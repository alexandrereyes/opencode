import { describe, expect, test } from "bun:test"
import { createRoot } from "solid-js"
import { createKeybindSettingsController } from "./keybinds"

describe("keybind settings capture", () => {
  test("records option-generated glyphs as their physical letter", () => {
    const values = new Map<string, string>()
    const target = document.implementation.createHTMLDocument()
    const owned = createRoot((dispose) => ({
      dispose,
      controller: createKeybindSettingsController(
        {
          command: {
            catalog: [],
            options: [{ id: "test.action", title: "Test action", keybind: undefined }],
            keybinds: () => {},
          },
          settings: {
            current: { keybinds: {} },
            keybinds: {
              get: (id) => values.get(id) ?? "",
              set: (id, value) => values.set(id, value),
              resetAll: () => values.clear(),
            },
          },
          target,
          notify: () => {},
        },
        {
          locale: () => "en",
          t: (key) => key,
        },
      ),
    }))

    owned.controller.capture.toggle("test.action")
    target.dispatchEvent(
      new KeyboardEvent("keydown", {
        key: "¬",
        code: "KeyL",
        metaKey: true,
        altKey: true,
      }),
    )

    expect(values.get("test.action")).toBe(
      `${/(Mac|iPod|iPhone|iPad)/.test(navigator.platform) ? "mod" : "meta"}+alt+l`,
    )
    expect(owned.controller.capture.active()).toBeNull()
    owned.dispose()
  })
})
