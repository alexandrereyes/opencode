import { expect, test } from "bun:test"
import { createDirectoryGuard } from "./directory-guard"

test("cold checks coalesce and missing directories stop catalog requests until reconnect", async () => {
  let checks = 0
  let loads = 0
  let exists = false
  const guard = createDirectoryGuard(async () => {
    checks++
    return exists
  })
  const load = async () => {
    loads++
  }
  await Promise.all([guard.run("/removed", load), guard.run("/removed", load)])
  expect(checks).toBe(1)
  expect(loads).toBe(0)
  exists = true
  guard.clear()
  await guard.run("/removed", load)
  await guard.run("/removed", load)
  expect(checks).toBe(2)
  expect(loads).toBe(2)
})

test("deletion after a successful check is confirmed once before suppressing failures", async () => {
  let checks = 0
  let exists = true
  const guard = createDirectoryGuard(async () => {
    checks++
    return exists
  })
  await guard.run("/repo", async () => {})
  exists = false
  const failed = async () => {
    throw new Error("HTTP 500")
  }
  await Promise.all([guard.run("/repo", failed), guard.run("/repo", failed)])
  expect(checks).toBe(2)
  await guard.run("/repo", failed)
  expect(checks).toBe(2)
})

test("unrelated 500s and probe failures retain the original error", async () => {
  const error = new Error("HTTP 500")
  for (const check of [
    async () => true,
    async () => {
      throw new Error("RPC unavailable")
    },
  ]) {
    const guard = createDirectoryGuard(check)
    await expect(
      guard.run("/repo", async () => {
        throw error
      }),
    ).rejects.toBe(error)
  }
})
