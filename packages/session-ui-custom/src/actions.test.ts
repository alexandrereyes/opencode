import { describe, expect, test } from "bun:test"
import { pendingSteerPresentation } from "./actions"

describe("pendingSteerPresentation", () => {
  test.each([
    { status: undefined, actions: false, waiting: false },
    { status: "queued" as const, actions: false, waiting: false },
    { status: "starting" as const, actions: true, waiting: false },
    { status: "steering" as const, actions: true, waiting: true },
    { status: "stranded" as const, actions: true, waiting: true },
  ])("$status", (row) => {
    expect(pendingSteerPresentation(row.status)).toEqual({ actions: row.actions, waiting: row.waiting })
  })
})
