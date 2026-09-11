import { describe, expect, test } from "bun:test"
import { bindComposerEditor, getCursorPosition, getSelectionRange, setCursorPosition } from "./dom"

describe("Composer editor binding", () => {
  test("routes selection reads and writes through the editor engine", () => {
    const element = document.createElement("div")
    const selection = { start: 2, end: 7 }
    const unbind = bindComposerEditor(element, {
      selection: () => selection,
      setSelection: (start, end) => {
        selection.start = start
        selection.end = end
      },
    })

    expect(getSelectionRange(element)).toEqual({ start: 2, end: 7 })
    expect(getCursorPosition(element)).toBe(7)
    setCursorPosition(element, 4)
    expect(getSelectionRange(element)).toEqual({ start: 4, end: 4 })

    unbind()
    expect(getSelectionRange(element)).toBeUndefined()
    expect(getCursorPosition(element)).toBe(0)
  })
})
