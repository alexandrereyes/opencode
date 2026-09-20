import { describe, expect, test } from "bun:test"
import { parentSettingsView, projectSettingsView, selectSettingsView, type SettingsView } from "./surface"

describe("settings scoped routing", () => {
  test("selects root custom pages without losing the root scope", () => {
    const root: SettingsView = { type: "root", tab: "general" }

    expect(selectSettingsView(root, "snippets")).toEqual({ type: "root", tab: "snippets" })
    expect(selectSettingsView(root, "about")).toEqual({ type: "root", tab: "about" })
    expect(selectSettingsView(root, "invalid")).toBe(root)
  })

  test("selects only tabs valid for the current contextual scope", () => {
    const server: SettingsView = { type: "server", server: "server-a", tab: "general" }
    const project: SettingsView = {
      type: "project",
      server: "server-a",
      project: "/repo",
      tab: "general",
      parent: "server",
    }

    expect(selectSettingsView(server, "models")).toEqual({ ...server, tab: "models" })
    expect(selectSettingsView(server, "appearance")).toBe(server)
    expect(selectSettingsView(project, "extensions")).toEqual({ ...project, tab: "extensions" })
    expect(selectSettingsView(project, "models")).toBe(project)
  })

  test("backs through project and server context", () => {
    expect(parentSettingsView({ type: "server", server: "server-a", tab: "projects" })).toEqual({
      type: "root",
      tab: "general",
    })
    expect(
      parentSettingsView({
        type: "project",
        server: "server-a",
        project: "/repo",
        tab: "general",
        parent: "server",
      }),
    ).toEqual({ type: "server", server: "server-a", tab: "projects" })
    expect(
      parentSettingsView({
        type: "project",
        server: "server-a",
        project: "/repo",
        tab: "general",
        parent: "root",
      }),
    ).toEqual({ type: "root", tab: "projects" })
  })

  test("records the actual origin scope for a project", () => {
    expect(
      projectSettingsView({ type: "root", tab: "projects" }, { server: "server-a", project: "/repo" }),
    ).toMatchObject({ type: "project", parent: "root" })
    expect(
      projectSettingsView(
        { type: "server", server: "server-a", tab: "projects" },
        { server: "server-a", project: "/repo" },
      ),
    ).toMatchObject({ type: "project", parent: "server" })
  })
})
