import { describe, expect, test } from "bun:test"
import en from "@/runtime/i18n/en"
import { getCompactRelativeTime, getRelativeTime } from "./time"

const plural: Parameters<typeof getCompactRelativeTime>[1] = (key, count) =>
  en[`${key}.other`].replace("{{count}}", String(count))
const translate: Parameters<typeof getRelativeTime>[1] = (key, params) =>
  en[key].replace("{{count}}", String(params?.count))
const now = Date.UTC(2026, 8, 11, 12)

describe("shared relative time", () => {
  test.each([
    [0, "0s"],
    [999, "0s"],
    [42_000, "42s"],
    [59_999, "59s"],
    [60_000, "1m"],
    [3_599_999, "59m"],
    [3_600_000, "1h"],
    [36_000_000, "10h"],
    [86_399_999, "23h"],
    [86_400_000, "1d"],
    [864_000_000, "10d"],
    [-42_000, "0s"],
  ])("compact age at %i milliseconds is %s", (elapsed, label) => {
    expect(getCompactRelativeTime(now - elapsed, plural, now)).toBe(label)
    expect(getCompactRelativeTime(new Date(now - elapsed).toISOString(), plural, now)).toBe(label)
  })

  test("invalid dates have no label; epoch zero remains a real timestamp", () => {
    for (const value of [NaN, Infinity, "invalid", ""]) {
      expect(getCompactRelativeTime(value, plural, now)).toBe("")
      expect(getRelativeTime(value, translate, now)).toBe("")
    }
    expect(getCompactRelativeTime(0, plural, 42_000)).toBe("42s")
  })

  test("the existing mobile wording stays unchanged", () => {
    expect(getRelativeTime(now + 1000, translate, now)).toBe("Just now")
    expect(getRelativeTime(now - 42_000, translate, now)).toBe("Just now")
    expect(getRelativeTime(now - 60_000, translate, now)).toBe("1m ago")
    expect(getRelativeTime(now - 36_000_000, translate, now)).toBe("10h ago")
    expect(getRelativeTime(now - 86_400_000, translate, now)).toBe("1d ago")
  })
})
