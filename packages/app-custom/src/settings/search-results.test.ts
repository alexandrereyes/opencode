import { describe, expect, test } from "bun:test"
import en from "@/runtime/i18n/en"
import { settingsSearchIndex, settingsSearchProjects, type SettingsSearchServer } from "./search-index"
import { rankSettings } from "./search-results"
import type { SettingsView } from "./surface"

const project = { id: "proj_opencode", name: "OpenCode", worktree: "/projects/opencode", expanded: false }
const servers: SettingsSearchServer[] = [
  { key: "local", name: "Local server", connected: true, projects: [project] },
  { key: "remote", name: "Build server", connected: true, projects: [project] },
]
const root: SettingsView = { type: "root", tab: "general" }

function index(input: Partial<Parameters<typeof settingsSearchIndex>[0]> = {}) {
  return settingsSearchIndex({
    servers,
    desktop: false,
    browser: false,
    dev: false,
    mobile: false,
    translate: ((key: keyof typeof en) => en[key]) as Parameters<typeof settingsSearchIndex>[0]["translate"],
    ...input,
  })
}

describe("settings search index", () => {
  test("uses concrete server identity and adapts single-server destinations", () => {
    const multi = rankSettings("models", index(), root).filter((item) => item.topLevel)
    expect(multi.map((item) => item.view)).toEqual([
      { type: "server", server: "local", tab: "models" },
      { type: "server", server: "remote", tab: "models" },
    ])
    const single = rankSettings("models", index({ servers: [servers[0]] }), root).find((item) => item.topLevel)!
    expect(single.view).toEqual({ type: "root", tab: "models" })
  })

  test("keeps unavailable servers discoverable without advertising unloaded pages", () => {
    const items = index({ servers: [{ ...servers[0], connected: false }] })
    expect(items.filter((item) => item.server).map((item) => item.id)).toEqual(["server:local"])
    expect(rankSettings("Local server", items, root)[0].view).toEqual({ type: "root", tab: "servers" })
    expect(rankSettings("models", items, root)).toEqual([])
  })

  test("only advertises controls supported by this platform and channel", () => {
    const targets = (input: Parameters<typeof index>[0]) => index(input).map((item) => item.view.target)
    expect(targets({})).not.toContain("settings-pinch-zoom")
    expect(targets({})).not.toContain("settings-experimental-browser")
    expect(targets({})).not.toContain("settings-show-project-icon")
    expect(targets({ desktop: true })).toContain("settings-pinch-zoom")
    expect(targets({ browser: true })).toContain("settings-experimental-browser")
    expect(targets({ dev: true })).toContain("settings-show-project-icon")
    expect(targets({ dev: true })).not.toContain("settings-mobile-titlebar-bottom")
    expect(targets({ dev: true, mobile: true })).toContain("settings-mobile-titlebar-bottom")
  })

  test("includes custom pages and controls without dead dialog targets", () => {
    const items = index({ servers: [servers[0]] })
    expect(rankSettings("snippets", items, root)[0].view).toEqual({ type: "root", tab: "snippets" })
    expect(rankSettings("command palette", items, root)[0].view.target).toBe("settings-show-search")
    expect(rankSettings("server status", items, root)[0].view.target).toBe("settings-show-status")
    expect(items.some((item) => item.view.target?.startsWith("settings-project-"))).toBe(false)
  })

  test("indexes manual model selection as a page without loading model entries", () => {
    const items = index({ servers: [servers[0]] })
    expect(rankSettings("manual favorites", items, root).map((item) => item.view)).toEqual([
      { type: "root", tab: "models" },
    ])
    expect(items.some((item) => item.id.startsWith("model:"))).toBe(false)
  })

  test("uses stable identities and live project page destinations", () => {
    const items = index()
    expect(new Set(items.map((item) => item.id)).size).toBe(items.length)
    expect(
      index({
        translate: ((key: keyof typeof en) => `translated ${en[key]}`) as Parameters<
          typeof settingsSearchIndex
        >[0]["translate"],
      }).map((item) => item.id),
    ).toEqual(items.map((item) => item.id))
    expect(rankSettings("OpenCode", items, root).map((item) => item.entity)).toEqual([true, true])
    expect(rankSettings("OpenCode extensions", items, root).map((item) => item.view.tab)).toEqual([
      "extensions",
      "extensions",
    ])
    expect(rankSettings("OpenCode skills", items, root).map((item) => item.view.subtab)).toEqual(["skills", "skills"])
  })

  test("enriches only tracked projects and does not resurrect closed or untracked sync entries", () => {
    const tracked = [{ ...project, name: "Tracked name" }]
    const projects = settingsSearchProjects(tracked, [
      { ...project, name: "Enriched tracked name" },
      { id: "proj_untracked", name: "Untracked only", worktree: "/projects/untracked" },
      { id: "proj_closed", name: "Closed only", worktree: "/projects/closed" },
    ])
    const items = index({ servers: [{ ...servers[0], projects }] })

    expect(projects).toEqual([{ ...project, name: "Enriched tracked name" }])
    expect(rankSettings("Enriched tracked name", items, root).map((item) => item.entity)).toEqual([true])
    expect(rankSettings("Untracked only", items, root)).toEqual([])
    expect(rankSettings("Closed only", items, root)).toEqual([])
  })
})

describe("settings search ranking", () => {
  test("prioritizes top-level pages and custom targets", () => {
    expect(rankSettings("snip", index(), root)[0].title).toBe("Snippets")
    expect(rankSettings("dark mode", index(), root)[0].view.target).toBe("settings-color-scheme")
    expect(rankSettings("termfont", index(), root)[0].title).toBe("Terminal Font")
  })

  test("qualifies project pages and ranks equivalent matches by origin", () => {
    expect(
      rankSettings("Build server OpenCode extensions", index(), root)
        .filter((item) => !item.view.subtab)
        .map((item) => item.server),
    ).toEqual(["remote"])
    const origin: SettingsView = {
      type: "project",
      server: "remote",
      project: project.worktree,
      tab: "general",
      parent: "server",
    }
    expect(
      rankSettings("OpenCode extensions", index(), origin)
        .filter((item) => !item.view.subtab)
        .map((item) => item.server),
    ).toEqual(["remote", "local"])
  })

  test("normalizes queries while rejecting paths and unrelated values", () => {
    const items = index({ servers: [{ ...servers[0], projects: [{ ...project, name: "Open Code" }] }] })
    expect(rankSettings("  ＯＰＥＮ   ＣＯＤＥ   extensions  ", items, root)[0].view.tab).toBe("extensions")
    expect(rankSettings("/projects/opencode", items, root)).toEqual([])
    expect(rankSettings("  ", items, root)).toEqual([])
    expect(rankSettings("zzzzzzzzz", items, root)).toEqual([])
  })
})
