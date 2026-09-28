import { describe, expect, test } from "bun:test"
import { parseSettingsView, settingsViewUrl, type SettingsView } from "./route"

const roundTrip = (view: SettingsView) => parseSettingsView(new URL(settingsViewUrl(view), "http://localhost").search)

describe("settings route", () => {
  test("keeps root preferences at the canonical route", () => {
    expect(settingsViewUrl({ type: "root", tab: "general" })).toBe("/settings")
    expect(parseSettingsView("")).toEqual({ type: "root", tab: "general" })
  })

  test("round trips custom root, server, and project pages with their origin", () => {
    const project: SettingsView = {
      type: "project",
      server: "local",
      project: "C:\\work folder",
      parent: "server",
      tab: "extensions",
      subtab: "lsps",
    }

    expect(roundTrip({ type: "root", tab: "snippets" })).toEqual({ type: "root", tab: "snippets" })
    expect(roundTrip({ type: "server", server: "http://a:4096", tab: "models" })).toEqual({
      type: "server",
      server: "http://a:4096",
      tab: "models",
    })
    expect(roundTrip(project)).toEqual(project)
    expect(roundTrip({ ...project, parent: "root", tab: "general", subtab: undefined })).toEqual({
      ...project,
      parent: "root",
      tab: "general",
      subtab: undefined,
    })
  })

  test("keeps only search reveal state from history", () => {
    const stale = { type: "root", tab: "models", target: "settings-plugin", searchActivation: 2 } as SettingsView

    expect(parseSettingsView("?tab=extensions&subtab=plugins", stale)).toEqual({
      type: "root",
      tab: "extensions",
      subtab: "plugins",
      target: "settings-plugin",
      searchActivation: 2,
    })
  })

  test("falls back for invalid scope and tab combinations", () => {
    expect(parseSettingsView("?tab=unknown")).toEqual({ type: "root", tab: "general" })
    expect(parseSettingsView("?tab=toString")).toEqual({ type: "root", tab: "general" })
    expect(parseSettingsView("?project=%2Fwork&tab=extensions")).toEqual({ type: "root", tab: "general" })
    expect(parseSettingsView("?server=local&tab=snippets")).toEqual({ type: "root", tab: "general" })
    expect(parseSettingsView("?tab=extensions&subtab=lsps")).toEqual({ type: "root", tab: "extensions" })
  })
})
