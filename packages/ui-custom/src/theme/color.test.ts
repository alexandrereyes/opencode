import { expect, test } from "bun:test"
import { contrastRatio } from "./color"

test("contrast ratio uses WCAG relative luminance weights", () => {
  expect(contrastRatio("#00FF00", "#000000")).toBeCloseTo(15.3, 1)
})
