import { describe, expect, test } from "bun:test"
import { modifierHold, sidebarShortcuts, type ModifierHold, type ModifierHoldEvent } from "./sidebar-shortcuts"

const down = (key: "mod" | "digit" | "other", mod = true, extra = false): ModifierHoldEvent => ({
  type: "keydown",
  mod,
  extra,
  key,
})
const elapsed: ModifierHoldEvent = { type: "elapsed" }

const run = (events: ModifierHoldEvent[]) =>
  events.reduce<ModifierHold>((state, event) => modifierHold(state, event), "idle")

describe("modifierHold", () => {
  test("shows after the mod key is held alone", () => {
    expect(run([down("mod")])).toBe("pending")
    expect(run([down("mod"), down("mod"), elapsed])).toBe("visible")
  })

  test("typing plain keys does not block a later hold", () => {
    expect(run([down("other", false), down("other", false), down("mod"), elapsed])).toBe("visible")
  })

  test("a non-mod modifier alone does not strand the state", () => {
    expect(run([down("other", false, true), down("mod"), elapsed])).toBe("visible")
  })

  test("digits keep visible badges while held", () => {
    expect(run([down("mod"), elapsed, down("digit"), down("digit")])).toBe("visible")
    expect(run([down("mod"), down("digit"), elapsed])).toBe("cancelled")
  })

  test("cancels on other keys or modifiers until mod is released", () => {
    expect(run([down("mod"), elapsed, down("other")])).toBe("cancelled")
    expect(run([down("mod"), down("other"), elapsed])).toBe("cancelled")
    expect(run([down("mod", true, true)])).toBe("cancelled")
    expect(run([down("other"), down("mod")])).toBe("cancelled")
    expect(run([down("other"), { type: "keyup", mod: true }])).toBe("cancelled")
  })

  test("hides when mod is no longer held", () => {
    expect(run([down("mod"), elapsed, { type: "keyup", mod: false }])).toBe("idle")
    expect(run([down("other"), { type: "keyup", mod: false }, down("mod")])).toBe("pending")
    expect(run([down("mod"), elapsed, { type: "release" }])).toBe("idle")
    expect(run([down("mod"), { type: "release" }, elapsed])).toBe("idle")
  })
})

describe("sidebarShortcuts", () => {
  test("numbers the first nine rows", () => {
    const shortcuts = sidebarShortcuts(Array.from({ length: 12 }, (_, index) => `s${index}`))
    expect([...shortcuts]).toEqual(Array.from({ length: 9 }, (_, index) => [`s${index}`, index + 1]))
  })
})
