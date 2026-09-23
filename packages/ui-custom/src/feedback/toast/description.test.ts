import { expect, test } from "bun:test"
import { boundToastDescription, toastDescriptionLimit } from "./description"

test("bounds oversized descriptions before retention and keeps short options unchanged", () => {
  const short = { title: "Failure", description: "Upload failed" }
  expect(boundToastDescription(short)).toBe(short)
  const bounded = boundToastDescription({ ...short, description: `data:image/png;base64,${"A".repeat(50000)}` })
  expect(bounded.description.length).toBe(toastDescriptionLimit + 1)
  expect(bounded.description.endsWith("…")).toBe(true)
  expect(bounded.title).toBe(short.title)
})
