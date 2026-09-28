import { expect, test } from "bun:test"
import { localizedListParts, richTemplateParts } from "./language"

test("rich interpolation preserves values and accepts spaced placeholders", () => {
  const value = { label: "project" }
  expect(richTemplateParts("Open {{ project }} {{missing}}", { project: value })).toEqual(["Open ", value, " ", ""])
})

test("localized rich lists retain their original elements", () => {
  const first = { label: "Read" }
  const second = { label: "Edit" }
  expect(localizedListParts("pt-BR", [first, second])).toEqual([first, " e ", second])
})
