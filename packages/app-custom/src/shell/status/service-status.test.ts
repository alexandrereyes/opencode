import { describe, expect, test } from "bun:test"
import { serviceStatus } from "./service-status"

describe("service status", () => {
  test("prioritizes failures and authentication over healthy services", () => {
    expect(serviceStatus(["connected", "failed", "needs_auth"])).toBe("failed")
    expect(serviceStatus(["active"], new Error("unavailable"))).toBe("failed")
    expect(serviceStatus(["connected", "needs_auth"])).toBe("needs_auth")
    expect(serviceStatus(["connected", "pending"])).toBe("pending")
  })
  test("empty or disabled configurations do not imply healthy running services", () => {
    expect(serviceStatus([])).toBe("disabled")
    expect(serviceStatus(["disabled"])).toBe("disabled")
    expect(serviceStatus(["disabled", "active"])).toBe("active")
  })
})
