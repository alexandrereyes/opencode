import { expect, test } from "bun:test"
import { createPreviewQueue } from "./preview"

test("dashboard preview queue bounds simultaneous reads and drains in admission order", async () => {
  const enqueue = createPreviewQueue()
  const releases = Array.from({ length: 6 }, () => Promise.withResolvers<void>())
  const started = Array.from({ length: 6 }, () => Promise.withResolvers<void>())
  const finished = Array.from({ length: 6 }, () => Promise.withResolvers<void>())
  const order: number[] = []
  releases.forEach((release, index) =>
    enqueue(async () => {
      order.push(index)
      started[index].resolve()
      await release.promise
      finished[index].resolve()
    }),
  )
  expect(order).toEqual([0, 1, 2, 3])
  releases[1].resolve()
  await started[4].promise
  expect(order).toEqual([0, 1, 2, 3, 4])
  releases[0].resolve()
  await started[5].promise
  expect(order).toEqual([0, 1, 2, 3, 4, 5])
  releases.forEach((release) => release.resolve())
  await Promise.all(finished.map((finish) => finish.promise))
})
