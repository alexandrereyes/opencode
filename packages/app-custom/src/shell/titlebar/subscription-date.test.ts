import { describe, expect, test } from "bun:test"
import { formatSubscriptionDate } from "./subscription-date"

describe("formatSubscriptionDate", () => {
  const date = new Date(2026, 8, 19, 5, 14).getTime()

  test("places the weekday after regular dates", () => {
    expect(formatSubscriptionDate(date, "en-US")).toBe("19-Sep 05:14 (Saturday)")
  })

  test("places the weekday before weekly quota dates", () => {
    expect(formatSubscriptionDate(date, "en-US", true)).toBe("(Saturday) 19-Sep 05:14")
  })

  test("uses localized month and weekday names", () => {
    expect(formatSubscriptionDate(date, "pt-BR")).toBe("19-set 05:14 (sábado)")
  })
})
