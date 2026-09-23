import { describe, expect, test } from "bun:test"
import { explorerAbsolute, explorerDisplay, explorerParent, explorerQuery, explorerRows, explorerSubmission } from "./explorer-query"

const home = "/Users/alex"

describe("project explorer", () => {
  test("splits the query into the browsed directory and the child filter", () => {
    expect(explorerQuery("~/", home)).toEqual({ directory: "~/", filter: "", browsed: home, target: home })
    expect(explorerQuery("~/Dev/op", home)).toEqual({
      directory: "~/Dev/",
      filter: "op",
      browsed: "/Users/alex/Dev",
      target: "/Users/alex/Dev/op",
    })
    expect(explorerQuery("/tmp//work/", home).browsed).toBe("/tmp/work")
    expect(explorerQuery("relative/", home).browsed).toBe("")
  })

  test("expands only a leading tilde segment", () => {
    expect(explorerAbsolute("~", home)).toBe(home)
    expect(explorerAbsolute("~alex/", home)).toBe("")
    expect(explorerAbsolute("~/Dev", "")).toBe("")
    expect(explorerAbsolute("/a/b/../c/", home)).toBe("/a/c")
  })

  test("displays forward-slash directory paths relative to home", () => {
    expect(explorerDisplay("/Users/alex", home)).toBe("~/")
    expect(explorerDisplay("/Users/alex/Dev/", home)).toBe("~/Dev/")
    expect(explorerDisplay("/Users/alexandra", home)).toBe("/Users/alexandra/")
    expect(explorerDisplay("C:\\OpenCode\\NewProject", "")).toBe("C:/OpenCode/NewProject/")
    expect(explorerParent("C:/OpenCode/", "")).toBe("C:/")
    expect(explorerParent("C:/", "")).toBeUndefined()
  })

  test("walks up past the home directory to the filesystem root", () => {
    expect(explorerParent("~/Dev/", home)).toBe("~/")
    expect(explorerParent("~/", home)).toBe("/Users/")
    expect(explorerParent("/Users/", home)).toBe("/")
    expect(explorerParent("/", home)).toBeUndefined()
    expect(explorerParent("~/Dev/op", home)).toBeUndefined()
  })

  test("filters by case-insensitive prefix, hides dot folders, and marks added projects", () => {
    const entries = [
      { name: "opencode", absolute: "/Users/alex/Dev/opencode" },
      { name: ".config", absolute: "/Users/alex/Dev/.config" },
      { name: "Abacato", absolute: "/Users/alex/Dev/Abacato" },
      { name: "openchamber", absolute: "/Users/alex/Dev/openchamber/" },
    ]
    const added = new Set(["/Users/alex/Dev/openchamber"])
    expect(explorerRows({ entries, filter: "", hidden: false, added }).map((row) => row.name)).toEqual([
      "Abacato",
      "openchamber",
      "opencode",
    ])
    expect(explorerRows({ entries, filter: "OPEN", hidden: false, added })).toEqual([
      { name: "openchamber", absolute: "/Users/alex/Dev/openchamber", added: true },
      { name: "opencode", absolute: "/Users/alex/Dev/opencode", added: false },
    ])
    expect(explorerRows({ entries, filter: ".c", hidden: false, added }).map((row) => row.name)).toEqual([".config"])
    expect(explorerRows({ entries, filter: "", hidden: true, added })).toHaveLength(4)
  })

  test("chooses between selected, existing, added, and new project targets", () => {
    const rows = [{ name: "opencode", absolute: "/Users/alex/Dev/opencode" }]
    const base = { home, selected: [], added: new Set(["/Users/alex/Dev/added"]), readable: true, rows }
    expect(explorerSubmission({ ...base, query: "~/Dev/", selected: ["/a", "/b"] })).toEqual({
      type: "selected",
      paths: ["/a", "/b"],
    })
    expect(explorerSubmission({ ...base, query: "~/Dev/" })).toEqual({ type: "existing", path: "/Users/alex/Dev" })
    expect(explorerSubmission({ ...base, query: "~/Dev/opencode" })).toEqual({
      type: "existing",
      path: "/Users/alex/Dev/opencode",
    })
    expect(explorerSubmission({ ...base, query: "~/Dev/open" })).toEqual({
      type: "create",
      path: "/Users/alex/Dev/open",
    })
    expect(explorerSubmission({ ...base, query: "~/Dev/added" })).toEqual({
      type: "added",
      path: "/Users/alex/Dev/added",
    })
    expect(explorerSubmission({ ...base, query: "~/Dev/open", readable: false })).toBeUndefined()
  })
})
