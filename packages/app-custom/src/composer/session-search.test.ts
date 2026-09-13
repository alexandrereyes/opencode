import { describe, expect, test } from "bun:test"
import type { SessionInfo } from "@opencode/client/promise"
import { createSessionSearch } from "./session-search"

const session = (id: string, archived = false, parentID?: string) =>
  ({
    id,
    projectID: "project",
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    time: { created: 1, updated: 1, archived: archived ? 2 : undefined },
    title: id,
    location: { directory: `/work/${id}` },
    parentID,
  }) as SessionInfo

describe("composer session search", () => {
  test("loads recent global sessions without a query and filters current, archived, and child sessions", async () => {
    const calls: string[] = []
    const search = createSessionSearch({
      list: async (query) => {
        calls.push(query)
        return [
          session("ses_current"),
          session("ses_recent"),
          session("ses_archived", true),
          session("ses_child", false, "ses_parent"),
        ]
      },
      get: async (id) => session(id),
      current: () => "ses_current",
      debounce: 0,
    })

    expect((await search.load("")).map((item) => item.id)).toEqual(["ses_recent"])
    expect(calls).toEqual([""])
  })

  test("discards an older result after a newer query starts", async () => {
    const pending = new Map<string, (sessions: SessionInfo[]) => void>()
    const search = createSessionSearch({
      list: (query) => new Promise((resolve) => pending.set(query, resolve)),
      get: async (id) => session(id),
      current: () => undefined,
      debounce: 0,
    })

    const old = search.load("old")
    await Promise.resolve()
    const current = search.load("current")
    await Promise.resolve()
    pending.get("current")?.([session("ses_current")])
    pending.get("old")?.([session("ses_old")])

    expect((await current).map((item) => item.id)).toEqual(["ses_current"])
    expect(await old).toEqual([])
  })

  test("deduplicates an exact session ID against title search results", async () => {
    const exact = session("ses_exact_12345678901234567890")
    let gets = 0
    const search = createSessionSearch({
      list: async () => [exact],
      get: async () => {
        gets++
        return exact
      },
      current: () => undefined,
      debounce: 0,
    })

    expect((await search.load(exact.id)).map((item) => item.id)).toEqual([exact.id])
    expect(gets).toBe(1)
  })

  test("filters child sessions from title and exact ID results", async () => {
    const child = session("ses_child_12345678901234567890", false, "ses_parent")
    const search = createSessionSearch({
      list: async () => [child],
      get: async () => child,
      current: () => undefined,
      debounce: 0,
    })

    expect(await search.load("child")).toEqual([])
    expect(await search.load(child.id)).toEqual([])
  })
})
