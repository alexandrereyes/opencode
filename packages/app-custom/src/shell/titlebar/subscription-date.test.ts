import { describe, expect, test } from "bun:test"
import {
  formatSubscriptionCountdown,
  formatSubscriptionDate,
  formatSubscriptionExpiry,
  formatSubscriptionShortDate,
} from "./subscription-date"

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

  test("shows the compact renewal date with a 24-hour time", () => {
    expect(formatSubscriptionShortDate(date, "pt-BR")).toBe("sáb., 19/09 05:14")
  })

  test("switches the countdown between fractional days, hours and minutes", () => {
    const after = (minutes: number) => new Date(date + minutes * 60_000).toISOString()
    expect(formatSubscriptionCountdown(after(7.3 * 1440), date)).toBe("7.3d")
    expect(formatSubscriptionCountdown(after(1440), date)).toBe("1d")
    expect(formatSubscriptionCountdown(after(1439), date)).toBe("23h")
    expect(formatSubscriptionCountdown(after(420), date)).toBe("7h")
    expect(formatSubscriptionCountdown(after(10), date)).toBe("10m")
    expect(formatSubscriptionCountdown(after(-1), date)).toBe("0m")
    expect(formatSubscriptionCountdown(null, date)).toBe("—")
  })

  test("omits minutes from banked expiry while days remain", () => {
    const after = (minutes: number) => new Date(date + minutes * 60_000).toISOString()
    expect(formatSubscriptionExpiry(after(7 * 1440 + 8 * 60 + 10), date)).toBe("7d 8h")
    expect(formatSubscriptionExpiry(after(1440 + 10), date)).toBe("1d")
    expect(formatSubscriptionExpiry(after(8 * 60 + 10), date)).toBe("8h 10m")
    expect(formatSubscriptionExpiry(after(600), date)).toBe("10h")
    expect(formatSubscriptionExpiry(after(5), date)).toBe("5m")
    expect(formatSubscriptionExpiry(after(-1), date)).toBe("0m")
  })
})
