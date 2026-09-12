import { describe, expect, test } from "bun:test"
import { Schema } from "effect"
import fixture from "./fixtures/open-computer-use-apps.json"
import { parseApps } from "../src/app-mentions"
import { AppMentions } from "../src/rpc"

describe("app mentions", () => {
  test("parses Open Computer Use output without inventing paths", () => {
    const apps = parseApps(fixture.content[0].text, "open-computer-use")
    expect(apps).toHaveLength(3)
    expect(apps[0]).toEqual({
      server: "open-computer-use",
      name: "Safari",
      bundleID: "com.apple.Safari",
      running: true,
    })
    expect(apps.every((app) => !("path" in app))).toBe(true)
  })

  test("preserves legacy paths and deduplicates bundle IDs", () => {
    const apps = parseApps(
      [
        "Safari — /System/Applications/Safari.app/ — com.apple.Safari [running]",
        "Safari — /Applications/Safari.app — com.apple.Safari [running]",
        "CotEditor — /Applications/CotEditor.app — com.coteditor.CotEditor [last-used=2026-09-08]",
      ].join("\n"),
      "codex-computer-use",
    )
    expect(apps).toEqual([
      {
        server: "codex-computer-use",
        name: "Safari",
        path: "/System/Applications/Safari.app/",
        bundleID: "com.apple.Safari",
        running: true,
      },
      {
        server: "codex-computer-use",
        name: "CotEditor",
        path: "/Applications/CotEditor.app",
        bundleID: "com.coteditor.CotEditor",
        running: false,
      },
    ])
  })

  test("ignores errors and unsupported output", () => {
    expect(parseApps("Computer Use is unavailable\n[]", "codex-computer-use")).toEqual([])
  })

  test("decodes persisted app references with an omitted path", () => {
    expect(
      Schema.decodeUnknownSync(AppMentions.App)({
        server: "open-computer-use",
        name: "Safari",
        bundleID: "com.apple.Safari",
        running: true,
      }),
    ).toEqual({
      server: "open-computer-use",
      name: "Safari",
      bundleID: "com.apple.Safari",
      running: true,
    })
  })
})
