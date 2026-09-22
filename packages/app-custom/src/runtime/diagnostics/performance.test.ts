import { describe, expect, test } from "bun:test"
import { createNavigationDiagnostics, createPerformanceHistory, requestLabel, retentionMs } from "./performance"

describe("performance history", () => {
  test("bounds memory and exports surviving entries in chronological order", () => {
    let now = 0
    const history = createPerformanceHistory(() => now++, 3)
    Array.from({ length: 5 }, (_, id) => history.record("test", { id }))
    expect(history.snapshot().entries.map((entry) => entry.data.id)).toEqual([2, 3, 4])
    expect(history.snapshot().overwritten).toBe(2)
  })
  test("expires entries even when no new records arrive", () => {
    let now = 0
    const history = createPerformanceHistory(() => now)
    history.record("old")
    now = retentionMs + 1
    expect(history.snapshot().entries).toEqual([])
  })
  test("removes origin, credentials, query, fragment and dynamic path values", () => {
    expect(
      requestLabel(
        "https://user:secret@private.example/api/session/ses_private/message?directory=/secret&token=secret#secret",
      ),
    ).toBe("api/session/:param/:param")
    expect(requestLabel("https://private.example/private/secret")).toBe("other")
  })
  test("correlates navigation phases and drops superseded paint", () => {
    let now = 10
    const history = createPerformanceHistory(() => now)
    const navigation = createNavigationDiagnostics(history, () => now)
    navigation.click("ses_a", 80)
    now = 30
    navigation.route("ses_a")
    now = 50
    const paint = navigation.ready("ses_a")
    now = 70
    paint(true)
    expect(history.snapshot().entries.map((entry) => entry.data.elapsedMs)).toEqual([undefined, 20, 40, 60])
    navigation.click("ses_b", 0)
    paint(true)
    expect(history.snapshot().entries.filter((entry) => entry.type === "session.paint-opportunity")).toHaveLength(1)
  })
})
