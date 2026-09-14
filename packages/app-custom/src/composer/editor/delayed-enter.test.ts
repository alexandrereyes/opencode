import { describe, expect, test } from "bun:test"
import { preserveDelayedEnterModifiers } from "./delayed-enter"

describe("delayed Enter modifiers", () => {
  test("restores Shift on an editor-generated Enter event", () => {
    const target = document.createElement("div")
    const cleanup = preserveDelayedEnterModifiers(target)
    target.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", shiftKey: true, bubbles: true }))
    const delayed = new KeyboardEvent("keydown", { key: "Enter", bubbles: true })
    Object.defineProperty(delayed, "synthetic", { value: true })

    target.dispatchEvent(delayed)

    expect(delayed.shiftKey).toBe(true)
    cleanup()
  })

  test("does not add modifiers to plain Enter", () => {
    const target = document.createElement("div")
    const cleanup = preserveDelayedEnterModifiers(target)
    target.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }))
    const delayed = new KeyboardEvent("keydown", { key: "Enter", bubbles: true })
    Object.defineProperty(delayed, "synthetic", { value: true })

    target.dispatchEvent(delayed)

    expect(delayed.shiftKey).toBe(false)
    cleanup()
  })
})
