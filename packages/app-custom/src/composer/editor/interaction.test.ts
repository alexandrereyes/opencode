import { expect, test } from "bun:test"
import { shouldHandlePasteAsAttachment } from "./interaction"

test("leaves unavailable and non-plain text clipboard formats to native paste", () => {
  expect(shouldHandlePasteAsAttachment(null, false)).toBe(false)
  expect(shouldHandlePasteAsAttachment({ types: ["text/html"], items: [] } as unknown as DataTransfer, true)).toBe(
    false,
  )
  expect(shouldHandlePasteAsAttachment({ types: ["text/rtf"], items: [] } as unknown as DataTransfer, true)).toBe(false)
  expect(shouldHandlePasteAsAttachment(null, true)).toBe(true)
  expect(
    shouldHandlePasteAsAttachment({ types: [], items: [{ kind: "file" }] } as unknown as DataTransfer, false),
  ).toBe(true)
})
