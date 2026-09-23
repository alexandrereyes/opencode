import { describe, expect, test } from "bun:test"
import { createReadingPositions } from "./reading-position"

describe("reading positions", () => {
  const anchor = { rowKey: "row", messageID: "message", offset: 1500 }
  test("anchor and follow updates preserve independent intent and session ownership", () => {
    const positions = createReadingPositions()
    positions.follow("A", false)
    positions.follow("B", true)
    positions.anchor("A", anchor)
    expect(positions.get("A")).toEqual({ pinned: false, anchor })
    expect(positions.get("B")).toEqual({ pinned: true })
    positions.follow("A", true)
    expect(positions.get("A")).toEqual({ pinned: true, anchor })
  })
  test("retains the 200 most recently accessed sessions", () => {
    const positions = createReadingPositions()
    Array.from({ length: 200 }, (_, i) => positions.follow(String(i), false))
    positions.get("0")
    positions.anchor("200", anchor)
    expect(positions.get("1")).toBeUndefined()
    expect(positions.get("0")).toEqual({ pinned: false })
    expect(positions.get("200")).toEqual({ pinned: true, anchor })
    positions.follow("2", true)
    positions.follow("201", true)
    expect(positions.get("3")).toBeUndefined()
    expect(positions.get("2")).toEqual({ pinned: true })
  })
})
