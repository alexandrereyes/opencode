import { describe, expect, test } from "bun:test"
import { admitMessages, createHistoryAdmission } from "./history-admission"

describe("history admission", () => {
  const messages = ["a", "b", "c", "d"].map((id) => ({ id }))

  test("hides a prepended prefix only while held", () => {
    expect(admitMessages(messages, "c", true)).toEqual([{ id: "c" }, { id: "d" }])
    expect(admitMessages(messages, "c", false)).toBe(messages)
  })

  test("keeps the same array when nothing was prepended or the boundary disappeared", () => {
    expect(admitMessages(messages, "a", true)).toBe(messages)
    expect(admitMessages(messages, "removed", true)).toBe(messages)
    expect(admitMessages(messages, undefined, true)).toBe(messages)
  })

  test("keeps admitted messages live, including appended ones", () => {
    const next = [...messages, { id: "e" }]
    expect(admitMessages(next, "c", true)).toEqual([{ id: "c" }, { id: "d" }, { id: "e" }])
  })

  test("waits for further pages only after one arrived during the hold", () => {
    const admission = createHistoryAdmission()
    admission.loaded()
    expect(admission.waiting()).toBe(false)
    admission.hold()
    expect(admission.waiting()).toBe(false)
    admission.loaded()
    expect(admission.waiting()).toBe(true)
    admission.release()
    expect(admission.held()).toBe(false)
    expect(admission.waiting()).toBe(false)
    admission.hold()
    expect(admission.waiting()).toBe(false)
  })
})
