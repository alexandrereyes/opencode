import { describe, expect, test } from "bun:test"
import { ComputerUse } from "../../src/mcp/computer-use"

describe("codex-computer-use app catalog", () => {
  test("parses running and previously used apps from the actual text format", () => {
    const apps = ComputerUse.parseApps(
      [
        "Safari — /System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/ — com.apple.Safari [running]",
        "Espelhamento do iPhone — /System/Applications/iPhone Mirroring.app/ — com.apple.ScreenContinuity [frontmost, running, last-used=2026-09-08, uses=61]",
        "CotEditor — /Applications/CotEditor.app — com.coteditor.CotEditor [last-used=2026-09-08, uses=736]",
        "Safari — /Applications/Safari.app — com.apple.Safari [running]",
        "No apps found",
        "Invalid — relative.app — bad [running]",
      ].join("\n"),
      "codex-computer-use",
    )
    expect(apps).toHaveLength(3)
    expect(apps[0]).toEqual({
      server: "codex-computer-use",
      name: "Safari",
      path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/",
      bundleID: "com.apple.Safari",
      running: true,
    })
    expect(apps[1].running).toBe(true)
    expect(apps[2].running).toBe(false)
  })

  test("does not invent apps from errors or an unsupported response", () => {
    expect(ComputerUse.parseApps("Computer Use is unavailable\n[]", "codex-computer-use")).toEqual([])
  })
})
