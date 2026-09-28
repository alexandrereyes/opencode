import { describe, expect, test } from "bun:test"
import { createUiI18n, pluralCategory, useI18n } from "./i18n"

describe("pluralCategory", () => {
  test.each([
    ["en", 0, "other"],
    ["en", 1, "one"],
    ["fr", 0, "one"],
    ["fr", 1_000_000, "many"],
    ["ru", 1, "one"],
    ["ru", 2, "few"],
    ["ru", 5, "many"],
    ["ru", 21, "one"],
    ["ar", 0, "zero"],
    ["ar", 1, "one"],
    ["ar", 2, "two"],
    ["ar", 3, "few"],
    ["ar", 11, "many"],
    ["ar", 100, "other"],
    ["ja", 1, "other"],
  ] as const)("selects %s for %d as %s", (locale, count, expected) => {
    expect(pluralCategory(locale, count)).toBe(expected)
  })
})

test("dynamic English preserves runtime copy and other locales use the dictionary fallback", () => {
  const english = useI18n()
  const portuguese = createUiI18n({ ...english, locale: () => "pt-BR" })
  expect(english.tDynamic("ui.sessionTimeline.notice.restart", "Resuming {{name}}", { name: "work" })).toBe(
    "Resuming work",
  )
  expect(portuguese.tDynamic("ui.sessionTimeline.notice.restart", "Runtime English")).toBe("Continuing after restart")
})

test("tool lists preserve English commas and use localized separators", () => {
  const english = useI18n()
  const portuguese = createUiI18n({ ...english, locale: () => "pt-BR" })
  expect(english.list(["Read", "Edit", "Shell"])).toBe("Read, Edit, Shell")
  expect(english.listSeparator(2, 3)).toBe(",")
  expect(portuguese.list(["Read", "Edit", "Shell"])).toBe("Read, Edit e Shell")
  expect(portuguese.listSeparator(1, 3)).toBe(", ")
  expect(portuguese.listSeparator(2, 3)).toBe(" e ")
})

test("retry copy is a complete phrase with the attempt and remaining count", () => {
  const i18n = useI18n()
  expect(i18n.plural("ui.sessionTurn.retry.attemptWaiting", 1, { attempt: 2 })).toBe("Attempt 2 - retrying in 1s")
  expect(i18n.plural("ui.sessionTurn.retry.attemptWaiting", 4, { attempt: 2 })).toBe("Attempt 2 - retrying in 4s")
  expect(i18n.t("ui.sessionTurn.retry.attemptRetryingNow", { attempt: 2 })).toBe("Attempt 2 - retrying")
})
